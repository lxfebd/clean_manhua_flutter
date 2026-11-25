import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/source_manage_page.dart';

/// P1-17 源管理页头窄屏溢出的 widget 回归。
///
/// 背景：返回按钮 + 标题 + 三个带图标文字按钮挤在一个无 Wrap 的 Row 里，
/// 390dp 手机扣除页边距后仅 ~358dp，容纳不下该组合 → RenderFlex overflow
/// 黄条/按钮被截断，而源管理正是默认源失效时的关键恢复页。
/// 修复：标题 Expanded，窄屏（<600dp）把三个次要操作收进「更多」菜单。
///
/// 这条测试就是原来的缺口：窄屏溢出在测试里会直接抛异常，所以能自动化。
void main() {
  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: SourceManagePage()),
    ));
    // 让 initState 的异步加载（SourceConfigStore.all 等）跑完并重建一次。
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('P1-17 源管理页头', () {
    for (final w in const [320.0, 360.0, 390.0, 480.0, 600.0, 840.0, 1024.0]) {
      testWidgets('${w.toInt()}dp 宽度下无布局溢出', (tester) async {
        await pumpAt(tester, w);
        // RenderFlex overflow 在测试环境会抛异常；这里必须为零。
        expect(tester.takeException(), isNull,
            reason: '${w.toInt()}dp 下页头溢出（见 P1-17）');

        // 标题与返回按钮必须一直在场。
        expect(find.text('数据源管理'), findsOneWidget);
        expect(find.byIcon(Icons.arrow_back_ios_new_rounded),
            findsAny);

        // 三个操作的可达性：窄屏走「更多」菜单，宽屏是三个按钮。
        if (w < 600) {
          expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget,
              reason: '窄屏应收纳进「更多」菜单');
          // 菜单项展开后必须包含三个操作。用定时 pump 而非 pumpAndSettle——
          // 页面有常驻动画/计时器，settle 永不返回（测试环境问题，非产品 bug）。
          await tester.tap(find.byIcon(Icons.more_horiz_rounded));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          // 注意：条目是 PopupMenuItem<String>，byType(PopupMenuItem) 只会
          // 匹配 <dynamic>，必须用谓词匹配任意泛型参数。
          final items = find.byWidgetPredicate((w) => w is PopupMenuItem);
          expect(items, findsNWidgets(3),
              reason: '「更多」菜单必须容纳 自定义源/源市场/恢复默认 三项');
          expect(find.text('自定义源'), findsWidgets);
          expect(find.text('源市场'), findsWidgets);
          expect(find.text('恢复默认'), findsWidgets);
          expect(tester.takeException(), isNull, reason: '菜单展开不应抛异常');
        } else {
          expect(find.text('自定义源'), findsOneWidget);
          expect(find.text('源市场'), findsOneWidget);
          expect(find.text('恢复默认'), findsOneWidget);
        }
      });
    }
  });
}
