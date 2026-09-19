/// 一个插帧档位的完整描述（供 UI 面板直接渲染）。
class FrameInterpPreset {
  /// 唯一 id，也是持久化时存的值。
  final String id;

  /// 面板上显示的名称。
  final String name;

  /// 一句话说明它做了什么。
  final String desc;

  /// 档位序号（0=关），用来排序与判定开关。
  final int level;

  const FrameInterpPreset({
    required this.id,
    required this.name,
    required this.desc,
    required this.level,
  });

  bool get enabled => level > 0;
}

/// mpv 原生补帧（interpolation）管理。
///
/// 形态（docs/frame-interpolation-research.md F3 定案，2026-09-19 修订）：
/// mpv 内置 `interpolation=yes` 配合 `video-sync=display-resample-desync`，
/// 按显示刷新率把低帧率源补出中间帧（非运动补偿，单纯帧复制+混合，
/// 开销小、失败自动降级原速）。RIFE 引擎（`ai.frame.rife`）走离线子进程
/// 逐帧推理，接不进实时播放链，不作为播放器开关。
///
/// ⚠️ 倍速防护（2026-09-19 根因定位）：interpolation 只有在
/// `display-resample`（或 desync 变体）下才有意义，而 display-resample 的
/// 恒定 1 倍速**依赖可靠的 `estimated-display-fps`**——该估算在 ANGLE/远程
/// 桌面/合成器故障时读到垃圾值（本机实测 4211~8922Hz）导致视频被倍速。
/// 因此插帧前置条件由 `_applySync` 的探测守护把关（显示时钟可靠 **且**
/// 音轨在），时钟不可靠/无音轨时绝不开启插帧。
///
/// ⚠️ 用户机器插帧出路定案（2026-09-19 两轮实测）：
///   * `override-display-fps=60` 只钉 `display-fps`（读回 60.000000），
///     **不钉 `estimated-display-fps`**——display-resample/desync 追帧用的
///     是 edisp 不是 display-fps。用户机器 desync 下 edisp=419~525Hz 垃圾值
///     → mpv 按错时钟追帧 → 实时倍速（即使 `video-sync-max-factor=1` 也挡
///     不住：max-factor 限相对调整幅度，基准速率本身是错的，等于没挡）。
///   * 因此这台机器上 mpv 实时插帧**没有安全形态**：插帧必须进
///     display-resample 系，而该系必然倍速。出路 = edisp 探测门闸（时钟
///     不可靠绝不进 desync，插帧如实报障）+ 墙钟守卫兜底（诊断循环
///     连续两拍 time-pos/墙钟失衡即强制关插帧）+ 低帧率源判据
///     [fpsEligible]（时钟可靠时 24fps@60Hz 才真正插，避免无效开）。
///     需要插帧但时钟不可靠的用户，替代形态是离线导出（F2，RIFE 子进程
///     逐帧补帧落盘，见 docs/frame-interpolation-research.md）。
class FrameInterpManager {
  FrameInterpManager._();

  /// 全部档位，顺序即 UI 展示顺序。
  static const List<FrameInterpPreset> levels = [
    FrameInterpPreset(
      id: 'off',
      name: '关闭',
      desc: '原始帧率，零额外开销',
      level: 0,
    ),
    FrameInterpPreset(
      id: 'smooth',
      name: '流畅补帧',
      desc: '24fps 动画补到显示刷新率，低开销，推荐',
      level: 1,
    ),
    FrameInterpPreset(
      id: 'max',
      name: '全力补帧',
      desc: '更激进阈值，低帧率源全补，开销最高',
      level: 2,
    ),
  ];

  /// mpv 关键选项（FFI 实测确认，docs/... F3 记录）：
  /// `interpolation-threshold=0.85`——mpv 源码 `fabs(ratio-1.0)<threshold`
  /// 时跳过插帧：24fps 源 ratio=2.5 必插、60fps 源 ratio=1.0 不插，省 GPU。
  static const double _defaultThreshold = 0.85;

  static FrameInterpPreset presetById(String id) =>
      levels.firstWhere((e) => e.id == id, orElse: () => levels.first);

  static int indexOfId(String id) {
    final i = levels.indexWhere((e) => e.id == id);
    return i < 0 ? 0 : i;
  }

  /// 某档位对应的 mpv 属性集。off 显式还原默认值（幂等，可反复调用）。
  static Map<String, String> propsFor(String id) {
    final p = presetById(id);
    if (!p.enabled) {
      return {
        'interpolation': 'no',
        'interpolation-threshold': '$_defaultThreshold',
      };
    }
    return {
      'interpolation': 'yes',
      // smooth 用研究定案阈值；max 放宽到 0.99（接近 1:1 也插）。
      'interpolation-threshold': p.id == 'max' ? '0.99' : '$_defaultThreshold',
    };
  }

  /// 插帧是否值得开的帧率建议（纯函数，供单元测试与面板提示）。
  ///
  /// 语义与 mpv `interpolation-threshold` 同源：threshold=0.85 时插帧条件为
  /// `fabs(ratio-1.0) >= 0.85`，即源帧率 ≤ 显示刷新率的 1/1.85 ≈ 0.54 才
  /// 真正补帧（24fps@60Hz → ratio=2.5 必插；48fps@60Hz → ratio=1.25 被
  /// threshold 跳过，开了也没用）。故建议条件取 `videoFps < dispFps / 1.85`，
  /// 与 mpv 实际行为一致，避免对「开了也无效」的高帧率源做无谓推荐。
  /// 任一 fps ≤ 0 或缺失返回 false（不误伤）。
  static bool fpsEligible({required double videoFps, required double dispFps}) {
    if (videoFps <= 0 || dispFps <= 0) return false;
    return videoFps < dispFps / 1.85;
  }

  /// 墙钟守卫判定（纯函数，供单测）：真实播放速率 [rate]（time-pos 推进 /
  /// 墙钟流逝）偏离 1.0 是否达到「变速」标准。
  ///
  /// 2026-09-19 实测定案：mpv 的 `speed` 属性在显示时钟估算错误时读回
  /// 恒 1.0（自认 1x），**不可信**——用户机器实测 desync 下 edisp=419~525Hz
  /// 垃圾值、视频实时倍速、speed 却恒 1.000000。唯一可靠的倍速判据是
  /// time-pos 推进速度 vs 墙钟：真实 1 倍速两者同步，时钟错了按错时钟追帧
  /// → rate 明显偏离 1.0。阈值 0.2 = ±20%（诊断循环 2s 一拍，误差被平均）。
  /// rate ≤ 0 / 非有限 → false（单测直接覆盖，不依赖 speed 属性）。
  static bool wallClockDrifted(double rate, {double threshold = 0.2}) {
    if (rate <= 0 || !rate.isFinite) return false;
    return (rate - 1.0).abs() > threshold;
  }
}