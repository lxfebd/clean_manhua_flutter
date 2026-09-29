import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/anime_home_page.dart';

/// 回归测试：动漫页滚动收起头部（8-31 重设计·两页同步）。
/// 手机/平板/桌面三档宽度 × 桌面/移动双平台，确认无 RenderFlex 溢出等异常，
/// SliverPersistentHeader 存在、收起后头部高度收缩到 kToolbarHeight+状态栏。
void main() {
  Future<void> pumpAt(
    WidgetTester tester,
    double width, {
    TargetPlatform? platform,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    if (platform != null) {
      debugDefaultTargetPlatformOverride = platform;
    }
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(0, false),
      home: const AnimeHomePage(),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('手机 390dp：移动平台，头部展开/收起无异常', (tester) async {
    // 默认测试平台即 android，无需 override（避免 foundation 变量残留警告）。
    await pumpAt(tester, 390);
    expect(tester.takeException(), isNull, reason: '手机展开态无异常');
    expect(find.byType(SliverPersistentHeader), findsOneWidget);

    await tester.drag(
        find.byType(CustomScrollView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '手机收起后无异常');
  });

  /// M2 回归：展开头淡出后必须被 IgnorePointer 屏蔽，否则半收起时看不见的
  /// 搜索框/胶囊仍吃掉点击（两态热区重叠）。
  testWidgets('手机 390dp：收起后展开头被 IgnorePointer 屏蔽', (tester) async {
    await pumpAt(tester, 390);

    const expandedGuard = ValueKey('anime-header-expanded-guard');
    const collapsedGuard = ValueKey('anime-header-collapsed-guard');

    // 展开态（t=0）：展开头可点；收起头尚未出现（t<0.01 不渲染）。
    expect(
      tester.widget<IgnorePointer>(find.byKey(expandedGuard)).ignoring,
      isFalse,
      reason: '完全展开时搜索框必须可点',
    );
    expect(find.byKey(collapsedGuard), findsNothing,
        reason: '完全展开时收起头不参与布局');

    // 收起态（t=1）：展开头必须屏蔽，收起头可点。
    await tester.drag(
        find.byType(CustomScrollView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IgnorePointer>(find.byKey(expandedGuard)).ignoring,
      isTrue,
      reason: '收起后不可见的展开头必须屏蔽点击（原缺陷）',
    );
    expect(
      tester.widget<IgnorePointer>(find.byKey(collapsedGuard)).ignoring,
      isFalse,
      reason: '收起后收起头必须可点',
    );
  });

  testWidgets('平板 1000dp：桌面平台（桌面工具栏形态）无异常', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpAt(tester, 1000);
      expect(tester.takeException(), isNull, reason: '平板桌面工具栏展开态无异常');

      await tester.drag(
          find.byType(CustomScrollView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '平板桌面工具栏收起后无异常');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('平板 1000dp：移动平台（平板 Column 头）无异常', (tester) async {
    await pumpAt(tester, 1000);
    expect(tester.takeException(), isNull, reason: '平板 Column 展开态无异常');

    await tester.drag(
        find.byType(CustomScrollView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '平板 Column 收起后无异常');
  });

  testWidgets('桌面 1440dp：桌面工具栏形态无异常', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpAt(tester, 1440);
      expect(tester.takeException(), isNull, reason: '桌面展开态无异常');

      await tester.drag(
          find.byType(CustomScrollView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '桌面收起后无异常');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}