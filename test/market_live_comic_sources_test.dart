import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_comic_source.dart';

/// 市场 comic 源的**真实网络**链路验证：排行 → 详情 → 章节目录 → 章节图片。
///
/// 与 [market_live_novel_sources_test]（novel 侧）同理：证明「装进市场后确实能
/// 翻到页」，而不是只通过 validate()。漫画源最容易出现的假阳性是「列表能出、
/// 章节能出、但图片是 JS 注入的」——只有真取到图片 URL 才算可用。
///
/// CI 不出网：仅当环境变量 `XM_LIVE=1` 时执行。本地验证：
/// `$env:XM_LIVE=1; flutter test test/market_live_comic_sources_test.dart`
void main() {
  final liveOn = (Platform.environment['XM_LIVE'] ?? '').trim() == '1';
  final skip = liveOn ? null : '设置 XM_LIVE=1 才跑真实站点验证';

  for (final path in const [
    'sources/manhuawang_comic.json',
  ]) {
    test('live 漫画源 $path：DSL 校验', () {
      final d = decodeCustomSourceDef(File(path).readAsStringSync());
      expect(d, isNotNull);
      expect(d!.validate(), isEmpty);
    }, skip: skip);

    test('live 漫画源 $path：排行 → 详情 → 章节 → 章节图片', () async {
      final d = decodeCustomSourceDef(File(path).readAsStringSync())!;
      final src = DslComicSource(d);

      final rank = await src.rank(1);
      expect(rank.length, greaterThan(3), reason: '首屏排行为空：装进市场就是空页');
      expect(rank.first.id.isNotEmpty, isTrue);
      expect(rank.first.name.trim().isNotEmpty, isTrue);
      // 封面缺失时列表卡片会走 picFallback/占位，这里要求真实取到封面
      expect(rank.first.pic, contains('http'), reason: '列表封面抽取失败');

      final detail = await src.detail(rank.first.id);
      expect(detail.name.trim().isNotEmpty, isTrue, reason: '标题抽取失败');
      expect(detail.chapters, isNotEmpty, reason: '章节目录为空');

      // 首条可能是只有 1~2 卷的短篇：在前几条里找一本真正能翻的漫画
      var checked = 0;
      String? picUrl;
      for (final item in rank.take(5)) {
        final d = await src.detail(item.id);
        if (d.chapters.isEmpty) continue;
        checked = d.chapters.length;
        final pics = await src.chapterPics(d.chapters.first.id);
        if (pics.isNotEmpty) {
          picUrl = pics.first;
          break;
        }
      }
      expect(picUrl, isNotNull, reason: '前 5 本都取不到章节图片（可能是 JS 注入图）');
      expect(picUrl, startsWith('http'), reason: '图片不是可用 URL');
      expect(picUrl, isNot(contains('base64')), reason: '取到的是 lazyload 占位图');
      expect(checked, greaterThan(0));
    }, skip: skip, timeout: const Timeout(Duration(seconds: 120)));

    test('live 漫画源 $path：分类导航与分类列表', () async {
      final d = decodeCustomSourceDef(File(path).readAsStringSync())!;
      final src = DslComicSource(d);
      final cats = await src.categories();
      expect(cats.length, greaterThan(1), reason: '分类为空');
      expect(cats.first.id.isNotEmpty, isTrue);
      final list = await src.listByCategory(cats.first.id, 1);
      expect(list.length, greaterThan(2), reason: '分类列表为空');
      // 分类翻页必须真的换内容，否则「加载更多」会重复同一页
      final next = await src.listByCategory(cats.first.id, 2);
      expect(next.map((e) => e.id).toSet().intersection(list.map((e) => e.id).toSet()),
          isEmpty,
          reason: '分类第 2 页与第 1 页内容相同：分页无效');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 120)));
  }
}
