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
}
