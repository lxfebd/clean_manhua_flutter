import '../models/comic_item.dart';
import 'novel_source.dart';
import 'source_config.dart';
import 'source_http.dart';

/// 笔趣阁类聚合小说源（xbiquge.com / tobiquge.com 模板）。
///
/// 站点结构（2026-08 实测可用）：
/// - 排行：/rank.html（无分页，整页书单）
/// - 分类：/list-{catId}-{page}/   （catId: 4都市, 6游戏, 8异界, 9科幻, 10历史…）
/// - 详情：/bqg/{novelId}/         章节列表在详情页内
/// - 章节：/bqg/{novelId}/{cid}.html → <div id="content"> 内 <p> 段落
/// - 封面：og:image（tobiquge.com 图床）
/// - 搜索：该模板搜索跳转第三方聚合站，本站无搜索接口，返回空列表。
/// - 注意：主站 xbiquge.com 会 301 到 tobiquge.com，而重定向链在部分 UA/
///   header（如 Accept: */*）下连接会被关闭，因此首选直连 tobiquge.com。
class BiqugeNovelSource extends NovelSource {
  static const List<String> _defaultHosts = [
    'https://www.tobiquge.com',
    'https://www.xbiquge.com',
  ];

  // 详情页章节：<a href="/bqg/{novelId}/{cid}.html">章节名</a>
  static final RegExp _chapterRe =
      RegExp(r'<a\s+href="/bqg/(\d+)/(\d+)\.html"[^>]*>([^<]+)</a>');
  static final RegExp _h1Re = RegExp(r'<h1[^>]*>([^<]+)</h1>');
  static final RegExp _ogTitleRe =
      RegExp(r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"');
  static final RegExp _ogImgRe =
      RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"');
  static final RegExp _descRe =
      RegExp(r'<meta[^>]+property="og:description"[^>]+content="([^"]+)"');
  static final RegExp _contentRe =
      RegExp(r'<div[^>]+id="content"[^>]*>([\s\S]*?)</div>',
          caseSensitive: false);
  // 下一章：<a href="/bqg/{id}/{cid}.html" class="pageDown">下一章</a>
  static final RegExp _nextRe =
      RegExp(r'<a\s+href="[^"]*/bqg/(\d+)/(\d+)\.html"[^>]*class="pageDown"[^>]*>[^<]*下一章</a>');
  // 上一章：<a href="/bqg/{id}/{cid}.html" class="pageUp">上一章</a>
  static final RegExp _prevRe =
      RegExp(r'<a\s+href="[^"]*/bqg/(\d+)/(\d+)\.html"[^>]*class="pageUp"[^>]*>[^<]*上一章</a>');
  static final RegExp _tagRe = RegExp(r'<[^>]+>');
  static final RegExp _brRe = RegExp(r'(<br\s*/?>|</p>|&nbsp;)',
      caseSensitive: false);

  @override
  String get id => 'biquge';
  @override
  String get name => '笔趣阁';
  @override
  SourceTier get tier => SourceTier.primary;

  // 站内分类 id → 名称
  static const Map<String, String> _catNames = {
    '4': '都市小说',
    '5': '游戏小说',
    '6': '网游小说',
    '8': '异界小说',
    '9': '科幻小说',
    '10': '历史小说',
    '11': '武侠小说',
    '12': '军事小说',
    '16': '古代言情',
    '18': '现代言情',
  };

  @override
  Future<List<Category>> categories() async => [
        for (final e in _catNames.entries) Category(e.key, e.value),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final id = categoryId == 'all' ? '4' : categoryId;
    return _parseList(
        await SourceHttp.get('biquge', '/list-$id-$page/',
            fallbackHosts: _defaultHosts));
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    // /rank.html 为整页书单（无分页），page>1 时仍返回首页排行。
    final body = await SourceHttp.get('biquge', '/rank.html',
        fallbackHosts: _defaultHosts);
    return _parseList(body);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    // 该模板无站内搜索（搜索框跳第三方聚合站），返回空列表由 UI 兜底。
    return const [];
  }

  @override
  Future<NovelDetail> detail(String novelId) async {
    final body = await SourceHttp.get('biquge', '/bqg/$novelId/',
        fallbackHosts: _defaultHosts);
    final name = _first(_ogTitleRe, body);
    final cover = _first(_ogImgRe, body);
    final desc = _first(_descRe, body);
    final chapters = <NovelChapter>[];
    final seen = <String>{};
    var idx = 0;
    final chLinks = _chapterRe.allMatches(body).take(6).map((m) =>
        '${m.group(1)}/${m.group(2)}:${m.group(3)}').join(' | ');
    // ignore: avoid_print
    print('[BIQUGE-DETAIL] id=$novelId bodyLen=${body.length} '
        'chapterReCount=${_chapterRe.allMatches(body).length} '
        'chLinks=$chLinks');
    for (final m in _chapterRe.allMatches(body)) {
      final nid = m.group(1)!;
      final cid = m.group(2)!;
      // 站点在章节列表头部放 cid=0 的无效占位链接（如「/bqg/{id}/0.html」），需跳过
      if (cid == '0') continue;
      if (nid != novelId || !seen.add(cid)) continue;
      chapters.add(
          NovelChapter('$novelId|$cid', _clean(m.group(3)!), index: idx++));
    }
    return NovelDetail(
      ComicItem(novelId, name, cover),
      chapters,
      description: desc,
    );
  }

  @override
  Future<NovelContent> chapterContent(String chapterId) async {
    // chapterId 形如 "{novelId}|{cid}"
    final sep = chapterId.indexOf('|');
    if (sep < 0) {
      return NovelContent(chapterId, '', const []);
    }
    final novelId = chapterId.substring(0, sep);
    final cid = chapterId.substring(sep + 1);
    final body = await SourceHttp.get('biquge', '/bqg/$novelId/$cid.html',
        fallbackHosts: _defaultHosts);
    final title = _first(_h1Re, body);
    final paragraphs = _parseContent(body);
    final prev = _firstGroup(_prevRe, body);
    final next = _firstGroup(_nextRe, body);
    // ignore: avoid_print
    print('[BIQUGE-DEBUG] cid=$cid bodyLen=${body.length} '
        'hasContent=${_contentRe.hasMatch(body)} paras=${paragraphs.length} '
        'hasPrev=$prev hasNext=$next '
        'sample=${body.length > 300 ? body.substring(0, 300) : body}');
    return NovelContent(
      chapterId,
      _clean(title),
      paragraphs,
      prevChapterId: prev != null ? '$novelId|$prev' : null,
      nextChapterId: next != null ? '$novelId|$next' : null,
    );
  }

  List<String> _parseContent(String html) {
    final m = _contentRe.firstMatch(html);
    if (m == null) return const [];
    final raw = m.group(1)!
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
        .replaceAll(_brRe, '\n')
        .replaceAll(_tagRe, '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return raw
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != '『加入书签，方便阅读』')
        .toList();
  }

  Future<List<ComicItem>> _parseList(String html) async {
    final items = <ComicItem>[];
    final bookRe = RegExp(r'<a\s+href="/bqg/(\d+)/"[^>]*>([^<]+)</a>');
    for (final m in bookRe.allMatches(html)) {
      final id = m.group(1)!;
      if (items.any((e) => e.id == id)) continue;
      items.add(ComicItem(id, _clean(m.group(2)!), ''));
    }
    // ignore: avoid_print
    print('[BIQUGE-LIST] bodyLen=${html.length} books=${items.length} '
        'imgs=${RegExp(r'<img[^>]+src="([^"]+)"').allMatches(html).length} '
        'imgSample=${RegExp(r'<img[^>]+src="([^"]+)"').allMatches(html).take(2).map((m)=>m.group(1)).join(' | ')}');
    return items;
  }

  static String _clean(String s) => s
      .replaceAll(_tagRe, '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();

  static String _first(RegExp re, String s) {
    final m = re.firstMatch(s);
    return m == null ? '' : _clean(m.group(1) ?? '');
  }

  static String? _firstGroup(RegExp re, String s) =>
      re.firstMatch(s)?.group(2);
}
