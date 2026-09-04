import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/main_shell.dart';

/// 复现 MuMu 模拟器 1920x1080 物理像素、低横屏高度的渲染路径。
/// 现有 main_shell_large_test 高度固定 900，未覆盖矮屏。
void main() {
  Future<void> pumpAtSize(WidgetTester tester, double w, double h, double dpr) async {
    tester.view.physicalSize = Size(w * dpr, h * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MainShell()));
    await tester.pump(Duration(milliseconds: 200));
  }

  testWidgets('dpr2 逻辑 960x540 矮横屏', (tester) async {
    await pumpAtSize(tester, 960, 540, 2.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dpr2.4 逻辑 800x450 矮横屏', (tester) async {
    await pumpAtSize(tester, 800, 450, 2.4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dpr1 逻辑 1920x1080', (tester) async {
    await pumpAtSize(tester, 1920, 1080, 1.0);
    expect(tester.takeException(), isNull);
  });
}
