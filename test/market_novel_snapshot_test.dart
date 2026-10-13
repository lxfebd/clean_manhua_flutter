import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_novel_source.dart';

/// 小说源**离线快照**回归：把本机保存的真实页面（tmpprobe/market/*.html）挂到
/// 回环 HTTP，用 [sources] 目录里的源 JSON 原文（仅把站点域名换成本机）跑
/// 榜单 → 分类 → 详情 → 章节 → 正文 全链路。
///
/// 目的：源规则一旦与真实页面结构脱节（站点改版），这里会红；
/// 与 [market_live_novel_sources_test]（真站点、需 XM_LIVE=1）互补。
/// 快照目录不在仓库内：缺失时整组跳过，CI 不受影响。
void main() {
  final snap = _findSnapshots();
  final skip = snap == null ? '缺少 tmpprobe/market 页面快照，跳过离线回归' : null;

  late HttpServer server;

  tearDown(() async => server.close(force: true));

  /// 起一台只服务本站快照的本机服务器，返回 base。
  Future<String> start(Map<String, String> exact,
      {RegExp? chapterRe, String? chapterFile}) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://${server.address.address}:${server.port}';
    server.listen((req) {
      final path = req.uri.path;
      var file = exact[path];
      if (file == null && chapterRe != null && chapterRe.hasMatch(path)) {
        file = chapterFile;
      }
      final f = file == null ? null : File('${snap!.path}/$file');
      if (f == null || !f.existsSync()) {
        req.response.statusCode = 404;
        req.response.write('missing snapshot: $path');
        req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.html;
      req.response.write(f.readAsStringSync());
      req.response.close();
    });
    return base;
  }

  /// 源 JSON 原文 → 本地可跑的定义（域名换成本机回环）。
  CustomSourceDef localDef(String file, String siteHost, String base) =>
      decodeCustomSourceDef(
          File('sources/$file').readAsStringSync().replaceAll(siteHost, base))!;

  group('书海阁小说 离线快照', () {
    test('榜单 → 分类 → 详情 → 章节 → 正文', () async {
      final base = await start({
        '/': 'sh_home.html',
        '/allvisit/1.html': 'sh_rank.html',
        '/XuanHuan/': 'sh_cat.html',
        '/446052/': 'sh_detail.html',
      },
          chapterRe: RegExp(r'^/\d+/\d+\.html$'),
          chapterFile: 'sh_chap.html');
      final src = DslNovelSource(
          localDef('shuhaige_novel.json', 'https://www.shuhaige.net', base));

      final rank = await src.rank(1);
      expect(rank.length, greaterThan(3), reason: '榜单页结构变了');
      expect(rank.first.id.isNotEmpty, isTrue);
      expect(rank.first.name.trim().isNotEmpty, isTrue);

      final cats = await src.categories();
      expect(cats.length, greaterThan(2), reason: '分类导航结构变了');
      final list = await src.listByCategory(cats.first.id, 1);
      expect(list.length, greaterThan(2), reason: '分类列表结构变了');

      final detail = await src.detail('446052/');
      expect(detail.name.trim().isNotEmpty, isTrue, reason: '书名抽取失败');
      expect(detail.chapters.length, greaterThan(5), reason: '章节目录结构变了');

      final content = await src.chapterContent(detail.chapters.first.id);
      expect(content.paragraphs.length, greaterThan(3), reason: '正文结构变了');
    }, skip: skip);
  });

  group('妙笔阁小说 离线快照', () {
    test('榜单 → 分类 → 详情 → 章节 → 正文', () async {
      final base = await start({
        '/': 'mb_home.html',
        '/top/allvisit_1.html': 'mb_rank.html',
        '/xuanhuan/1.html': 'mb_cat.html',
        '/shu/98478/': 'mb_detail.html',
      },
          chapterRe: RegExp(r'^/shu/\d+/\d+\.html$'),
          chapterFile: 'mb_chap.html');
      final src = DslNovelSource(
          localDef('miaobige_novel.json', 'https://www.miaobige.com', base));

      final rank = await src.rank(1);
      expect(rank.length, greaterThan(3), reason: '榜单页结构变了');

      final cats = await src.categories();
      expect(cats.length, greaterThan(2), reason: '分类导航结构变了');
      final list = await src.listByCategory(cats.first.id, 1);
      expect(list.length, greaterThan(2), reason: '分类列表结构变了');

      final detail = await src.detail('shu/98478/');
      expect(detail.name.trim().isNotEmpty, isTrue, reason: '书名抽取失败');
      expect(detail.chapters.length, greaterThan(5), reason: '章节目录结构变了');

      final content = await src.chapterContent(detail.chapters.first.id);
      expect(content.paragraphs.length, greaterThan(3), reason: '正文结构变了');
      // 正文里的版权提示/推广行应被 picFilter 滤掉
      expect(content.paragraphs.any((p) => p.startsWith('如果此书')), isFalse);
      expect(content.paragraphs.any((p) => p.contains('请大家收藏')), isFalse);
    }, skip: skip);
  });
}

Directory? _findSnapshots() {
  final root = Directory.current.absolute;
  for (final c in [
    Directory('${root.path}/../tmpprobe/market'),
    Directory('tmpprobe/market'),
  ]) {
    if (c.existsSync()) return c;
  }
  return null;
}
