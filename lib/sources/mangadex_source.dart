import 'dart:convert';

import '../models/comic_item.dart';
import 'comic_source.dart';
import 'source_http.dart';

/// MangaDex 官方 API 图源。
/// 接口文档: https://api.mangadex.org/docs/
/// 无 R18；不强制登录；完全公共可用，遵守服务器端 rate limit。
class MangaDexSource extends ComicSource {
  static const String _api = 'https://api.mangadex.org';
  static const String _coverBase = 'https://uploads.mangadex.org/covers';
  static const List<String> _fallbackHosts = [_api];

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Accept': 'application/json',
  };

  @override
  String get id => 'mangadex';
  @override
  String get name => 'MangaDex';

  static final _categories = <Category>[
    Category('trending', '热门'),
    Category('latest', '最新更新'),
    Category('rating', '高分推荐'),
    Category('createdAt', '新作品'),
  ];

  @override
  Future<List<Category>> categories() async => _categories;

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final offset = (page - 1) * 20;
    final order = _orderParam(categoryId);
    final api = await _apiHost();
    final url = '$api/manga?limit=20&offset=$offset'
        '&order[$order]=desc&contentRating[]=safe&contentRating[]=suggestive'
        '&contentRating[]=erotica&includes[]=cover_art';
    return _mangaList(url);
  }

  @override
  Future<List<ComicItem>> rank(int page) async => listByCategory('rating', page);

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final offset = (page - 1) * 20;
    final api = await _apiHost();
    final url = '$api/manga?limit=20&offset=$offset'
        '&title=${Uri.encodeQueryComponent(keyword)}'
        '&contentRating[]=safe&contentRating[]=suggestive'
        '&contentRating[]=erotica&includes[]=cover_art';
    return _mangaList(url);
  }

  @override
  Future<ComicDetail> detail(String comicId) async {
    final api = await _apiHost();
    final url = '$api/manga/$comicId?includes[]=cover_art&includes[]=author'
        '&includes[]=artist';
    final body = await _get(url);
    final root = jsonDecode(body) as Map<String, dynamic>;
    final data = root['data'] as Map<String, dynamic>;
    final attrs = data['attributes'] as Map<String, dynamic>;
    final rels = (data['relationships'] as List? ?? []);
    final item = _mangaFromData(data, rels, attrs);
    final desc = _pickLocalized(attrs['description']) ?? '';
    item.content = desc;

    final api2 = await _apiHost();
    final chUrl = '$api2/manga/$comicId/feed?limit=500&order[chapter]=asc'
        '&translatedLanguage[]=zh&translatedLanguage[]=zh-hk'
        '&translatedLanguage[]=zh-tw&translatedLanguage[]=en';
    final chBody = await _get(chUrl);
    final chRoot = jsonDecode(chBody) as Map<String, dynamic>;
    final chData = (chRoot['data'] as List? ?? []);
    final chapters = <Chapter>[];
    for (final c in chData) {
      final a = c['attributes'] as Map<String, dynamic>;
      final num = (a['chapter'] as String?) ?? '';
      final title = (a['title'] as String?) ?? '';
      final lang = (a['translatedLanguage'] as String?) ?? '';
      final label = num.isNotEmpty
          ? '第${num}话${title.isNotEmpty ? ' $title' : ''}（$lang）'
          : '番外 ${title.isNotEmpty ? title : ''}（$lang）'.trim();
      chapters.add(Chapter(c['id'] as String, label));
    }
    return ComicDetail(item, chapters);
  }

  @override
  Future<List<String>> chapterPics(String chapterId) async {
    final api = await _apiHost();
    final body = await _get('$api/at-home/server/$chapterId');
    final root = jsonDecode(body) as Map<String, dynamic>;
    final ch = root['chapter'] as Map<String, dynamic>;
    final hash = ch['hash'] as String;
    final data = (ch['data'] as List? ?? []);
    // at-home CDN 节点（*.mangadex.network）时有不稳定/404，
    // 统一改用 uploads 官方静态宿主：uploads.mangadex.org/data/{hash}/{file}。
    return [
      for (final f in data) 'https://uploads.mangadex.org/data/$hash/$f'
    ];
  }

  /// 配置优先的 API host（可在源管理页覆盖，免发版）。
  Future<String> _apiHost() =>
      SourceHttp.pickHost('mangadex', _fallbackHosts);

  Future<String> _get(String url) =>
      SourceHttp.getUrl('mangadex', url, headers: _headers);

  String _orderParam(String categoryId) {
    switch (categoryId) {
      case 'rating':
        return 'rating';
      case 'createdAt':
        return 'createdAt';
      case 'latest':
        return 'latestUploadedChapter';
      case 'trending':
      default:
        return 'followedCount';
    }
  }

  Future<List<ComicItem>> _mangaList(String url) async {
    final body = await _get(url);
    final root = jsonDecode(body) as Map<String, dynamic>;
    final data = (root['data'] as List? ?? []);
    final out = <ComicItem>[];
    for (final m in data) {
      final attrs = m['attributes'] as Map<String, dynamic>;
      final rels = (m['relationships'] as List? ?? []);
      out.add(_mangaFromData(m, rels, attrs));
    }
    return out;
  }

  ComicItem _mangaFromData(
    Map<String, dynamic> data,
    List<dynamic> rels,
    Map<String, dynamic> attrs,
  ) {
    final id = data['id'] as String;
    final title = _pickLocalized(attrs['title']) ?? id;
    String? cover;
    for (final r in rels) {
      if (r is! Map) continue;
      if (r['type'] == 'cover_art' && r['attributes'] != null) {
        final f = (r['attributes'] as Map)['fileName'] as String?;
        if (f != null) {
          cover = '$_coverBase/$id/$f.256.jpg';
          break;
        }
      }
    }
    final alt = (attrs['altTitles'] as List? ?? [])
        .whereType<Map>()
        .map((e) => _pickLocalized(e))
        .whereType<String>()
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    return ComicItem(id, title, cover ?? '')
      ..yname = alt.isNotEmpty ? alt : null;
  }

  String? _pickLocalized(dynamic v) {
    if (v is String) return v;
    if (v is Map) {
      for (final k in ['zh-ro', 'zh', 'zh-hk', 'zh-tw', 'en', 'ja-ro', 'ja']) {
        final s = v[k];
        if (s is String && s.isNotEmpty) return s;
      }
      for (final e in v.values) {
        if (e is String && e.isNotEmpty) return e;
      }
    }
    return null;
  }
}
