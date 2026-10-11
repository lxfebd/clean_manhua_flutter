import 'package:media_kit/media_kit.dart';

import '../net/http_client.dart' show Net;
import '../sources/video_source.dart';

/// 播放器页公共纯函数（god-class 拆分产物）。
///
/// 原为 native_player_page / anime_player_page 各自私有的 static helper
/// （_wh/_fmtFps/ovrFps/_trimSpeed/_audioTrackSubtitle），零状态依赖、
/// 可单测。anime 侧的 _trimSpeed 与 native 逐字节相同——抽公共后消除重复。

/// 拼「宽×高」文案（`×` 不是标识符字符，插值里不用加花括号）。
String whLabel(int w, int h) => '$w×$h';

/// 浮点 FPS 文案：可解析则保留 2 位小数，否则原样（空串 → '?'）。
String fmtFps(String v) {
  final d = double.tryParse(v);
  if (d == null) return v.isEmpty ? '?' : v;
  return d.toStringAsFixed(2);
}

/// 解析 override-display-fps 读回值（如 "60.000000" 或 "60/1"）。
/// 不可解析/非正数返回 0。
double ovrFps(String v) {
  final d = double.tryParse(v);
  if (d != null && d > 0) return d;
  final parts = v.split('/');
  if (parts.length == 2) {
    final num = int.tryParse(parts[0]);
    final den = int.tryParse(parts[1]);
    if (num != null && den != null && den > 0) return num / den;
  }
  return 0;
}

/// 倍速文案：整数值显示 1 位小数（1.0x），非整数原样（0.25x）。
String trimSpeed(double s) =>
    s == s.roundToDouble() ? s.toStringAsFixed(1) : s.toString();

/// 音轨副标题：语言 · 编码 · 声道 · 默认；无可显示项返回 null。
String? audioTrackSubtitle(AudioTrack t) {
  final parts = <String>[];
  if (t.language != null && t.language!.isNotEmpty) {
    parts.add('语言 ${t.language}');
  }
  if (t.codec != null) parts.add(t.codec!);
  if (t.channels != null && t.channels!.isNotEmpty) {
    parts.add(t.channels!);
  }
  if (t.isDefault ?? false) parts.add('默认');
  return parts.isEmpty ? null : parts.join(' · ');
}

/// ── 手势纯计算（god-class 拆分产物） ──────────────────────────
/// 原为 native_player_page 手势 State 方法内的内联计算，抽为顶层纯函数
/// 后可单测（见 test/player_gesture_test.dart）。

/// 连点侧区判定：左 35% 内 → 1（回退），右 35% 外 → 2（快进），
/// 中间 30% → 0（播放/暂停）。
int seekTapSide(double x, double width) {
  return x < width * 0.35 ? 1 : (x > width * 0.65 ? 2 : 0);
}

/// 连点累计 seek 幅度：第 1 次 10s，之后每次 +10s，上限 60s。
int tapSeekSeconds(int streak) => (streak * 10).clamp(10, 60);

/// 横滑 seek 可扫总时长：整屏宽 = 视频总时长的 1/4，最多 180 秒。
double horizontalSeekSpan(int durSeconds) {
  final span = durSeconds / 4;
  return span > 180 ? 180.0 : span;
}

/// 横滑 seek 目标：从 [from] 按横向位移 [dx]（屏宽 [width]）推进/回退，
/// clamp 到 [0, dur]。
Duration horizontalSeekTarget({
  required Duration from,
  required double dx,
  required double width,
  required Duration dur,
}) {
  final maxSpan = horizontalSeekSpan(dur.inSeconds);
  final deltaSec = dx / width * maxSpan * 2;
  var t = from + Duration(milliseconds: (deltaSec * 1000).round());
  if (t < Duration.zero) t = Duration.zero;
  if (t > dur) t = dur;
  return t;
}

/// 竖滑归一化位移：以屏幕高度 *0.7 为标尺（竖屏小窗只有两百来像素高，
/// 按窗口高度换算会灵敏到没法微调），上滑（负 primaryDelta）为正值增量。
double verticalGestureDelta(double primaryDelta, double screenHeight) {
  final refH = screenHeight * 0.7;
  return -primaryDelta / refH;
}

/// 竖滑目标值：起始值 + 增量后 clamp 到 [lo, 1.0]（亮度下限随模式不同：
/// 系统亮度 _minBrightness=0，遮罩兜底 _minMaskBrightness=0.12；音量下限 0）。
double verticalGestureValue(double start, double delta, double lo) {
  final v = start + delta;
  return v.clamp(lo, 1.0);
}

/// 播放请求头：UA + 除 pan.wo.cn 外的 Referer + Host 头映射。
///
/// 带 Referer 会让 mpv 拉流反复被 400 掐断（实测 HTTP 400 / ECONNRESET，
/// 无 Referer 才 206 正常下载），故对 pan.wo.cn 签名直链域名不设 Referer。
Map<String, String> mediaHeaders(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return const {};
  final host = uri.host;
  final h = <String, String>{
    'User-Agent': Net.defaultUA,
    if (!RegExp(r'(^|\.)pan\.wo\.cn$').hasMatch(host))
      'Referer': '${uri.scheme}://$host/',
    ...hostHeaderFor(url),
  };
  return h;
}
