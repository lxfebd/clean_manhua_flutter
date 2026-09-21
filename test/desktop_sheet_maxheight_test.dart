import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/responsive.dart';

/// 桌面端 showResponsiveBottomSheet 高度约束回归测试。
/// 历史 bug 根因：桌面分支（showDialog→Center→ConstrainedBox）只有
/// maxWidth，内容高于窗口时卡片直接顶出屏幕底边（如"切换番剧源"8 项
/// 列表"感觉被裁断"）。修复后：限高 86% 窗口高，超出部分可滚。
void main() {
  const viewSize = Size(1165, 500);

  Future<void> openSheet(WidgetTester tester, WidgetBuilder builder) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () =>
                showResponsiveBottomSheet(context: context, builder: builder),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  /// 复刻 anime_home_page._pickSource 的结构：Column(min)+Flexible(ListView)。
  Widget sourceList(int n) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
                padding: EdgeInsets.all(14), child: Text('切换番剧源')),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (int i = 0; i < n; i++)
                    ListTile(title: Text('src$i'), dense: true)
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );

  /// 把弹窗滚到底（在外层 SingleChildScrollView 视口内向上拖）。
  Future<void> scrollToEnd(WidgetTester tester, Finder anchor) async {
    final gesture = await tester.startGesture(tester.getCenter(anchor));
    await gesture.moveBy(const Offset(0, -800));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('内容高于窗口：滚动视口限高不超过窗口 86%', (tester) async {
    await openSheet(tester, (_) => sourceList(20));
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    expect(viewport.height, lessThanOrEqualTo(viewSize.height * 0.86 + 1));
    // 视口必须严格小于整窗：修复前视口=整窗高，卡片底边直接顶出屏幕。
    expect(viewport.height, lessThan(viewSize.height));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('内容高于窗口：滚轮可滚到最后一项', (tester) async {
    await openSheet(tester, (_) => sourceList(20));
    // 末项被视口裁切（widget 存在但不可命中），说明超出部分靠滚动查看。
    expect(find.text('src19'), findsOneWidget);
    expect(find.text('src19').hitTestable(), findsNothing);
    await scrollToEnd(tester, find.text('切换番剧源'));
    expect(find.text('src19').hitTestable(), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('内容矮于窗口：按自然高度完整显示，不裁不断', (tester) async {
    await openSheet(tester, (_) => sourceList(3));
    expect(find.text('src2').hitTestable(), findsOneWidget);
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    expect(viewport.height, lessThanOrEqualTo(viewSize.height * 0.86));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('纯高内容调用方（无内层滚动）：不溢出且可滚到底', (tester) async {
    await openSheet(
      tester,
      (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(padding: EdgeInsets.all(14), child: Text('标题')),
          for (int i = 0; i < 16; i++)
            ListTile(title: Text('row$i'), dense: true),
        ],
      ),
    );
    expect(find.text('row15').hitTestable(), findsNothing);
    await scrollToEnd(tester, find.text('标题'));
    expect(find.text('row15').hitTestable(), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
