import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/responsive.dart';

/// 响应式布局系统回归测试：
/// 1. ScreenSize 断点边界（600/840/1200）
/// 2. Responsive 各判定方法与导航模式
/// 3. 大屏网格列数单调性（不因窗口变宽反而挤小卡片）
/// 4. showResponsiveBottomSheet 平板限宽（M3 大屏准则 LS-U2）
void main() {
  group('ScreenSize 断点边界', () {
    test('fromWidth 正确分类各断点', () {
      expect(ScreenSize.fromWidth(0), ScreenSize.compact);
      expect(ScreenSize.fromWidth(599.9), ScreenSize.compact);
      expect(ScreenSize.fromWidth(600), ScreenSize.medium);
      expect(ScreenSize.fromWidth(839.9), ScreenSize.medium);
      expect(ScreenSize.fromWidth(840), ScreenSize.expanded);
      expect(ScreenSize.fromWidth(1199.9), ScreenSize.expanded);
      expect(ScreenSize.fromWidth(1200), ScreenSize.large);
      expect(ScreenSize.fromWidth(1920), ScreenSize.large);
    });

    test('断点区间无缝衔接（相邻断点不重叠不遗漏）', () {
      const breakpoints = [0.0, 599.9, 600.0, 839.9, 840.0, 1199.9, 1200.0];
      final sizes = breakpoints.map(ScreenSize.fromWidth).toList();
      expect(sizes[0], ScreenSize.compact);
      expect(sizes[1], ScreenSize.compact);
      expect(sizes[2], ScreenSize.medium);
      expect(sizes[3], ScreenSize.medium);
      expect(sizes[4], ScreenSize.expanded);
      expect(sizes[5], ScreenSize.expanded);
      expect(sizes[6], ScreenSize.large);
    });
  });

  group('Responsive 判定（无 MediaQuery 依赖，纯宽度逻辑）', () {
    Future<BuildContext> pumpAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('compact 手机：<600dp 判定正确', (tester) async {
      final ctx = await pumpAt(tester, 400);
      expect(Responsive.screenSize(ctx), ScreenSize.compact);
      expect(Responsive.isCompact(ctx), isTrue);
      expect(Responsive.isMedium(ctx), isFalse);
      expect(Responsive.isTablet(ctx), isFalse);
      expect(Responsive.isExpanded(ctx), isFalse);
      expect(Responsive.isLarge(ctx), isFalse);
      expect(Responsive.navigationMode(ctx), NavigationMode.bottomNav);
    });

    testWidgets('medium 小平板：600–840dp 判定正确', (tester) async {
      final ctx = await pumpAt(tester, 720);
      expect(Responsive.screenSize(ctx), ScreenSize.medium);
      expect(Responsive.isCompact(ctx), isFalse);
      expect(Responsive.isMedium(ctx), isTrue);
      expect(Responsive.isTablet(ctx), isTrue);
      expect(Responsive.isExpanded(ctx), isFalse);
      expect(Responsive.isLarge(ctx), isFalse);
      expect(Responsive.navigationMode(ctx), NavigationMode.rail);
    });

    testWidgets('expanded 平板：840–1200dp 判定正确', (tester) async {
      final ctx = await pumpAt(tester, 1000);
      expect(Responsive.screenSize(ctx), ScreenSize.expanded);
      expect(Responsive.isExpanded(ctx), isTrue);
      expect(Responsive.isLarge(ctx), isFalse);
      expect(Responsive.navigationMode(ctx), NavigationMode.rail);
    });

    testWidgets('large 桌面：≥1200dp 判定正确', (tester) async {
      final ctx = await pumpAt(tester, 1440);
      expect(Responsive.screenSize(ctx), ScreenSize.large);
      expect(Responsive.isExpanded(ctx), isTrue);
      expect(Responsive.isLarge(ctx), isTrue);
      expect(Responsive.navigationMode(ctx), NavigationMode.drawer);
    });

    testWidgets('大屏输入框/表单类元素限宽 640dp（M3 LS-U2）', (tester) async {
      final phoneCtx = await pumpAt(tester, 400);
      expect(Responsive.fieldMaxWidth(phoneCtx), double.infinity);
      final tabletCtx = await pumpAt(tester, 1000);
      expect(Responsive.fieldMaxWidth(tabletCtx), 640);
    });

    testWidgets('内容最大宽度：大屏收口、小屏不限', (tester) async {
      final phoneCtx = await pumpAt(tester, 400);
      expect(Responsive.maxContentWidth(phoneCtx), isNull);
      final expandedCtx = await pumpAt(tester, 1000);
      expect(Responsive.maxContentWidth(expandedCtx), isNull);
      final largeCtx = await pumpAt(tester, 1200);
      expect(Responsive.maxContentWidth(largeCtx), 1200);
      final xlargeCtx = await pumpAt(tester, 1600);
      expect(Responsive.maxContentWidth(xlargeCtx), 1400);
    });

    testWidgets('网格列数随断点单调不减（大屏不挤小卡片）', (tester) async {
      const widths = [360.0, 720.0, 1000.0, 1440.0];
      final comicCols = <int>[];
      final novelCols = <int>[];
      final chapterCols = <int>[];
      for (final w in widths) {
        final ctx = await pumpAt(tester, w);
        comicCols.add(Responsive.comicGridColumns(ctx));
        novelCols.add(Responsive.novelGridColumns(ctx));
        chapterCols.add(Responsive.chapterGridColumns(ctx));
      }
      for (var i = 1; i < comicCols.length; i++) {
        expect(comicCols[i] >= comicCols[i - 1], isTrue,
            reason: '漫画列数在宽度 ${widths[i]} 不应小于 ${widths[i - 1]}');
        expect(novelCols[i] >= novelCols[i - 1], isTrue);
        expect(chapterCols[i] >= chapterCols[i - 1], isTrue);
      }
    });
  });

  group('AdaptiveValue 回退逻辑', () {
    testWidgets('未指定档位时回退到前一档', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              result = AdaptiveValue.of<String>(
                context,
                compact: 'c',
                medium: 'm',
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      // large 未指定 → 回退到 expanded → medium
      expect(result, 'm');
    });
  });

  group('showResponsiveBottomSheet 限宽（M3 LS-U2）', () {
    Future<void> pumpOpen(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showResponsiveBottomSheet<void>(
                    context: context,
                    builder: (_) => const SizedBox(
                      key: ValueKey('sheetContent'),
                      width: double.infinity,
                      height: 200,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('手机宽度下弹窗全宽', (tester) async {
      await pumpOpen(tester, 400);
      // 弹窗内部结构受限宽约束影响：直接测量 sheet 内容（SizedBox height:200）
      final content = find.byKey(const ValueKey('sheetContent'));
      final size = tester.getSize(content);
      expect(size.width, closeTo(400, 1));
    });

    testWidgets('平板宽度下弹窗限宽 500dp 并居中', (tester) async {
      await pumpOpen(tester, 1000);
      final content = find.byKey(const ValueKey('sheetContent'));
      final size = tester.getSize(content);
      expect(size.width, closeTo(kSheetMaxWidth, 1));
      // 仍处于底部（弹窗底部与屏幕底部对齐）
      final bottomSheetTop =
          tester.getTopLeft(find.byType(BottomSheet)).dy;
      expect(bottomSheetTop, closeTo(900 - 200, 1));
    });

    testWidgets('桌面宽度下弹窗仍限宽 500dp', (tester) async {
      await pumpOpen(tester, 1600);
      final content = find.byKey(const ValueKey('sheetContent'));
      final size = tester.getSize(content);
      expect(size.width, closeTo(kSheetMaxWidth, 1));
    });

    testWidgets('弹窗可正常关闭（isDismissible 默认 true）', (tester) async {
      await pumpOpen(tester, 1000);
      expect(find.byType(BottomSheet), findsOneWidget);
      // 点击遮罩层关闭
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });
  });
}
