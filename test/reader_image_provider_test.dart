import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/reader_page.dart';

/// 阅读器图片降采样 provider 的组合守护。
///
/// 线上崩溃：纵向条漫整页变成红字错误墙——
///   'package:flutter/src/painting/image_provider.dart': Failed assertion:
///   'getTargetSize == null': ResizeImage cannot be composed with another
///   ImageProvider that applies getTargetSize.
/// 成因：`Image.memory(bytes, cacheWidth: n)` 已自动把 provider 包成 ResizeImage，
/// 旧代码又取 `.image` 再套一层 ResizeImage。ResizeImage 自身会向解码回调下发
/// getTargetSize，外层因此断言失败——纵向每一张图都抛异常。
final Uint8List _png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

void main() {
  test('readerImageProvider 横向/纵向都是单层 ResizeImage', () {
    for (final horizontal in [true, false]) {
      final p = readerImageProvider(_png1x1,
          horizontal: horizontal, width: 800, height: 600);
      expect(p, isA<ResizeImage>(), reason: '降采样必须生效');
      final inner = (p as ResizeImage).imageProvider;
      expect(inner, isA<MemoryImage>());
      expect(inner, isNot(isA<ResizeImage>()),
          reason: '嵌套 ResizeImage 会在解码时触发 Flutter 断言');
    }
  });

  test('旧写法的自动包装确实构成嵌套（守护崩溃成因）', () {
    // Image(cacheWidth:) 内部就是 ResizeImage.resizeIfNeeded(...)
    final auto = ResizeImage.resizeIfNeeded(800, null, MemoryImage(_png1x1));
    expect(auto, isA<ResizeImage>());
    // 再套一层 = 线上崩溃的那个组合
    expect(ResizeImage(auto, height: 600).imageProvider, isA<ResizeImage>());
  });

  testWidgets('修复后的组合可正常解码出图', (tester) async {
    for (final horizontal in [true, false]) {
      final p = readerImageProvider(_png1x1,
          horizontal: horizontal, width: 800, height: 600);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: p),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'horizontal=$horizontal 不应抛异常');
    }
  });
}
