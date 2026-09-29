import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/anime_home_page.dart';
import 'package:xingmanxia/ui/home_page.dart';

/// 探针：定位「上滑收缩过程中黄条溢出」的真实来源。
///
/// 思路：分步小幅滚动（每步 10dp），在**中间偏移量**逐帧检查异常，
/// 而不只是首尾；再叠加放大文字缩放，因为静态核算在 1.0 缩放下刚好
/// 卡边（手机 158/158），文字一放大就会顶爆展开头自然高。
void main() {
  Future<void> pumpAt(
    WidgetTester tester,
    Widget page, {
    double width = 390,
    double textScale = 1.0,
    TargetPlatform? platform,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(0, false),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: page,
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  // 不用 pumpAndSettle：骨架/状态切换有循环动画会一直不 settle。
  Future<void> stepDrag(WidgetTester tester, String tag) async {
    for (var d = 10; d <= 600; d += 10) {
      await tester.drag(find.byType(CustomScrollView).first,
          Offset(0, -d.toDouble()));
      await tester.pump(const Duration(milliseconds: 50));
      final e = tester.takeException();
      if (e != null) {
        fail('$tag 滚动 ${d}dp 时溢出/异常：$e');
      }
    }
    // 末态 pump 多帧，捕获 settle 后状态。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final e = tester.takeException();
      if (e != null) {
        fail('$tag settle 后溢出/异常：$e');
      }
    }
  }

  testWidgets('首页 手机 390 文字1.0：分步滚动无溢出', (tester) async {
    await pumpAt(tester, const HomePage(type: 0));
    await stepDrag(tester, 'home-phone-x1.0');
  });

  testWidgets('首页 手机 390 文字1.5：分步滚动无溢出', (tester) async {
    await pumpAt(tester, const HomePage(type: 0), textScale: 1.5);
    await stepDrag(tester, 'home-phone-x1.5');
  });

  testWidgets('首页 手机 390 文字2.0：分步滚动无溢出', (tester) async {
    await pumpAt(tester, const HomePage(type: 0), textScale: 2.0);
    await stepDrag(tester, 'home-phone-x2.0');
  });

  testWidgets('动漫页 手机 390 文字1.0：分步滚动无溢出', (tester) async {
    await pumpAt(tester, const AnimeHomePage());
    await stepDrag(tester, 'anime-phone-x1.0');
  });

  testWidgets('动漫页 手机 390 文字1.5：分步滚动无溢出', (tester) async {
    await pumpAt(tester, const AnimeHomePage(), textScale: 1.5);
    await stepDrag(tester, 'anime-phone-x1.5');
  });

  testWidgets('首页 平板 1000 文字1.3：分步滚动无溢出', (tester) async {
    await pumpAt(tester, const HomePage(type: 0),
        width: 1000, textScale: 1.3);
    await stepDrag(tester, 'home-tablet-x1.3');
  });

  testWidgets('动漫页 平板 1000 文字1.3：分步滚动无溢出', (tester) async {
    await pumpAt(tester, const AnimeHomePage(),
        width: 1000, textScale: 1.3);
    await stepDrag(tester, 'anime-tablet-x1.3');
  });

  testWidgets('首页 桌面 1440 文字1.3：分步滚动无溢出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpAt(tester, const HomePage(type: 0), width: 1440, textScale: 1.3);
      await stepDrag(tester, 'home-desktop-x1.3');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('动漫页 桌面 1440 文字1.3：分步滚动无溢出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpAt(tester, const AnimeHomePage(), width: 1440, textScale: 1.3);
      await stepDrag(tester, 'anime-desktop-x1.3');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
