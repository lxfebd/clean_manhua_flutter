import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/main_shell.dart';
import 'package:xingmanxia/ui/responsive.dart';

/// Android TV 遥控器焦点导航回归测试。
///
/// 覆盖 §8.4 TV 基础期「焦点导航」部分：
/// - `HoverEffect(focusable: true)` 可被 D-pad 聚焦，OK/Enter 触发 onTap
/// - 方向键由上→下在可聚焦节点间移动焦点（Flutter 焦点系统天然支持）
/// - `focusable` 默认 false 时桌面/触屏行为不变（无 Focus 节点）
/// - 聚焦项显示主色焦点环
void main() {
  group('HoverEffect TV 焦点导航', () {
    testWidgets('非 focusable（默认）无可聚焦节点', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverEffect(
              onTap: () => taps++,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      ));

      // 非 focusable 项不参与焦点导航：尝试聚焦无效果、无 onTap 触发
      final finder = find.byType(HoverEffect);
      expect(finder, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(finder.evaluate().first));
      expect(taps, 0);
    });

    testWidgets('focusable 项聚焦后 OK/Enter 触发 onTap', (tester) async {
      var taps = 0;
      final focusNode = FocusNode(debugLabel: 'tv-item');
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverEffect(
              focusable: true,
              focusNode: focusNode,
              onTap: () => taps++,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      ));

      // 初始未聚焦、无触发
      expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(focusNode));
      expect(taps, 0);

      // 聚焦后（等价 TV 遥控器方向键进入焦点系统），D-pad 中心键触发 onTap
      focusNode.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, focusNode);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1);

      // Enter 同样触发
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('方向键在上下两个 focusable 项间移动焦点', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              HoverEffect(
                focusable: true,
                onTap: () {},
                child: const SizedBox(width: 80, height: 40),
              ),
              HoverEffect(
                focusable: true,
                onTap: () {},
                child: const SizedBox(width: 80, height: 40),
              ),
            ],
          ),
        ),
      ));

      // 初始聚焦第一个 focusable 节点
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      final highlighted = FocusManager.instance.primaryFocus;
      expect(highlighted, isNotNull);

      // D-pad 向下：焦点应从第一项移到第二项
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(highlighted));
    });

    testWidgets('聚焦时渲染主色焦点环', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HoverEffect(
            focusable: true,
            onTap: () {},
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      ));

      // 初始无焦点环（透明描边）
      expect(
        _hasPrimaryBorder(tester),
        false,
        reason: '未聚焦时描边应为透明',
      );

      // 聚焦后出现主色描边
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_hasPrimaryBorder(tester), true, reason: '聚焦后应显示主色焦点环');
    });
  });
}

bool _hasPrimaryBorder(WidgetTester tester) {
  final decorated = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
  for (final db in decorated) {
    final deco = db.decoration as BoxDecoration?;
    final side = deco?.border?.top;
    if (side != null &&
        deco!.borderRadius != null &&
        side.color != Colors.transparent) {
      return true;
    }
  }
  return false;
}