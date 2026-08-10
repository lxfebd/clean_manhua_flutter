import '../models/comic_item.dart';
import 'novel_source.dart';
import 'source_config.dart';
import 'source_http.dart';

/// 笔趣阁类聚合小说源。
///
/// 采用经典「笔趣阁(YanMo/KindlePHP 模板)」结构解析：
/// - 搜索：/modules/article/search.php?searchkey={q}
/// - 详情：/book/{id}/
/// - 章节：/book/{id}/{cid}.html  →  <div id="content">
///
/// 该模板被数百个镜像共用，结构十年稳定。具体站点通过 [SourceConfig.hosts] 配置
/// （首个 host 生效），在「源管理」页即可切换域名，无需改代码重发版。
class BiqugeNovelSource extends NovelSource {
  static const List<String> _defaultHosts = [
    'https://www.biquge.com.tw',
    'https://www.xbiquge.la',
    'https://www.biquge5200.com',
  ];

  // 搜索结果：<a href="/book/12345/" ...>书名</a>（位于 tbody 结果区）
  static final RegExp _searchRe =
      RegExp(r'<a\s+href="/book/(\d+)/"[^>]*>([^<]+)</a>');
  // 详情页章节：<a href="/book/12345/6789.html">章节名</a>
  static final RegExp _chapterRe =
      RegExp(r'<a\s+href="/book/\d+/(\d+)\.html"[^>]*>([^<]+)</a>');
  static final RegExp _h1Re = RegExp(r'<h1[^>]*>([^<]+)</h1>');
  static final RegExp _ogImgRe =
      RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"');
  static final RegExp _fmImgRe =
      RegExp(r'id="fmimg"[^>]*>[\s\S]*?<img[^>]+src="([^"]+)"');
  static final RegExp _descRe =
      RegExp(r'<meta[^>]+name="description"[^>]+content="([^"]+)"');
  static final RegExp _contentRe =
      RegExp(r'<div[^>]+id="content"[^>]*>([\s\S]*?)</div>',
          caseSensitive: false);
  static final RegExp _prevRe =
      RegExp(r'<a\s+href="(\d+)\.html"[^>]*>上一章</a>', caseSensitive: false);
  static final RegExp _nextRe =
      RegExp(r'<a\s+href="(\d+)\.html"[^>]*>下一章</a>', caseSensitive: false);
  static final RegExp _tagRe = RegExp(r'<[^>]+>');
  static final RegExp _brRe = RegExp(r'(<br\s*/?>|</p>|&nbsp;)',
      caseSensitive: false);

  @override
  String get id => 'biquge';
  @override
  String get name => '笔趣阁';
  @override
  SourceTier get tier => SourceTier.primary;

  @override
  Future<List<Category>> categories() async => [
        Category('all', '全部'),
        Category('xuanhuan', '玄幻'),
        Category('xiuzhen', '修真'),
        Category('dushi', '都市'),
        Category('yanqing', '言情'),
        Category('kehuan', '科幻'),
        Category('lingyi', '灵异'),
        Category('wangyou', '网游'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    // 分类页多数镜像为 /sort/{id}_{page}/ 或 /category/，兜底走排行首页。
    final path = categoryId == 'all'
        ? '/modules/article/toplist.php?page=$page'
        : '/sort/$categoryId\_$page/';
    return _parseList(
        await SourceHttp.get('biquge', path, fallbackHosts: _defaultHosts));
  }

  @override
  Future<List<ComicItem>> rank(int page) async => _parseList(await SourceHttp.get(
      'biquge', '/modules/article/toplist.php?page=$page',
      fallbackHosts: _defaultHosts));

  @override
  Future<List<ComicItem>> search(String keyword, int page) async => _parseList(
      await SourceHttp.get(
          'biquge',
          '/modules/article/search.php?searchkey=${Uri.encodeQueryComponent(keyword)}',
          fallbackHosts: _defaultHosts));

  @override
  Future<NovelDetail> detail(String novelId) async {
    final body = await SourceHttp.get('biquge', '/book/$novelId/',
        fallbackHosts: _defaultHosts);
    final name = _first(_h1Re, body);
    final cover = _first(_ogImgRe, body) ?? _first(_fmImgRe, body);
    final desc = _first(_descRe, body);
    final chapters = <NovelChapter>[];
    var idx = 0;
    for (final m in _chapterRe.allMatches(body)) {
      chapters.add(NovelChapter(m.group(1)!, _clean(m.group(2)!),
          index: idx++));
    }
    return NovelDetail(
      ComicItem(novelId, name.isEmpty ? novelId : name, cover ?? ''),
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
    final body = await SourceHttp.get('biquge', '/book/$novelId/$cid.html',
        fallbackHosts: _defaultHosts);
    final title = _first(_h1Re, body);
    final paragraphs = _parseContent(body);
    final prev = _firstGroup(_prevRe, body);
    final next = _firstGroup(_nextRe, body);
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
    for (final m in _searchRe.allMatches(html)) {
      items.add(ComicItem(m.group(1)!, _clean(m.group(2)!), ''));
    }
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

  static String? _firstGroup(RegExp re, String s) {
    final m = re.firstMatch(s);
    return m?.group(1);
  }
}
