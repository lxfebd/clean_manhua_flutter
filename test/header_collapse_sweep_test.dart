import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/anime_home_page.dart';
import 'package:xingmanxia/ui/main_shell.dart';

/// 诊断测试（临时）：滚动收起头部的**过程中**逐帧检查是否发生 RenderFlex
/// 溢出（真机表现为主滚动条位置的黄黑条纹）。
///
/// 背景：既有的 anime_header_collapse_test 只检查「完全展开」与「完全收起」
/// 两个稳态，中途帧被跳过——而溢出恰好只发生在这两态之间的过渡里。
void main() {
  Future<void> pump(WidgetTester tester, Widget home, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(0, false),
      home: home,
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 缓慢拖动，每帧检查异常。返回首个出错的步号与异常文本。
  Future<String?> sweep(WidgetTester tester, {int steps = 24, double dy = -10}) async {
    final scrollable = find.byType(CustomScrollView).first;
    final gesture = await tester.startGesture(tester.getCenter(scrollable));
    String? firstError;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, dy));
      await tester.pump(const Duration(milliseconds: 16));
      final e = tester.takeException();
      if (e != null && firstError == null) {
        firstError = 'step $i (累计 dy=${(i + 1) * dy}): $e';
        // ignore: avoid_print
        print('SWEEP-ERROR anime/home $firstError');
      }
    }
    await gesture.up();
    // MainShell 有持续动画（骨架屏/加载点），pumpAndSettle 永不收敛；改用
    // 有界帧数并逐帧检查异常。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final e = tester.takeException();
      if (e != null && firstError == null) {
        firstError = 'settle 帧 $i: $e';
        // ignore: avoid_print
        print('SWEEP-ERROR anime/home $firstError');
      }
    }
    return firstError;
  }

  testWidgets('首页（MainShell）手机 390dp：收起过程中无溢出', (tester) async {
    await pump(tester, const MainShell(), 390);
    final err = await sweep(tester);
    // ignore: avoid_print
    print('HOME-SWEEP-RESULT: ${err ?? "无溢出"}');
    expect(err, isNull, reason: '首页收起过程中出现溢出：$err');
  });

  testWidgets('动漫页手机 390dp：收起过程中无溢出', (tester) async {
    await pump(tester, const AnimeHomePage(), 390);
    final err = await sweep(tester);
    // ignore: avoid_print
    print('ANIME-SWEEP-RESULT: ${err ?? "无溢出"}');
    expect(err, isNull, reason: '动漫页收起过程中出现溢出：$err');
  });
}
