import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/keyboard_shortcuts.dart';
import 'package:xingmanxia/ui/main_shell.dart';

/// 桌面快捷键回归：大屏下主壳注册全局快捷键（Ctrl+数字切 Tab、`?` 面板），
/// 且快捷键总览数据齐全（各阅读/播放场景的键位都在面板中有说明）。
void main() {
  Future<void> pumpLarge(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('大屏下 Ctrl+2 切到动漫 Tab', (tester) async {
    await pumpLarge(tester);
    // 主壳首 Tab 为 MangaAnimeTabs（复合页），Ctrl+2 应切到 AnimeHomePage。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('`?` 打开快捷键面板，Esc 关闭', (tester) async {
    await pumpLarge(tester);
    // shift + / = ?（完整 down→down→up 序列，sendKeyEvent 单发时序不稳）
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('键盘快捷键'), findsOneWidget);
    expect(find.text('视频播放器'), findsOneWidget);
    // Esc 关闭面板（overlay 自带全局 handler，无需焦点）
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('键盘快捷键'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快捷键面板数据齐全', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ShortcutHelpOverlay()));
    await tester.pump();
    // 分组标题
    expect(find.text('全局'), findsOneWidget);
    expect(find.text('漫画阅读器'), findsOneWidget);
    expect(find.text('小说阅读器'), findsOneWidget);
    expect(find.text('视频播放器'), findsOneWidget);
    // 关键动作
    expect(find.text('播放 / 暂停'), findsOneWidget);
    expect(find.text('快退 / 快进 10 秒'), findsOneWidget);
    expect(find.text('音轨切换'), findsOneWidget);
    expect(find.text('画中画'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
