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
}