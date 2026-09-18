/// 一个补帧档位的完整描述（供 UI 面板直接渲染）。
class FrameInterpPreset {
  /// 唯一 id，也是持久化时存的值。
  final String id;

  /// 面板上显示的名称。
  final String name;

  /// 一句话说明它做了什么。
  final String desc;

  /// GPU 开销星级 0~4，用来在面板上画小方块。
  final int cost;

  const FrameInterpPreset({
    required this.id,
    required this.name,
    required this.desc,
    required this.cost,
  });

  bool get enabled => id != 'off';
}

/// mpv 原生补帧（interpolation）管理。
///
/// 在 `video-sync=display-resample` 下，mpv 会按显示刷新率对视频做插帧
/// 与抽帧（`interpolation=yes`），把 24fps 动画补成接近显示刷新率的流畅度，
/// 且不改速度、不依赖任何外部引擎（零下载）。桌面专属（与 Anime4K 超分
/// 同一道门闸），移动端强制关闭。
class FrameInterpManager {
  FrameInterpManager._();

  /// 全部档位，顺序即 UI 展示顺序。
  static const List<FrameInterpPreset> levels = [
    FrameInterpPreset(
      id: 'off',
      name: '关闭',
      desc: '原始帧率，零额外开销',
      cost: 0,
    ),
    FrameInterpPreset(
      id: 'smooth',
      name: '流畅补帧',
      desc: '补到显示刷新率，24fps 动画流畅度大幅提升',
      cost: 2,
    ),
    FrameInterpPreset(
      id: 'max',
      name: '尽力补帧',
      desc: '更低阈值、更激进补帧，快镜头更平滑，更吃 CPU/GPU',
      cost: 3,
    ),
  ];

  static FrameInterpPreset presetById(String id) =>
      levels.firstWhere((e) => e.id == id, orElse: () => levels.first);

  /// 该档位对应的 mpv 属性集。
  ///
  /// off 显式还原 `interpolation=no`（覆盖历史遗留的持久化开启值）；
  /// threshold/tscale 只在开启档下下发（off 时 mpv 根本不用它们，无需还原）。
  static Map<String, String> propsFor(String id) {
    final p = presetById(id);
    if (!p.enabled) return const {'interpolation': 'no'};
    return {
      'interpolation': 'yes',
      'interpolation-threshold': p.id == 'max' ? '0.99' : '0.85',
      'tscale': 'oversample',
    };
  }

  /// 是否值得开补帧的判据（纯函数，供提示/诊断用）。
  ///
  /// * [InterpAdvice.recommend]：视频帧率 ≤ 0.4 × 显示刷新率
  ///   （如 24fps@60Hz），补帧收益明显；
  /// * [InterpAdvice.noBenefit]：视频帧率 ≥ 显示刷新率，无收益；
  /// * [InterpAdvice.neutral]：其余区间（0.4~1.0），收益一般。
  static InterpAdvice adviceFor({
    required double videoFps,
    required double dispFps,
  }) {
    if (videoFps <= 0 || dispFps <= 0) return InterpAdvice.neutral;
    final ratio = videoFps / dispFps;
    if (ratio >= 1.0) return InterpAdvice.noBenefit;
    if (ratio <= 0.4) return InterpAdvice.recommend;
    return InterpAdvice.neutral;
  }
}

enum InterpAdvice { recommend, neutral, noBenefit }