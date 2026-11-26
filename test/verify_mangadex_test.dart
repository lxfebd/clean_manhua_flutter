import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/source_health_monitor.dart';
import 'package:xingmanxia/sources/mangadex_source.dart';

/// MangaDex 真网契约（修复 POWBlock 反爬后的回归）。
///
/// 2026-11 起 api.mangadex.org 前置 POWBlock 工作量证明网关，
/// 伪装浏览器 UA 会被返回 HTML 挑战页。本源改用规范应用 UA 后，
/// rank / detail(+feed) / chapterPics / search 四条链路都必须真的通。
///
/// 与其它 verify_* 一致：默认跳过，需要时传
/// `--dart-define=LIVE_SOURCE_TESTS=true`。
const bool _skipLive = !bool.fromEnvironment('LIVE_SOURCE_TESTS');

void main() {
  final src = MangaDexSource();

  test('rank：榜单取到条目且封面可构造', () async {
    final list = await src.rank(1);
    // ignore: avoid_print
    print('  rank items=${list.length}');
    expect(list, isNotEmpty, reason: '榜单解析为空 = 很可能又被反爬拦成 HTML');
    expect(list.first.id, isNotEmpty);
    expect(list.first.name, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);

  test('search：关键词搜索返回结果', () async {
    final list = await src.search('one', 1);
    // ignore: avoid_print
    print('  search items=${list.length}');
    expect(list, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);

  test('detail + feed + chapterPics：详情→章节→图片全链路', () async {
    final list = await src.rank(1);
    expect(list, isNotEmpty);
    // 榜单头部作品未必有中/英章节，往后找第一个有章节的，最多试 5 个。
    for (final item in list.take(5)) {
      final d = await src.detail(item.id);
      // ignore: avoid_print
      print('  detail ${item.name}: chapters=${d.chapters.length} '
          'tags=${d.tags.length} status=${d.status}');
      if (d.chapters.isEmpty) continue;
      final pics = await src.chapterPics(d.chapters.first.id);
      // ignore: avoid_print
      print('  chapterPics: ${pics.length} pages '
          'first=${pics.isNotEmpty ? pics.first : "-"}');
      expect(pics, isNotEmpty, reason: '章节拿不到图片');
      expect(pics.first, startsWith('https://uploads.mangadex.org/data/'));
      return;
    }
    fail('榜单前 5 部作品都没有可读章节，检查 feed 的 translatedLanguage 过滤');
  }, timeout: const Timeout(Duration(minutes: 3)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);

  test('解析探测本身对 MangaDex 通过（这正是每日契约红的那一项）', () async {
    final r = await SourceHealthMonitor.instance.debugParseOne(src);
    // ignore: avoid_print
    print('  parseProbe ok=${r.ok} items=${r.items} err=${r.error}');
    expect(r.ok, isTrue, reason: '解析探测失败：${r.error}');
    expect(r.error, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
