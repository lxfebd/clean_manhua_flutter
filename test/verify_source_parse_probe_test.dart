import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/source_health_monitor.dart';
import 'package:xingmanxia/sources/local_novel_source.dart';
import 'package:xingmanxia/sources/source_manager.dart';

/// 源解析探测的真网契约。
///
/// 单元测试（regression_source_parse_probe_test.dart）只覆盖合并语义；
/// 这里覆盖「这段代码在真实源上真的能跑通」——`_parseOne` 走的是
/// `rank(1)`（漫画/小说）与 `categories()+listByCategory()`（视频），
/// 这条路径此前从未被执行过，必须在真网上验证一次才算做完。
///
/// **判定口径（2026-11-27 改）**：只有 `ParseOutcome.drift`
///（请求成功、解析成功、但 0 条）才算失败。unreachable（403 / 超时 /
/// 非 JSON）只打印 INFO——反爬网关返回的 HTML 挑战页同样会让 jsonDecode
/// 抛 FormatException，且 GitHub runner 在海外访问国内源天然 403/重置，
/// 用这些证据去开 issue 只会产生噪声、训练用户忽略警报。
///
/// 用法与其它 verify_* 一致：默认跳过，需要时传
/// `--dart-define=LIVE_SOURCE_TESTS=true`（每日 source-health workflow 带着跑）。

const bool _skipLive = !bool.fromEnvironment('LIVE_SOURCE_TESTS');

void main() {
  test('所有启用源：解析出条目，或仅因不可达而未验证（真网）', () async {
    final mon = SourceHealthMonitor.instance;
    final drift = <String>[]; // 契约变更——要修
    final unreachable = <String>[]; // 环境噪声——只记录

    Future<void> probe(String domain, String name, dynamic s) async {
      final r = await mon.debugParseOne(s);
      final tag = r.outcome == ParseOutcome.drift
          ? 'FAIL'
          : r.outcome == ParseOutcome.unreachable
              ? 'INFO'
              : 'OK  ';
      // ignore: avoid_print
      print('  $tag $domain $name: items=${r.items} err=${r.error}');
      if (r.outcome == ParseOutcome.drift) {
        drift.add('$domain/$name: ${r.error}');
      } else if (r.outcome == ParseOutcome.unreachable) {
        unreachable.add('$domain/$name: ${r.error}');
      }
    }

    for (final s in SourceManager.sources) {
      if (s.isEnabled) await probe('comic', s.name, s);
    }
    for (final s in SourceManager.novelSources) {
      if (!s.isEnabled) continue;
      // 本地导入的 rank() 恒为空（本地书没有远端榜单），不参与解析探测。
      if (s is LocalNovelSource) continue;
      await probe('novel', s.name, s);
    }
    for (final s in SourceManager.videoSources) {
      if (s.isEnabled) await probe('video', s.name, s);
    }

    // ignore: avoid_print
    print('---- drift=${drift.length} unreachable=${unreachable.length} ----');

    expect(drift, isEmpty,
        reason: '以下源请求成功但解析不出条目 = 契约已变更，必须修：\n'
            '${drift.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 4)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
