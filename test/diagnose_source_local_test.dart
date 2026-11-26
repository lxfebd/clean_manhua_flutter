import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/source_health_monitor.dart';
import 'package:xingmanxia/sources/agedm_video_source.dart';
import 'package:xingmanxia/sources/ashan_yingyuan_video_source.dart';
import 'package:xingmanxia/sources/wche_dm_video_source.dart';
import 'package:xingmanxia/sources/xbiquge_novel_source.dart';

/// 源站「本机可用性」诊断（真网）。
///
/// ## 为什么单独一个文件
/// 每日 `source-health.yml` 跑在 **GitHub 海外 runner** 上。国内源（AGE / 风车 /
/// 鞍山 / 新笔趣阁）在那台机器上经常因为跨境链路被拦，表现为 403 / Timeout /
/// ClientException——**那是 runner 的网络问题，不是源站坏了**。
///
/// 2026-11-27 实测：这四个域名在本机（国内网络）全部 200，深层列表页也正常：
/// | 源 | 探针真实路径 | 本机结果 |
/// |---|---|---|
/// | AGE 动漫 | `GET /catalog/all-all-all-all-all-time-1` | 200, 24 条目 |
/// | 风车动漫 | `GET /html/1.html` | 200, 400 卡片 |
/// | 鞍山影院 | `GET /so-show/1`（HTTP） | 200 |
/// | 新笔趣阁 | `GET /fenlei/1/1.html` | 200 |
///
/// 所以这四项在 CI 里红，**不能**据此判定"源死了"。要判死必须在本机跑本文件。
///
/// 用法：`flutter test test/diagnose_source_local_test.dart --dart-define=LIVE_SOURCE_TESTS=true`
const bool _skipLive = !bool.fromEnvironment('LIVE_SOURCE_TESTS');

void main() {
  final mon = SourceHealthMonitor.instance;

  /// 断言某源在本机能解析出条目（这是"源活着"的唯一可靠信号：
  /// HTTP 200 只说明首页能给文字，解析出条目才说明结构没变）。
  Future<void> expectParseOk(String label, dynamic src) async {
    final r = await mon.debugParseOne(src);
    // ignore: avoid_print
    print('  $label: ok=${r.ok} items=${r.items} err=${r.error}');
    expect(r.ok, isTrue, reason: '$label 本机解析失败：${r.error}');
    expect(r.items, greaterThan(0), reason: '$label 解析出 0 条');
  }

  test('AGE 动漫：categories + listByCategory 能解出条目', () async {
    await expectParseOk('AGE 动漫', AgedMVideoSource());
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);

  test('风车动漫：categories + listByCategory 能解出条目', () async {
    await expectParseOk('风车动漫', WcheDmVideoSource());
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);

  test('鞍山影院：categories + listByCategory 能解出条目（HTTP 源）', () async {
    await expectParseOk('鞍山影院', AshanYingyuanVideoSource());
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);

  test('新笔趣阁：rank 能解出条目', () async {
    await expectParseOk('新笔趣阁', XbiqugeNovelSource());
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
