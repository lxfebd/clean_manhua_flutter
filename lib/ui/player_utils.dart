import 'package:media_kit/media_kit.dart';

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
