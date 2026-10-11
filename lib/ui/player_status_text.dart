/// 播放器状态文案纯函数（god-class 拆分产物）。
///
/// 原为 native_player_page State 私有方法（_srBadgeLabel/_srHintText/
/// _bufferText），依赖 State 字段但可参数注入——抽为顶层纯函数后可单测。
library;

/// 超分角标文案：档位 + 源分辨率 + x2 放大链执行条件。
///
/// ⚠️ 不要写「→ 输出分辨率」：Anime4K 执行在 VO 着色器阶段，mpv 没有
/// 任何属性能直接给出"超分后的尺寸"（旧实现拿 video-out-params 冒充，
/// 恒等于源尺寸，属于谎报）。如实展示：档位 + 源分辨率 + x2 链是否
/// 具备执行条件（不成立时说明原因）。
String srBadgeLabel(String srName, int vw, int vh, bool? eligible) {
  final buf = StringBuffer('AI 超分 · $srName');
  if (vw > 0 && vh > 0) buf.write(' · $vw×$vh');
  if (eligible == false) {
    // 渲染输出比源还小（窗口/屏幕装不下源，正在缩小播放）：
    // shader 的 WHEN 条件不成立，本次只有 Restore 修复链在跑。
    buf.write(' · 缩小播放，仅修复');
  }
  return buf.toString();
}

/// 超分面板底部提示，按 x2 链实际执行条件分三种情况如实说明。
///
/// Anime4K x2 链的 `//!WHEN OUTPUT.w > MAIN.w/0.999` 要求渲染输出
/// （= mpv 渲染目标 = 窗口/全屏尺寸）比片源大才执行；执行后画面被放大到
/// 2×源分辨率再由 VO 缩回窗口尺寸（超采样）。所以：
/// * 全屏到 2K 屏（输出 2560×1440）播 1080p 源 → x2 链跑 → 真实 2K；
/// * 窗口化播 1080p 源 → 输出≈源尺寸 → WHEN 不成立 → 只有修复链生效。
String srHintText(int vw, int vh, bool? eligible) {
  final src = (vw > 0 && vh > 0) ? '当前片源 $vw×$vh' : '片源分辨率获取中';
  if (eligible == false) {
    return '$src，画面渲染尺寸比片源还小（正在缩小播放），放大链不执行，'
        '本次只有线条修复生效。全屏播放或调大窗口即可开启 2 倍超采样。';
  }
  if (vw > 0 && vw <= 1280) {
    return '$src，低于 720p 档位收益最明显；卡顿请降档。'
        'x2 档（极致画质）全屏到 2K 屏会自动放大到 2560×1440（2K 超采样）。';
  }
  return '$src。超分会把画面放大 2 倍再缩回屏幕尺寸（超采样，锐化线条与降噪），'
      '收益小于低分辨率片源但真实可见，开销较高，卡顿请降档。'
      'x2 档（极致画质）全屏到 2K 屏即为 2K 超分。';
}

/// 缓冲/加载中提示文案：已有进度数据时给百分比，否则给阶段说明。
String bufferText({
  required bool recovering,
  required bool switching,
  required bool ready,
  required bool buffering,
  required Duration dur,
  required Duration buffer,
}) {
  if (recovering) return '播放中断，正在重连…';
  if (switching) return '正在解析直链…';
  if (ready && buffering) {
    final d = dur.inMilliseconds;
    final b = buffer.inMilliseconds;
    if (d > 0) {
      final pct = (b * 100 / d).clamp(0, 100).toInt();
      return '缓冲中 $pct%';
    }
  }
  return '加载中…';
}
