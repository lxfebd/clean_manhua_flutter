/// 阅读统计聚合（从日粒度 reading_stats 磁盘数据算周/月/年维度）。
///
/// 从 [LocalStore] 抽出（原 local_store.dart 阅读统计域 god-class 拆分）。
/// 全部为纯函数：入参是「原始 map + 可注入时钟」，出参是聚合结果——
/// 不碰存储原语、无 UI 依赖，可单测。
///
/// 脏数据容错：reading_stats 是磁盘数据（备份恢复/旧版本可产生任意形状，
/// 键可能是非 String、值可能是 String 而非 num、日期串可能非法）。
/// 聚合一律按「可解析即计入、坏条目跳过」处理，绝不抛错崩 UI。
library;

/// 阅读统计纯函数域（无状态、无存储依赖——原始数据由调用方读取后传入）。
class ReadingStats {
  ReadingStats._();

  /// 读原始 map 中的某天秒数（值可能是 num/String/null，类型错按 0）。
  static int secOf(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  /// 规范化日粒度 map：过滤非法键/非法值，返回 { 'yyyy-MM-dd': 秒数(>0) }。
  /// 坏键（非 String / 日期非法 / 长度错）与坏值（无法转秒）一律跳过。
  static Map<String, int> normalize(Map<dynamic, dynamic> raw, {int? year}) {
    final out = <String, int>{};
    for (final e in raw.entries) {
      final k = e.key;
      if (k is! String || k.length < 10) continue;
      if (year != null && !k.startsWith('$year-')) continue;
      // 只认 yyyy-MM-dd 形状的键（前 10 位是日期，后段容忍任意后缀）
      final datePart = k.substring(0, 10);
      final d = DateTime.tryParse(datePart);
      if (d == null) continue;
      final sec = secOf(e.value);
      if (sec <= 0) continue;
      out[k] = sec;
    }
    return out;
  }

  /// 周（最近 7 天）阅读秒数总和。
  static int weekSeconds(Map<dynamic, dynamic> raw,
      {DateTime Function()? now}) {
    final nowFn = now ?? DateTime.now;
    final n = nowFn();
    var sum = 0;
    for (var i = 0; i < 7; i++) {
      final d = n.subtract(Duration(days: i));
      final key = dayKeyOf(d);
      // 周聚合不要求键是合法日期（只要匹配今天往前 7 天的 key 串）
      sum += secOf(raw[key]);
    }
    return sum;
  }

  /// 全部累计阅读秒数。
  static int totalSeconds(Map<dynamic, dynamic> raw) {
    var sum = 0;
    for (final v in raw.values) {
      sum += secOf(v);
    }
    return sum;
  }

  /// 最近 N 天每天的阅读秒数（按日期升序 [{day, seconds}]）。
  static List<Map<String, dynamic>> recentDays(Map<dynamic, dynamic> raw,
      int n,
      {DateTime Function()? now}) {
    final nowFn = now ?? DateTime.now;
    final d0 = nowFn();
    final out = <Map<String, dynamic>>[];
    for (var i = n - 1; i >= 0; i--) {
      final d = d0.subtract(Duration(days: i));
      final key = dayKeyOf(d);
      out.add({'day': key, 'seconds': secOf(raw[key])});
    }
    return out;
  }

  /// 最近 N 个月每月的阅读秒数（按月份升序 [{month:'2026-08', seconds}]）。
  static List<Map<String, dynamic>> recentMonths(Map<dynamic, dynamic> raw,
      int n,
      {DateTime Function()? now}) {
    final nowFn = now ?? DateTime.now;
    final n0 = nowFn();
    final out = <Map<String, dynamic>>[];
    for (var i = n - 1; i >= 0; i--) {
      final month = DateTime(n0.year, n0.month - i, 1);
      final key = monthKeyOf(month);
      var sum = 0;
      for (final e in raw.entries) {
        final k = e.key;
        if (k is! String || k.length < 7) continue;
        if (k.startsWith(key)) sum += secOf(e.value);
      }
      out.add({'month': key, 'seconds': sum});
    }
    return out;
  }

  /// 指定年份的月度阅读统计（全年 12 个月升序 [{month:'2026-01', seconds}]）。
  static List<Map<String, dynamic>> yearMonths(
      Map<dynamic, dynamic> raw, int year) {
    final out = <Map<String, dynamic>>[];
    for (var mo = 1; mo <= 12; mo++) {
      final key = '$year-${mo.toString().padLeft(2, '0')}';
      var sum = 0;
      for (final e in raw.entries) {
        final k = e.key;
        if (k is! String || k.length < 7) continue;
        if (k.startsWith(key)) sum += secOf(e.value);
      }
      out.add({'month': key, 'seconds': sum});
    }
    return out;
  }

  /// 指定年份的总阅读秒数。
  static int yearSeconds(Map<dynamic, dynamic> raw, [int? year]) {
    var sum = 0;
    for (final e in raw.entries) {
      final k = e.key;
      if (k is! String) continue;
      if (year != null && !k.startsWith('$year')) continue;
      sum += secOf(e.value);
    }
    return sum;
  }

  /// 有效阅读天数（秒数 > 0）；可传年份限定。
  static int activeDays(Map<dynamic, dynamic> raw, [int? year]) {
    var count = 0;
    for (final e in raw.entries) {
      final k = e.key;
      if (k is! String) continue;
      if (year != null && !k.startsWith('$year')) continue;
      if (secOf(e.value) > 0) count++;
    }
    return count;
  }

  /// 指定年份的最长连续阅读记录（纯读取，不落盘）。
  ///
  /// 从日粒度 reading_stats 聚合：把该年阅读秒数 > 0 的日期串成有序天集合，
  /// 找最长连续区间，返回 { maxStreak, bestStart, bestEnd, bestSeconds }。
  /// maxStreak=0 表示该年无任何阅读记录。
  static Map<String, dynamic> yearStreak(Map<dynamic, dynamic> raw, int year) {
    final days = normalize(raw, year: year);
    if (days.isEmpty) {
      return {
        'maxStreak': 0,
        'bestStart': null,
        'bestEnd': null,
        'bestSeconds': 0
      };
    }
    final sorted = days.keys.toList()..sort();
    var bestStart = sorted.first;
    var bestEnd = sorted.first;
    var curStart = sorted.first;
    var curEnd = sorted.first;
    var curStreak = 1;
    var maxStreak = 1;
    for (var i = 1; i < sorted.length; i++) {
      final prev = DateTime.parse(sorted[i - 1]);
      final cur = DateTime.parse(sorted[i]);
      // 相邻两天（差 1 天）延续当前连续段；否则开新段
      if (cur.difference(prev).inDays == 1) {
        curEnd = sorted[i];
        curStreak++;
      } else {
        curStart = sorted[i];
        curEnd = sorted[i];
        curStreak = 1;
      }
      if (curStreak > maxStreak) {
        maxStreak = curStreak;
        bestStart = curStart;
        bestEnd = curEnd;
      }
    }
    // 最佳连续区间内的累计时长
    var bestSeconds = 0;
    for (var d = DateTime.parse(bestStart);
        !d.isAfter(DateTime.parse(bestEnd));
        d = d.add(const Duration(days: 1))) {
      bestSeconds += days[dayKeyOf(d)] ?? 0;
    }
    return {
      'maxStreak': maxStreak,
      'bestStart': bestStart,
      'bestEnd': bestEnd,
      'bestSeconds': bestSeconds,
    };
  }

  /// 指定年份的单日最长阅读记录（纯读取）。
  /// 返回 { day, seconds }；无记录时 seconds=0。
  static Map<String, dynamic> yearBestDay(
      Map<dynamic, dynamic> raw, int year) {
    String? bestDay;
    var bestSec = 0;
    for (final e in raw.entries) {
      final k = e.key;
      if (k is! String || k.length < 10) continue;
      final datePart = k.substring(0, 10);
      if (!datePart.startsWith('$year-')) continue;
      if (DateTime.tryParse(datePart) == null) continue;
      final sec = secOf(e.value);
      if (sec > bestSec) {
        bestSec = sec;
        bestDay = k;
      }
    }
    return {'day': bestDay, 'seconds': bestSec};
  }

  /// 今日 key（yyyy-MM-dd）。
  static String dayKeyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 月份 key（yyyy-MM）。
  static String monthKeyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  /// JSON 反序列化 reading_stats 原始 map 的容错入口：
  /// 顶层不是 map / 含坏键值都交给各聚合函数自行跳过。
  static Map<dynamic, dynamic> decodeRaw(dynamic json) {
    if (json is Map) return json;
    return const {};
  }
}