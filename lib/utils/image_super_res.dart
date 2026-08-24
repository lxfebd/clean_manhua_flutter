import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 真实图片超分辨率重采样 —— Lanczos-3 算法。
///
/// Lanczos-3 是图像处理业界公认的金标准重采样算法，被 ImageMagick、GIMP、
/// GEGL 等专业图像处理软件采用。对动漫/漫画线条类图像效果尤其出色。
///
/// 核函数：L(x) = sinc(x) · sinc(x/3)  (|x| < 3)，其余为 0。
/// 在独立 Isolate 中执行，不阻塞 UI 线程。
class ImageSuperRes {
  static const double _pi = 3.141592653589793;

  static double _sinc(double x) {
    if (x.abs() < 1e-10) return 1.0;
    final px = _pi * x;
    return sin(px) / px;
  }

  static double _lanczos3(double x) {
    final ax = x.abs();
    if (ax >= 3.0) return 0.0;
    return _sinc(x) * _sinc(x / 3.0);
  }

  /// 预计算 2 个子像素相位（0.0 和 0.5）的 Lanczos 权重。
  /// 2x 上采样时，目标像素的源坐标小数部分只可能是 0.0 或 0.5。
  static List<double> _phaseWeights(int phase) {
    return List<double>.generate(7, (i) {
      final dx = (i - 3).toDouble();
      final d = phase == 0 ? (dx + 0.5).abs() : dx.abs();
      return _lanczos3(d);
    });
  }

  static final List<double> _phase0 = _phaseWeights(0);
  static final List<double> _phase1 = _phaseWeights(1);

  /// 在独立 Isolate 中执行 2x Lanczos-3 超分上采样。
  /// 返回 JPEG 编码后的字节。
  static Future<Uint8List> upscale2x(Uint8List bytes,
      {int quality = 90}) async {
    return compute(_lanczosEntry, _LanczosArgs(bytes, quality));
  }
}

class _LanczosArgs {
  final Uint8List bytes;
  final int quality;
  const _LanczosArgs(this.bytes, this.quality);
}

Uint8List _lanczosEntry(_LanczosArgs args) {
  final src = img.decodeImage(args.bytes);
  if (src == null) return args.bytes;
  final sw = src.width;
  final sh = src.height;
  if (sw <= 1 || sh <= 1) return args.bytes;
  const r = 3;

  final dw = sw * 2;
  final dh = sh * 2;
  final out = img.Image(width: dw, height: dh);

  for (int y = 0; y < dh; y++) {
    final iy = (y / 2.0).floor();
    final yPhase = y & 1;
    final yWeights = yPhase == 0 ? ImageSuperRes._phase0 : ImageSuperRes._phase1;

    for (int x = 0; x < dw; x++) {
      final ix = (x / 2.0).floor();
      final xPhase = x & 1;
      final xWeights = xPhase == 0 ? ImageSuperRes._phase0 : ImageSuperRes._phase1;

      double rAcc = 0, gAcc = 0, bAcc = 0, totalW = 0;

      for (int dy = -r; dy <= r; dy++) {
        final sy = (iy + dy).clamp(0, sh - 1);
        final wy = yWeights[dy + r];

        for (int dx = -r; dx <= r; dx++) {
          final sx = (ix + dx).clamp(0, sw - 1);
          final wx = xWeights[dx + r];
          final w = wx * wy;
          totalW += w;

          final p = src.getPixel(sx, sy);
          rAcc += p.r.toDouble() * w;
          gAcc += p.g.toDouble() * w;
          bAcc += p.b.toDouble() * w;
        }
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

  return Uint8List.fromList(img.encodeJpg(out, quality: args.quality));
}