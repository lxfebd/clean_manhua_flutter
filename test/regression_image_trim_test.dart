import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xingmanxia/utils/image_trim.dart';

/// 自动裁边去白边：合成带白边的测试图，验证扫描比例与裁剪结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('白边识别：四边各 50px（500x700）返回 0.1 比例', () async {
    final im = img.Image(width: 500, height: 700);
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(im,
        x1: 50, y1: 50, x2: 449, y2: 649,
        color: img.ColorRgb8(200, 200, 200));
    final tr = computeTrimOf(im, ImageTrim.maxTrim);
    // 50/500 = 0.1（左右），50/700 ≈ 0.0714（上下）
    expect(tr.left, closeTo(0.1, 0.02));
    expect(tr.right, closeTo(0.1, 0.02));
    expect(tr.top, closeTo(50 / 700, 0.02));
    expect(tr.bottom, closeTo(50 / 700, 0.02));
  });

  test('trimAndCrop 一次解码完成扫描+裁剪，尺寸变小', () async {
    final im = img.Image(width: 500, height: 700);
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(im,
        x1: 50, y1: 50, x2: 449, y2: 649,
        color: img.ColorRgb8(200, 200, 200));
    final bytes = Uint8List.fromList(img.encodePng(im));
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

  test('过小图片跳过（不浪费扫描）', () async {
    final im = img.Image(width: 16, height: 16);
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    final tr = computeTrimOf(im, ImageTrim.maxTrim);
    expect(tr.isEmpty, isTrue);
  });
}
