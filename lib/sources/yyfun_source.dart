import 'dart:convert';

import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'source_http.dart';

/// 樱漫源：对接 yy-fun.cc 后端（PHP api.php?action=xxx）。
///
/// 实测后端有效接口（2026-08）：
///  - getComicClass            分类列表  (无参)
///  - getComicRank             排行榜    (page)
///  - getComicListByClass      按分类列表 (cid, page)
///  - getComicDetail           详情+章节 (mid=漫画ID)
///  - getChapterPics           章节图片  (cid=章节ID)
/// 注意：detail 返回的章节 id 是"章节ID"，chapterPics 必须传章节ID 而非漫画ID。
class YYFunSource extends ComicSource {
  static const String _base = 'https://comifg.yy-fun.cc';
  static const List<String> _fallbackHosts = [_base];

  /// 配置优先的 API 入口（可在源管理页覆盖，免发版）。
  Future<String> _api(String action, [Map<String, String> kv = const {}]) async {
    final host = await SourceHttp.pickHost('yyfun', _fallbackHosts);
    final params = {'action': action, ...kv};
    return Net.buildUrl('$host/api.php', params);
  }

  @override
  String get id => 'yyfun';
  @override
  String get name => '樱漫(YYFun)';

  @override
  Future<List<Category>> categories() async {
    final root = await _json(await _api('getComicClass'));
    final list = (root['data'] as List? ?? []);
    return list
        .map((o) => Category(_s((o as Map)['id']), _s(o['name'])))
        .toList();
  }

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final body = await SourceHttp.getUrl(
        'yyfun', await _api('getComicListByClass', {'cid': categoryId, 'page': '$page'}));
    return _parseList(body);
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    final body = await SourceHttp.getUrl('yyfun', await _api('getComicRank', {'page': '$page'}));
    final root = jsonDecode(body) as Map<String, dynamic>;
    final data = root['data'] as Map? ?? {};
    final list = data['list'] as List? ?? [];
    return list.map((o) => ComicItem.fromMap((o as Map).cast())).toList();
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final body = await SourceHttp.getUrl('yyfun',
        await _api('searchComic', {'keyword': keyword, 'page': '$page'}));
    return _parseList(body);
  }

  @override
  Future<ComicDetail> detail(String comicId) async {
    // getComicDetail 用 mid 参数返回漫画详情 + 章节列表。
    final root = await _json(await _api('getComicDetail', {'mid': comicId}));
    final data = root['data'] as Map? ?? {};
    final comic = data['comic'] as Map? ?? {};
    final title = _s(comic['name']);
    final pic = _s(comic['pic']);
    final author = _s(comic['author']);
    final content = _s(comic['content']);
    final chapters = <Chapter>[];
    final list = data['chapters'] as List? ?? [];
    for (final c in list) {
      final m = c as Map;
      chapters.add(Chapter(_s(m['id']), _s(m['name'])));
    }
    if (chapters.isEmpty) chapters.add(Chapter(comicId, '开始阅读'));
    final item = ComicItem(comicId, title.isEmpty ? '载入中...' : title, pic)
      ..author = author
      ..content = content;
    return ComicDetail(item, chapters);
  }

  @override
  Future<List<String>> chapterPics(String chapterId) async {
    // getChapterPics 用 cid 参数，cid 就是章节 ID。
    final root = await _json(await _api('getChapterPics', {'cid': chapterId}));
    final out = <String>[];
    final data = root['data'];
    if (data is Map) {
      final pics = data['pics'] as List?;
      if (pics != null) {
        for (final o in pics) {
          final m = o as Map;
          final url = _s(m['img']).trim();
          if (url.isNotEmpty) out.add(url);
        }
      }
    } else if (data is List) {
      out.addAll(data.map((e) => _s(e)));
    }
    return out;
  }

  List<ComicItem> _parseList(String body) {
    final root = jsonDecode(body) as Map<String, dynamic>;
    final data = root['data'];
    if (data is Map) {
      final d = data;
      if (d.containsKey('list')) return _items(d['list']);
      if (d.containsKey('data')) return _items(d['data']);
    }
    if (data is List) return _items(data);
    return [];
  }

  List<ComicItem> _items(Object? v) {
    if (v is! List) return [];
    return v.map((o) => ComicItem.fromMap((o as Map).cast())).toList();
  }

  Future<Map<String, dynamic>> _json(String url) async =>
      jsonDecode(await SourceHttp.getUrl('yyfun', url)) as Map<String, dynamic>;

  static String _s(dynamic v) => v == null ? '' : v.toString();
}
