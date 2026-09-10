import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xingmanxia/utils/image_trim.dart';

/// 自动裁边去白边：合成带白边的测试图，验证扫描比例与裁剪结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List makePng({int w = 500, int h = 700, int border = 50}) {
    final im = img.Image(width: w, height: h);
    // 白底
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    // 内容区：浅灰（非白），位于边框内侧（fillRect 的 x2/y2 为闭区间）
    img.fillRect(im,
        x1: border, y1: border, x2: w - border - 1, y2: h - border - 1,
        color: img.ColorRgb8(200, 200, 200));
    return Uint8List.fromList(img.encodePng(im));
  }

  test('白边识别：四边各 50px（500x700）返回 0.1 比例', () async {
    final bytes = makePng();
    final tr = await computeTrimRect(bytes);
    // 50/500 = 0.1（左右），50/700 ≈ 0.0714（上下）
    expect(tr.left, closeTo(0.1, 0.02));
    expect(tr.right, closeTo(0.1, 0.02));
    expect(tr.top, closeTo(50 / 700, 0.02));
    expect(tr.bottom, closeTo(50 / 700, 0.02));
  });

  test('trimAndCrop 一次解码完成扫描+裁剪，尺寸变小', () async {
    final bytes = makePng();
    final out = await trimAndCrop(bytes);
    final dec = img.decodeImage(out);
    expect(dec, isNotNull);
    // 裁掉四边后内容区 400x600
    expect(dec!.width, 400);
    expect(dec.height, 600);
  });

  test('无白边图片不误裁（返回原字节）', () async {
    final im = img.Image(width: 500, height: 700);
    img.fill(im, color: img.ColorRgb8(128, 128, 128));
    final bytes = Uint8List.fromList(img.encodePng(im));
    final out = await trimAndCrop(bytes);
    expect(out.length, bytes.length);
  });

  test('过小图片跳过（不浪费 Isolate）', () async {
    final im = img.Image(width: 200, height: 200);
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    final bytes = Uint8List.fromList(img.encodePng(im));
    final tr = await computeTrimRect(bytes);
    expect(tr.isEmpty, isTrue);
  });
}
