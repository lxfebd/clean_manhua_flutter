import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 图片超分辨率重采样。
///
/// 使用 Lanczos-3 分离卷积（先横向后纵向），比 2D 卷积快 3.5×。
/// 在独立 Isolate 中执行，不阻塞 UI 线程。
///
/// 性能保护：
/// - 全局互斥锁：同一时间只允许 1 个超分任务，防止低端机 CPU 过载卡死。
/// - 源图尺寸上限：最长边 > 1400px 的图不再放大（已经足够清晰）。
/// - JPEG 质量 88（平衡画质与文件大小）。
class ImageSuperRes {
  /// 算法版本：升级超分算法（如换 Real-ESRGAN）时递增，
  /// 缓存 key 会随之变化，旧的超分缓存自动失效。
  static const String algoVersion = 'lanczos3-v2';
  static Completer<void>? _mutex;

  /// 获取互斥锁，带 30 秒超时保护（防止 Isolate 异常导致锁永不释放）。
  static Future<void> _acquire() async {
    while (_mutex != null) {
      try {
        await _mutex!.future.timeout(const Duration(seconds: 30));
      } catch (_) {
        // 超时：强制释放，继续执行
        break;
      }
    }
    _mutex = Completer<void>();
  }

  static void _release() {
    final m = _mutex;
    _mutex = null;
    m?.complete();
  }

  static const int _maxSourceEdge = 1400;

  /// 轻量预检：只解析图片文件头（不完整解码）判断长边是否值得超分。
  /// 已清晰的图（长边 > 屏宽阈值）直接返回 null，避免把整图字节
  /// 传进 Isolate 又原样返回的无谓开销（iOS 低端机尤其敏感）。
  static Future<int?> maxEdgeOf(Uint8List bytes) async {
    try {
      final decoder = img.findDecoderForData(bytes);
      if (decoder == null) return null;
      final info = decoder.startDecode(bytes);
      if (info == null) return null;
      final w = info.width;
      final h = info.height;
      return w > h ? w : h;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> upscale2x(Uint8List bytes,
      {int quality = 88}) async {
    // 预检：长边超过 _maxSourceEdge 的图原本就会在 Isolate 内短路返回，
    // 这里提前拦下，省掉一次跨 Isolate 的整图字节传输。
    try {
      final edge = await maxEdgeOf(bytes);
      if (edge != null && edge > _maxSourceEdge) return bytes;
    } catch (_) {}
    await _acquire();
    try {
      return await compute(_upscaleEntry, _Args(bytes, quality, _maxSourceEdge))
          .timeout(const Duration(minutes: 2), onTimeout: () => bytes);
    } finally {
      _release();
    }
  }
}

class _Args {
  final Uint8List bytes;
  final int quality;
  final int maxSourceEdge;
  const _Args(this.bytes, this.quality, this.maxSourceEdge);
}

const double _pi = math.pi;

double _sinc(double x) {
  if (x.abs() < 1e-10) return 1.0;
  final px = _pi * x;
  return math.sin(px) / px;
}

double _lanczos3(double x) {
  final ax = x.abs();
  if (ax >= 3.0) return 0.0;
  return _sinc(x) * _sinc(x / 3.0);
}

final List<double> _phase0 = List<double>.generate(7, (i) {
  final dx = (i - 3).toDouble();
  return _lanczos3((dx + 0.5).abs());
});

final List<double> _phase1 = List<double>.generate(7, (i) {
  final dx = (i - 3).toDouble();
  return _lanczos3(dx.abs());
});

Uint8List _upscaleEntry(_Args args) {
  final src = img.decodeImage(args.bytes);
  if (src == null) return args.bytes;
  final sw = src.width;
  final sh = src.height;
  if (sw <= 1 || sh <= 1) return args.bytes;

  final longest = sw > sh ? sw : sh;
  if (longest > args.maxSourceEdge) return args.bytes;

  final dw = sw * 2;
  final dh = sh * 2;

  final tmp = _resizeAxis(src, axisX: true, outW: dw, outH: sh);
  final out = _resizeAxis(tmp, axisX: false, outW: dw, outH: dh);

  return Uint8List.fromList(img.encodeJpg(out, quality: args.quality));
}

img.Image _resizeAxis(img.Image src,
    {required bool axisX, required int outW, required int outH}) {
  final out = img.Image(width: outW, height: outH);
  final sw = src.width;
  final sh = src.height;

  for (int y = 0; y < outH; y++) {
    final iy = axisX ? y : (y ~/ 2);
    final yPhase = axisX ? 0 : (y & 1);
    final yWeights = yPhase == 0 ? _phase0 : _phase1;

    for (int x = 0; x < outW; x++) {
      final ix = axisX ? (x ~/ 2) : x;
      final xPhase = axisX ? (x & 1) : 0;
      final xWeights = xPhase == 0 ? _phase0 : _phase1;

      double rAcc = 0, gAcc = 0, bAcc = 0, totalW = 0;

      for (int d = -3; d <= 3; d++) {
        final sx = axisX ? (ix + d).clamp(0, sw - 1) : ix.clamp(0, sw - 1);
        final sy = axisX ? iy.clamp(0, sh - 1) : (iy + d).clamp(0, sh - 1);
        final w = axisX ? xWeights[d + 3] : yWeights[d + 3];
        totalW += w;
        final p = src.getPixel(sx, sy);
        rAcc += p.r.toDouble() * w;
        gAcc += p.g.toDouble() * w;
        bAcc += p.b.toDouble() * w;
      }

      if (totalW.abs() > 1e-10) {
        out.setPixelRgb(
          x, y,
          (rAcc / totalW).round().clamp(0, 255),
          (gAcc / totalW).round().clamp(0, 255),
          (bAcc / totalW).round().clamp(0, 255),
        );
      }
    }
  }
  return out;
}
