import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 漫画页自动裁边（去白边）：四方向逐行扫描灰度，返回各边裁剪比例。
///
/// 思路（路线图「图片自动裁边去白边」）：
/// - 图片加载完成后在 Isolate 里扫描一次，计算最小有效内容矩形；
/// - 判定规则：白边 = 一行/列灰度均值 > 250 且占比超过 95%（抗网点/噪点）；
/// - 返回四边裁剪比例（0~1，相对原图宽高），渲染期用
///   [TrimRect.apply] 组合 Transform 裁剪，不改动原始字节、不重复解码。
class ImageTrim {
  /// 算法版本：升级裁边算法（如加黑边识别）时递增，缓存 key 变化自动失效。
  static const String algoVersion = 'gray-v1';

  /// 有效内容行/列的最小占比（一行里超过该比例的像素灰度 > [whiteGray] 才算白边）。
  static const double _whiteRatio = 0.95;

  /// 灰度 > 250 判定为白/近白。
  static const int _whiteGray = 250;

  /// 极端保护：单边裁剪比例上限（防止误裁大面积留白/跨页彩页）。
  static const double maxTrim = 0.35;

  /// 顶部继续扫描的最小高度（避免把整页判定为白页）。
  static const int _minRemain = 16;

  /// 预检：只读文件头拿宽高。太小的图不做裁边（收益低且有风险）。
  static Future<bool> isWorthTrimming(Uint8List bytes,
      {int minEdge = 400}) async {
    try {
      final decoder = img.findDecoderForData(bytes);
      if (decoder == null) return false;
      final info = decoder.startDecode(bytes);
      if (info == null) return false;
      return info.width >= minEdge && info.height >= minEdge;
    } catch (_) {
      return false;
    }
  }
}

/// 四边裁剪比例（0~1，相对原图宽高）。全 0 = 无需裁剪。
@immutable
class TrimRect {
  final double top;
  final double bottom;
  final double left;
  final double right;

  const TrimRect({this.top = 0, this.bottom = 0, this.left = 0, this.right = 0});

  bool get isEmpty => top <= 0 && bottom <= 0 && left <= 0 && right <= 0;

  static const TrimRect none = TrimRect();

  Map<String, dynamic> toJson() =>
      {'top': top, 'bottom': bottom, 'left': left, 'right': right};

  factory TrimRect.fromJson(Map<String, dynamic> m) => TrimRect(
        top: (m['top'] as num?)?.toDouble() ?? 0,
        bottom: (m['bottom'] as num?)?.toDouble() ?? 0,
        left: (m['left'] as num?)?.toDouble() ?? 0,
        right: (m['right'] as num?)?.toDouble() ?? 0,
      );
}

/// compute() 入口参数（顶层函数避免闭包序列化问题）。
class _TrimArgs {
  final Uint8List bytes;
  final double maxTrim;
  const _TrimArgs(this.bytes, this.maxTrim);
}

