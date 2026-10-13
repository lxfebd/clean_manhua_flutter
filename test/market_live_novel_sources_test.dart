import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_novel_source.dart';

/// 市场 novel 源的**真实网络**链路验证：榜单 → 详情 → 章节目录 → 正文段落。
///
/// 与 [dsl_verify_live_sources_test]（离线快照、防站点改版）互补：这里跑真站点，
/// 证明「装进市场后确实能读到内容」，而不是只通过 validate()。
///
/// CI 不出网：仅当环境变量 `XM_LIVE=1` 时执行。本地验证：
/// `$env:XM_LIVE=1; flutter test test/market_live_novel_sources_test.dart`
void main() {
  final liveOn = (Platform.environment['XM_LIVE'] ?? '').trim() == '1';
  final skip = liveOn ? null : '设置 XM_LIVE=1 才跑真实站点验证';

  for (final path in const [
    'sources/shuhaige_novel.json',
    'sources/miaobige_novel.json',
    'sources/quanben5_novel.json',
  ]) {
    test('live 小说源 $path：DSL 校验', () {
      final d = decodeCustomSourceDef(File(path).readAsStringSync());
      expect(d, isNotNull);
      expect(d!.validate(), isEmpty);
    }, skip: skip);

    test('live 小说源 $path：榜单 → 详情 → 章节 → 正文', () async {
      final d = decodeCustomSourceDef(File(path).readAsStringSync())!;
      final src = DslNovelSource(d);

      final rank = await src.rank(1);
      expect(rank.length, greaterThan(3), reason: '榜单为空：装进市场首屏就是空的');
      expect(rank.first.id.isNotEmpty, isTrue);
      expect(rank.first.name.trim().isNotEmpty, isTrue);

      final detail = await src.detail(rank.first.id);
      expect(detail.name.trim().isNotEmpty, isTrue, reason: '书名抽取失败');
      expect(detail.chapters.length, greaterThan(5), reason: '章节目录为空');

      // 正文：取前几章里第一章有内容的（跳过公告/番外类空章）
      String? chapterId;
      var paragraphs = const <String>[];
      for (final ch in detail.chapters.take(6)) {
        final c = await src.chapterContent(ch.id);
        if (c.paragraphs.length > 3) {
          chapterId = ch.id;
          paragraphs = c.paragraphs;
          break;
        }
      }
      expect(chapterId, isNotNull, reason: '正文段落抽取失败');
      expect(paragraphs.length, greaterThan(3));
      expect(paragraphs.first.length, greaterThan(4));
      // 慢源站（如全本小说网 TTFB 可达 10s+）单条链路会超过默认 30s 用例上限
    }, skip: skip, timeout: const Timeout(Duration(seconds: 150)));

    test('live 小说源 $path：分类导航与分类列表', () async {
      final d = decodeCustomSourceDef(File(path).readAsStringSync())!;
      final src = DslNovelSource(d);
      final cats = await src.categories();
      expect(cats.length, greaterThan(2), reason: '分类为空');
      expect(cats.first.id.isNotEmpty, isTrue);
      final list = await src.listByCategory(cats.first.id, 1);
      expect(list.length, greaterThan(2), reason: '分类列表为空');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 120)));
  }
}
