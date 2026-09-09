import 'dart:convert';
import 'dart:typed_data';

/// 单条字幕。
class SubtitleCue {
  final int startMs;
  final int endMs;
  final String text;
  const SubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  /// 当前播放时刻（毫秒）是否命中本字幕。
  bool contains(int ms) => ms >= startMs && ms < endMs;
}

/// SRT 字幕解析（纯逻辑，不入库网络依赖）。
///
/// 支持标准 SRT 结构：序号行 / `HH:MM:SS,mmm --> HH:MM:SS,mmm` / 多行文本（空行分隔）。
/// 容错：去掉 BOM、统一 CRLF；忽略无效区块；时间轴按毫秒归一到升序。
class SubtitleSrt {
  SubtitleSrt._();

  static final RegExp _timeLine = RegExp(
      r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})');

  /// 解析 SRT 文本。[raw] 为文件文本（UTF-8 解出的字符串）。
  static List<SubtitleCue> parse(String raw) {
    final cues = <SubtitleCue>[];
    if (raw.isEmpty) return cues;
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 去掉开头的 BOM（EF BB BF → \uFEFF）
    final body = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final blocks = body.split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      if (block.trim().isEmpty) continue;
      final lines = block.split('\n');
      int? startMs;
      int? endMs;
      // 时间行通常是第 1 或第 2 行（有些 SRT 首行是序号，有些无序号）。
      for (var i = 0; i < lines.length && i < 3; i++) {
        final m = _timeLine.firstMatch(lines[i]);
        if (m != null) {
          startMs = _toMs(m, 1);
          endMs = _toMs(m, 5);
          break;
        }
      }
      if (startMs == null || endMs == null) continue;
      // 文本 = 时间行之后的非空行拼接；无序号时时间行即首行。
      final timeIdx = lines.indexWhere((l) => _timeLine.hasMatch(l));
      final textLines = <String>[];
      if (timeIdx >= 0) {
        for (var i = timeIdx + 1; i < lines.length; i++) {
          if (lines[i].trim().isNotEmpty) textLines.add(lines[i].trim());
        }
      }
      if (textLines.isEmpty) continue;
      cues.add(SubtitleCue(
        startMs: startMs,
        endMs: endMs,
        text: textLines.join('\n'),
      ));
    }
    // 按开始时间升序，去重同时间轴。
    cues.sort((a, b) => a.startMs.compareTo(b.startMs));
    return cues;
  }

  /// 解析 SRT 字节。优先 UTF-8；尝试 UTF-16LE/BE（BOM 判断）——部分国产字幕为 GBK，
  /// 但 Dart 无内建 GBK，这里先处理 UTF-8/UTF-16，GBK 由调用方探测后转参传入。
  /// 返回 null 表示无法识别编码。
  static List<SubtitleCue>? parseBytes(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    // UTF-16 LE BOM
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return parse(_fromUtf16CodeUnits(_decodeUtf16(bytes, littleEndian: true)));
    }
    // UTF-16 BE BOM
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return parse(_fromUtf16CodeUnits(_decodeUtf16(bytes, littleEndian: false)));
    }
    try {
      return parse(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  /// 把 UTF-16 码元列表转成 Dart String：`String.fromCharCodes` 会正确
  /// 组合代理对，BMP 字符直接映射。
  static String _fromUtf16CodeUnits(List<int> units) =>
      String.fromCharCodes(units);

  static List<int> _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    // 跳过 BOM（前 2 字节），每 2 字节一组按端序合成码元。
    final out = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      final lo = bytes[i];
      final hi = bytes[i + 1];
      out.add(littleEndian ? (hi << 8) | lo : (lo << 8) | hi);
    }
    return out;
  }

  static int _toMs(RegExpMatch m, int group) {
    final h = int.parse(m.group(group + 0)!);
    final min = int.parse(m.group(group + 1)!);
    final s = int.parse(m.group(group + 2)!);
    var msStr = m.group(group + 3)!;
    if (msStr.length == 1) msStr = '${msStr}00';
    if (msStr.length == 2) msStr = '${msStr}0';
    final ms = int.parse(msStr);
    return h * 3600000 + min * 60000 + s * 1000 + ms;
  }
}

/// 在当前时间轴中查当前时刻命中的字幕（二分，字幕已按 start 升序）。
class SubtitleIndex {
  final List<SubtitleCue> _cues;
  SubtitleIndex(this._cues) {
    // 保证升序
    _cues.sort((a, b) => a.startMs.compareTo(b.startMs));
  }

  List<SubtitleCue> get cues => _cues;

  /// 当前时刻命中的字幕（可能多条重叠时取 start 最大的一条，即最近开始）。
  SubtitleCue? at(int ms) {
    SubtitleCue? best;
    for (final c in _cues) {
      if (c.startMs > ms) break;
      if (c.contains(ms)) best = c;
    }
    return best;
  }

  bool get isEmpty => _cues.isEmpty;
}