/// Isolate 内执行：解码 → 逐行/列扫描 → 返回 TrimRect。
TrimRect _computeTrimEntry(_TrimArgs args) {
  final src = img.decodeImage(args.bytes);
  if (src == null) return TrimRect.none;
  final w = src.width;
  final h = src.height;
  if (w < 32 || h < 32) return TrimRect.none;
  final maxTrim = args.maxTrim;

  // 逐行计算「白像素占比」，用于上下边判定。
  final rowWhite = List<double>.filled(h, 0);
  for (int y = 0; y < h; y++) {
    var white = 0;
    for (int x = 0; x < w; x++) {
      final p = src.getPixel(x, y);
      // 灰度：0.299R + 0.587G + 0.114B（整数近似）
      final g = (p.r.toInt() * 77 + p.g.toInt() * 150 + p.b.toInt() * 29) >> 8;
      if (g > ImageTrim._whiteGray) white++;
    }
    rowWhite[y] = white / w;
  }

  bool isWhiteRow(int y) => rowWhite[y] >= ImageTrim._whiteRatio;

  // 从某一边向内容内部扫描：记录「纯白连续段」的结束位置。
  // 规则：连续 >=3 行/列的白段才认为是边距；中途出现内容则终止。
  // 扫描深度限制为 length - _minRemain：全白图也不会被裁到空。
  // 返回从该边起累计可裁掉的像素数（遇到内容即停）。
  int leadingWhite(List<bool> whiteLine, bool fromEnd) {
    final length = whiteLine.length;
    final maxScan = length - ImageTrim._minRemain;
    var cut = 0;
    var streak = 0;
    for (int i = 0; i < maxScan; i++) {
      final idx = fromEnd ? length - 1 - i : i;
      if (whiteLine[idx]) {
        streak++;
        // 只有凑够 3 行的纯白段才计为边距；中间出现内容行则整个作废
        if (streak >= 3) cut = i + 1;
      } else {
        // 遇到内容行：若已有边距则停止，否则重置继续找
        if (cut > 0) break;
        streak = 0;
      }
    }
    return cut;
  }

  // 顶部/底部：白行序列。
  final rowFlags = List<bool>.generate(h, isWhiteRow);
  var top = leadingWhite(rowFlags, false);
  var bottom = leadingWhite(rowFlags, true);
  if (top <= ImageTrim._minRemain) top = 0;
  if (bottom <= ImageTrim._minRemain) bottom = 0;

  // 左右：列方向扫描（灰度均值 + 白占比）。
  final colWhite = List<double>.filled(w, 0);
  for (int x = 0; x < w; x++) {
    var white = 0;
    for (int y = 0; y < h; y++) {
      final p = src.getPixel(x, y);
      final g = (p.r.toInt() * 77 + p.g.toInt() * 150 + p.b.toInt() * 29) >> 8;
      if (g > ImageTrim._whiteGray) white++;
    }
    colWhite[x] = white / h;
  }
  bool isWhiteCol(int x) => colWhite[x] >= ImageTrim._whiteRatio;

  final colFlags = List<bool>.generate(w, isWhiteCol);
  var left = leadingWhite(colFlags, false);
  var right = leadingWhite(colFlags, true);
  if (left <= ImageTrim._minRemain) left = 0;
  if (right <= ImageTrim._minRemain) right = 0;

  // 归一化为比例并套上限。
  final tr = TrimRect(
    top: (top / h).clamp(0.0, maxTrim),
    bottom: (bottom / h).clamp(0.0, maxTrim),
    left: (left / w).clamp(0.0, maxTrim),
    right: (right / w).clamp(0.0, maxTrim),
  );
  // 对极小边距做四舍五入抑制（<1.5% 的边不裁，避免抖动）。
  final q = TrimRect(
    top: tr.top < 0.015 ? 0 : tr.top,
    bottom: tr.bottom < 0.015 ? 0 : tr.bottom,
    left: tr.left < 0.015 ? 0 : tr.left,
    right: tr.right < 0.015 ? 0 : tr.right,
  );
  return q;
}

/// 在 Isolate 中计算裁边参数（不阻塞 UI）。失败/无收益返回 [TrimRect.none]。
Future<TrimRect> computeTrimRect(Uint8List bytes) async {
  try {
    final ok = await ImageTrim.isWorthTrimming(bytes);
    if (!ok) return TrimRect.none;
    return await compute(_computeTrimEntry, _TrimArgs(bytes, ImageTrim.maxTrim))
        .timeout(const Duration(seconds: 10), onTimeout: () => TrimRect.none);
  } catch (_) {
    return TrimRect.none;
  }
}

/// Isolate 内执行：按 [TrimRect] 把图片内容区裁出来重编码（JPEG 88）。
Uint8List _cropEntry(_CropArgs args) {
  final src = img.decodeImage(args.bytes);
  if (src == null) return args.bytes;
  final w = src.width;
  final h = src.height;
  final t = args.trim;
  final x0 = (t.left * w).round().clamp(0, w - 1);
  final y0 = (t.top * h).round().clamp(0, h - 1);
  final x1 = (w - (t.right * w).round()).clamp(x0 + 1, w);
  final y1 = (h - (t.bottom * h).round()).clamp(y0 + 1, h);
  if (x1 - x0 >= w || y1 - y0 >= h) return args.bytes;
  final cropped = img.copyCrop(src, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  return Uint8List.fromList(img.encodeJpg(cropped, quality: 88));
}

class _CropArgs {
  final Uint8List bytes;
  final TrimRect trim;
  const _CropArgs(this.bytes, this.trim);
}

/// 在 Isolate 中按 [trim] 裁剪字节。失败返回原图字节（不放大、不报错）。
Future<Uint8List> cropToContent(Uint8List bytes, TrimRect trim) async {
  if (trim.isEmpty) return bytes;
  try {
    return await compute(_cropEntry, _CropArgs(bytes, trim))
        .timeout(const Duration(seconds: 15), onTimeout: () => bytes);
  } catch (_) {
    return bytes;
  }
}

/// 一步完成「扫描白边 + 裁剪」（只解码一次，比两步各解码一次省一半开销）。
/// 无白边/失败返回原图字节。
Future<Uint8List> trimAndCrop(Uint8List bytes) async {
  try {
    final ok = await ImageTrim.isWorthTrimming(bytes);
    if (!ok) return bytes;
    return await compute(_trimAndCropEntry, bytes)
        .timeout(const Duration(seconds: 15), onTimeout: () => bytes);
  } catch (_) {
    return bytes;
  }
}

Uint8List _trimAndCropEntry(Uint8List bytes) {
  final trim = _computeTrimEntry(_TrimArgs(bytes, ImageTrim.maxTrim));
  if (trim.isEmpty) return bytes;
  return _cropEntry(_CropArgs(bytes, trim));
}
