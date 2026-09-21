import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/main_shell.dart';

/// 主框架大屏渲染验证：在平板/桌面宽度下真实渲染 MainShell，
/// 通过 tester.takeException() 确定性验证无 RenderFlex 溢出/无界 flex 等布局异常。
void main() {
  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: MainShell()),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('medium 小平板 720dp：rail 布局无异常', (tester) async {
    await pumpAt(tester, 720);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded 平板 1000dp：rail 布局无异常', (tester) async {
    await pumpAt(tester, 1000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large 桌面 1440dp：rail 布局无异常', (tester) async {
    await pumpAt(tester, 1440);
    expect(tester.takeException(), isNull);
  });

  testWidgets('xlarge 桌面 1920dp：rail 布局无异常', (tester) async {
    await pumpAt(tester, 1920);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面 1440dp：点书架/工具/我的不越界崩溃', (tester) async {
    // 回归：hub 保活重构后侧栏原始索引 4/5/6 直喂 IndexedStack（仅 4 页）
    // 必红屏断言崩溃。点这三个入口验证映射正确、无异常。
    await pumpAt(tester, 1440);
    for (final label in ['书架', '工具', '我的']) {
      await tester.tap(find.text(label).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: '点击$label后崩溃');
    }
  });
}
