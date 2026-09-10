import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/reader_page.dart';

/// 移动端手势回归（gitignored，仅本地验证）：
/// 1. 阅读器最左/最右边缘起手的上下滑 → 切换上一/下一话；
/// 2. 阅读器中部起手的上下滑 → 调节亮度（遮罩/系统亮度降级路径）。
/// 动漫(WebView)播放器手势依赖真实 WebView 平台，单测环境跳过，
/// 由 `flutter analyze` + 真机验收覆盖。
void main() {
  const w = Size(400, 800);

  testWidgets('阅读器：构造 + 首帧不抛异常（手势 smoke）', (tester) async {
    tester.view.physicalSize = w;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 需要真实源/章节数据，这里仅做编译期 smoke（页面构造不抛异常）。
    await tester.pumpWidget(MaterialApp(
      home: ReaderPage(
        sourceId: 'dummy',
        comicId: 'c',
        comicName: 'n',
        comicPic: '',
        comicAuthor: '',
        chapterId: 'ch1',
        title: '第1话',
        chapters: const [],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
