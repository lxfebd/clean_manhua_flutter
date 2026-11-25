import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/source_health_monitor.dart';
import 'package:xingmanxia/sources/source_manager.dart';

/// 源解析探测的真网契约。
///
/// 单元测试（regression_source_parse_probe_test.dart）只覆盖合并语义；
/// 这里覆盖「这段代码在真实源上真的能跑通」——`_parseOne` 走的是
/// `rank(1)`（漫画/小说）与 `categories()+listByCategory()`（视频），
/// 这条路径此前从未被执行过，必须在真网上验证一次才算做完。
///
/// 用法与其它 verify_* 一致：默认跳过，需要时传
/// `--dart-define=LIVE_SOURCE_TESTS=true`（每日 source-health workflow
/// 已经带着这个开关跑）。

const bool _skipLive = !bool.fromEnvironment('LIVE_SOURCE_TESTS');

void main() {
  test('所有启用源的解析探测都能返回条目（真网）', () async {
    final mon = SourceHealthMonitor.instance;
    final bad = <String>[];

    for (final s in SourceManager.sources) {
      if (!s.isEnabled) continue;
      final r = await mon.debugParseOne(s);
      // ignore: avoid_print
      print('  comic ${r.ok ? "OK " : "FAIL"} ${s.name}: '
          'items=${r.items} err=${r.error}');
      if (!r.ok) bad.add('comic/${s.name}: ${r.error}');
    }
    for (final s in SourceManager.novelSources) {
      if (!s.isEnabled) continue;
      final r = await mon.debugParseOne(s);
      // ignore: avoid_print
      print('  novel ${r.ok ? "OK " : "FAIL"} ${s.name}: '
          'items=${r.items} err=${r.error}');
      if (!r.ok) bad.add('novel/${s.name}: ${r.error}');
    }
    for (final s in SourceManager.videoSources) {
      if (!s.isEnabled) continue;
      final r = await mon.debugParseOne(s);
      // ignore: avoid_print
      print('  video ${r.ok ? "OK " : "FAIL"} ${s.name}: '
          'items=${r.items} err=${r.error}');
      if (!r.ok) bad.add('video/${s.name}: ${r.error}');
    }

    expect(bad, isEmpty,
        reason: '解析探测取不到内容的源（页面结构可能已变）：\n${bad.join("\n")}');
  }, timeout: const Timeout(Duration(minutes: 4)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}