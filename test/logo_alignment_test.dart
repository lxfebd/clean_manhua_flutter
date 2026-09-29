import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/anime_home_page.dart';
import 'package:xingmanxia/ui/home_page.dart';

/// logo 对齐回归：home 与 anime 两页 logo 图标中心 y 坐标必须一致，
/// 避免换页时 logo「一会儿上一会儿下」。
/// 同时校验 logo 旁文字基线与图标垂直居中（中心 y 差 ≤ 1dp）。
void main() {
  Future<void> pumpAt(WidgetTester tester, Widget page, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(0, false),
      home: page,
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Rect? findLogoRect(WidgetTester tester, Type pageType) {
    final logo = find.descendant(
      of: find.byType(pageType),
      matching: find.byType(ClipRRect),
    );
    if (logo.evaluate().isEmpty) return null;
    final box = logo.evaluate().first.renderObject as RenderBox;
    if (!box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  double? findTitleCenterY(WidgetTester tester, Type pageType) {
    final title = find.descendant(
      of: find.byType(pageType),
      matching: find.text('星漫匣'),
    ).first;
    if (title.evaluate().isEmpty) return null;
    final box = title.evaluate().first.renderObject as RenderBox;
    if (!box.hasSize) return null;
    final r = box.localToGlobal(Offset.zero) & box.size;
    return r.center.dy;
  }

  testWidgets('home 与 anime 的 logo 图标中心 y 对齐（手机 390dp）',
      (tester) async {
    await pumpAt(tester, const HomePage(type: 0), 390);
    final homeLogo = findLogoRect(tester, HomePage);
    final homeTitleY = findTitleCenterY(tester, HomePage);
    expect(homeLogo, isNotNull, reason: 'home 应有 logo ClipRRect');
    expect(homeTitleY, isNotNull, reason: 'home 应有「星漫匣」文字');

    final homeLogoCenterY = homeLogo!.center.dy;
    // home 内部：logo 中心与文字中心应在 1dp 内（同 Row crossAxisAlignment.center）
    expect((homeLogoCenterY - homeTitleY!).abs(), lessThanOrEqualTo(1.5),
        reason: 'home logo 中心 y=$homeLogoCenterY 与文字 y=$homeTitleY 偏差 > 1.5dp');

    await pumpAt(tester, const AnimeHomePage(), 390);
    final animeLogo = findLogoRect(tester, AnimeHomePage);
    final animeTitleY = findTitleCenterY(tester, AnimeHomePage);
    expect(animeLogo, isNotNull, reason: 'anime 应有 logo ClipRRect');
    expect(animeTitleY, isNotNull, reason: 'anime 应有「星漫匣」文字');

    final animeLogoCenterY = animeLogo!.center.dy;
    expect((animeLogoCenterY - animeTitleY!).abs(), lessThanOrEqualTo(1.5),
        reason: 'anime logo 中心 y=$animeLogoCenterY 与文字 y=$animeTitleY 偏差 > 1.5dp');

    // 两页 logo 中心 y 必须一致（同 top padding 6 + half logo size）
    expect((homeLogoCenterY - animeLogoCenterY).abs(), lessThanOrEqualTo(1.0),
        reason: 'home logo y=$homeLogoCenterY 与 anime logo y=$animeLogoCenterY 不齐');
  });

  testWidgets('home 与 anime 的 logo 图标中心 y 对齐（平板 1000dp 移动平台）',
      (tester) async {
    await pumpAt(tester, const HomePage(type: 0), 1000);
    final homeLogo = findLogoRect(tester, HomePage);
    final homeTitleY = findTitleCenterY(tester, HomePage);
    expect(homeLogo, isNotNull);
    expect(homeTitleY, isNotNull);
    final homeLogoCenterY = homeLogo!.center.dy;
    expect((homeLogoCenterY - homeTitleY!).abs(), lessThanOrEqualTo(1.5),
        reason: 'home 平板 logo 与文字不齐');

    await pumpAt(tester, const AnimeHomePage(), 1000);
    final animeLogo = findLogoRect(tester, AnimeHomePage);
    final animeTitleY = findTitleCenterY(tester, AnimeHomePage);
    expect(animeLogo, isNotNull);
    expect(animeTitleY, isNotNull);
    final animeLogoCenterY = animeLogo!.center.dy;
    expect((animeLogoCenterY - animeTitleY!).abs(), lessThanOrEqualTo(1.5),
        reason: 'anime 平板 logo 与文字不齐');
    expect((homeLogoCenterY - animeLogoCenterY).abs(), lessThanOrEqualTo(1.0),
        reason: 'home/anime 平板 logo 中心 y 不齐');
  });

  testWidgets('两页 logo 尺寸一致（手机 28+28 vs 平板 32+32 同尺寸）',
      (tester) async {
    await pumpAt(tester, const HomePage(type: 0), 390);
    final homeLogo = findLogoRect(tester, HomePage);
    await pumpAt(tester, const AnimeHomePage(), 390);
    final animeLogo = findLogoRect(tester, AnimeHomePage);
    expect(homeLogo!.size, equals(animeLogo!.size),
        reason: '手机两页 logo 尺寸应一致：home=${homeLogo.size} anime=${animeLogo.size}');

    await pumpAt(tester, const HomePage(type: 0), 1000);
    final homeLogoT = findLogoRect(tester, HomePage);
    await pumpAt(tester, const AnimeHomePage(), 1000);
    final animeLogoT = findLogoRect(tester, AnimeHomePage);
    expect(homeLogoT!.size, equals(animeLogoT!.size),
        reason: '平板两页 logo 尺寸应一致');
  });
}
