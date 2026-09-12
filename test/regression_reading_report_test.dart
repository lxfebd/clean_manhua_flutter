import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

/// 年度/月度阅读统计回归：年度聚合、跨年边界、空数据不崩。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 打桩：LocalStore 落到临时目录（单元测试无插件通道）。
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_reading_report').path;
        }
        return null;
      },
    );
  });

  setUp(() async {
    await LocalStore.init();
  });

  test('addReadingSeconds 累计到当天，yearReadingSeconds 汇总', () async {
    await LocalStore.addReadingSeconds(3600);
    await LocalStore.addReadingSeconds(120);
    final total = await LocalStore.yearReadingSeconds();
    expect(total, greaterThanOrEqualTo(3720));
  });

  test('activeReadingDays 只统计秒数>0 的天', () async {
    await LocalStore.addReadingSeconds(600);
    // 今日已有 600 秒，active 至少 1
    final today = await LocalStore.activeReadingDays();
    expect(today, greaterThanOrEqualTo(1));
  });

  test('yearReadingMonths 返回全年 12 个月升序且月度聚合正确', () async {
    // 写入一条（今日必然落在当前年份某月）
    await LocalStore.addReadingSeconds(60);
    final now = DateTime.now();
    final months = await LocalStore.yearReadingMonths(now.year);
    expect(months.length, 12);
    // 12 个月全部合法且唯一
    final keys = months.map((m) => m['month'] as String).toSet();
    expect(keys.length, 12);
    // 全年总秒数 = 各月之和
    var sum = 0;
    for (final m in months) {
      sum += (m['seconds'] as int?) ?? 0;
    }
    final total = await LocalStore.yearReadingSeconds(now.year);
    expect(sum, total);
  });

  test('跨年边界：指定年份只聚合该年，空年份为 0', () async {
    final months = await LocalStore.yearReadingMonths(2000);
    expect(months.length, 12);
    // 2000 年（历史年份）必然无数据
    final t = await LocalStore.yearReadingSeconds(2000);
    expect(t, 0);
    final a = await LocalStore.activeReadingDays(2000);
    expect(a, 0);
  });

  test('recentReadingMonths 返回最近 N 个月升序', () async {
    await LocalStore.addReadingSeconds(60);
    final months = await LocalStore.recentReadingMonths(6);
    expect(months.length, 6);
    // 升序：第 1 个月份 <= 第 2 个
    final a = months[0]['month'] as String;
    final b = months[1]['month'] as String;
    expect(a.compareTo(b) <= 0, isTrue);
  });

  test('yearReadingStreak 最长连续区间正确（含跨月连续）', () async {
    await LocalStore.writeJson('reading_stats', {
      // 2026-01-01 ~ 01-04 连续 4 天
      '2026-01-01': 600,
      '2026-01-02': 300,
      '2026-01-03': 1200,
      '2026-01-04': 60,
      // 断一天 01-05
      // 2026-01-06 ~ 01-07 连续 2 天
      '2026-01-06': 900,
      '2026-01-07': 100,
      // 跨月连续：01-30、01-31、02-01 连续 3 天
      '2026-01-30': 500,
      '2026-01-31': 500,
      '2026-02-01': 500,
      // 非连续孤立天
      '2026-03-15': 700,
    });
    final s = await LocalStore.yearReadingStreak(2026);
    expect(s['maxStreak'], 4); // 01-01~01-04 最长
    expect(s['bestStart'], '2026-01-01');
    expect(s['bestEnd'], '2026-01-04');
    // 最佳区间累计 = 600+300+1200+60
    expect(s['bestSeconds'], 2160);
  });

  test('yearReadingStreak 空年份返回 0 连续', () async {
    await LocalStore.writeJson('reading_stats', {'2025-12-31': 100});
    final s = await LocalStore.yearReadingStreak(2026);
    expect(s['maxStreak'], 0);
    expect(s['bestStart'], isNull);
    expect(s['bestSeconds'], 0);
  });

  test('yearReadingBestDay 单日最长记录正确', () async {
    await LocalStore.writeJson('reading_stats', {
      '2026-05-10': 1800,
      '2026-05-11': 7200, // 最长
      '2026-05-12': 3600,
      '2025-12-31': 99999, // 非目标年份应被排除
    });
    final b = await LocalStore.yearBestDay(2026);
    expect(b['day'], '2026-05-11');
    expect(b['seconds'], 7200);
  });

  test('yearReadingBestDay 空年份返回 null day / 0 秒', () async {
    await LocalStore.writeJson('reading_stats', {'2025-06-01': 100});
    final b = await LocalStore.yearBestDay(2026);
    expect(b['day'], isNull);
    expect(b['seconds'], 0);
  });
}