import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/reading_stats.dart';

/// ReadingStats 纯函数域单测（god-class 拆分产物）。
///
/// 双向验证：
/// 1. 正向聚合与旧 LocalStore 实现语义一致（week/year/bestDay/streak）。
/// 2. 脏数据容错——reading_stats 是磁盘数据（备份恢复/旧版本可产生任意
///    形状：int key、String 值、非法日期、非 map 顶层），聚合绝不抛错：
///    「可解析即计入、坏条目跳过」（旧实现在这些形状下抛 TypeError——
///    as num? 对 String、entry.key as String? 对 int key、DateTime.parse
///    对非法日期串）。
void main() {
  group('ReadingStats 正向聚合', () {
    test('weekSeconds 最近 7 天求和（含今天）', () {
      final now = DateTime(2026, 10, 10, 12);
      final raw = <dynamic, dynamic>{
        '2026-10-04': 100, // 恰好 7 天前
        '2026-10-05': 200,
        '2026-10-06': 300,
        '2026-10-10': 1000, // 今天
      };
      expect(ReadingStats.weekSeconds(raw, now: () => now), 1600);
    });

    test('totalSeconds 全部累计', () {
      final raw = <dynamic, dynamic>{'a': 100, 'b': 200, 'c': 300};
      expect(ReadingStats.totalSeconds(raw), 600);
    });

    test('yearMonths 全年 12 个月且聚合正确', () {
      final raw = <dynamic, dynamic>{
        '2026-01-05': 60,
        '2026-01-20': 40,
        '2026-12-31': 999,
      };
      final months = ReadingStats.yearMonths(raw, 2026);
      expect(months.length, 12);
      expect(months[0]['month'], '2026-01');
      expect(months[0]['seconds'], 100);
      expect(months[11]['month'], '2026-12');
      expect(months[11]['seconds'], 999);
    });

    test('yearSeconds / activeDays 指定年份限定', () {
      final raw = <dynamic, dynamic>{
        '2025-12-31': 100,
        '2026-01-01': 200,
        '2026-01-02': 0, // 0 秒不计 active
      };
      expect(ReadingStats.yearSeconds(raw, 2026), 200);
      expect(ReadingStats.yearSeconds(raw), 300);
      expect(ReadingStats.activeDays(raw, 2026), 1);
    });

    test('yearStreak 最长连续区间（含跨月）', () {
      final raw = <dynamic, dynamic>{
        '2026-01-01': 600,
        '2026-01-02': 300,
        '2026-01-03': 1200,
        '2026-01-04': 60,
        '2026-01-06': 900,
        '2026-01-07': 100,
        '2026-01-30': 500,
        '2026-01-31': 500,
        '2026-02-01': 500,
      };
      final s = ReadingStats.yearStreak(raw, 2026);
      expect(s['maxStreak'], 4);
      expect(s['bestStart'], '2026-01-01');
      expect(s['bestEnd'], '2026-01-04');
      expect(s['bestSeconds'], 2160);
    });

    test('yearStreak 空年份返回 0 连续', () {
      final s = ReadingStats.yearStreak({'2025-12-31': 100}, 2026);
      expect(s['maxStreak'], 0);
      expect(s['bestStart'], isNull);
      expect(s['bestSeconds'], 0);
    });

    test('yearBestDay 单日最长', () {
      final raw = <dynamic, dynamic>{
        '2026-05-10': 1800,
        '2026-05-11': 7200,
        '2026-05-12': 3600,
        '2025-12-31': 99999,
      };
      final b = ReadingStats.yearBestDay(raw, 2026);
      expect(b['day'], '2026-05-11');
      expect(b['seconds'], 7200);
    });

    test('dayKeyOf / monthKeyOf 补零', () {
      expect(ReadingStats.dayKeyOf(DateTime(2026, 1, 2)), '2026-01-02');
      expect(ReadingStats.monthKeyOf(DateTime(2026, 11)), '2026-11');
    });
  });

  group('ReadingStats 脏数据容错', () {
    test('int key / String 值 / 非法日期：不抛且跳过', () {
      // 旧实现崩溃点 1：entry.key as String?（int key 抛 TypeError）
      // 旧实现崩溃点 2：entry.value as num?（String 值抛 TypeError）
      // 旧实现崩溃点 3：DateTime.parse（非法日期串抛 FormatException）
      final raw = <dynamic, dynamic>{
        123: 5, // int key
        'not-a-date': '10', // 非法日期 + String 值
        '2026-01-01': '3600', // String 秒值 → 按 3600 计入
        '2026-01-02': 42, // 正常
      };
      expect(
        () => ReadingStats.yearStreak(raw, 2026),
        returnsNormally,
      );
      final s = ReadingStats.yearStreak(raw, 2026);
      expect(s['maxStreak'], 2, reason: '两正常天 01-01/01-02 连续');
      expect(s['bestSeconds'], 3642);

      // 各聚合对同一脏数据都不抛
      expect(ReadingStats.yearSeconds(raw, 2026), 3642);
      expect(ReadingStats.activeDays(raw, 2026), 2);
      final months = ReadingStats.yearMonths(raw, 2026);
      expect(months[0]['seconds'], 3642);
      expect(ReadingStats.yearBestDay(raw, 2026)['seconds'], 3600);
    });

    test('非 map 顶层：decodeRaw 归零不抛', () {
      expect(ReadingStats.decodeRaw(null), isEmpty);
      expect(ReadingStats.decodeRaw('oops'), isEmpty);
      expect(ReadingStats.decodeRaw([1, 2]), isEmpty);
      final raw = ReadingStats.decodeRaw({'2026-01-01': 1});
      expect(ReadingStats.totalSeconds(raw), 1);
    });

    test('secOf 各种形状', () {
      expect(ReadingStats.secOf(10), 10);
      expect(ReadingStats.secOf(10.7), 10);
      expect(ReadingStats.secOf('3600'), 3600);
      expect(ReadingStats.secOf('oops'), 0);
      expect(ReadingStats.secOf(null), 0);
      expect(ReadingStats.secOf([1]), 0);
    });
  });
}