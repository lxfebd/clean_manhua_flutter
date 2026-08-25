import 'dart:convert';

import '../models/comic_item.dart';
import 'novel_source.dart';
import 'source_config.dart';
import 'source_http.dart';

/// 新笔趣阁小说源（www.xbiquge.bz 模板，2026-08 实测可用）。
///
/// 与 [BiqugeNovelSource]（tobiquge.com）为两套独立模板/书库，互为补充：
/// - 分类：/fenlei/{catId}/{page}.html
/// - 排行：无独立排行页，回退抓首页推荐（.item 块与分类页同构）
/// - 详情：/books_{novelId}/  章节目录在详情页内（<a href="/books_{id}/{cid}.html">）
/// - 章节：/books_{novelId}/{cid}.html → 正文以 base64 编码在
///   `qsbs.bb('...')` 中（UTF-8 明文，直接 base64 解码即可）；
///   多页章节用 `_{n}.html` 后缀，需逐页聚合。
/// - 封面：/img/{novelId}.jpg（相对路径，需拼 host）
/// - 搜索：/search.html 需登录态，纯 GET/POST 拿不到结果，返回空列表由 UI 兜底。
class XbiqugeNovelSource extends NovelSource {
  static const List<String> _defaultHosts = [
    'https://www.xbiquge.bz',
  ];

  // 详情页头部导航按钮标题（非章节名，需跳过）
  static const Set<String> _navTitleLabels = {'开始阅读', '章节目录', '加入书架'};

  // 章节列表：<a class="..." href="/books_{nid}/{cid}.html">章节名<span></span></a>
  // （href 前可能带 class 等属性；标题内可能有 <span>，故用惰性捕获再 _clean 去标签）
  static final RegExp _chapterRe = RegExp(
      r'<a\b[^>]*\bhref="/books_(\d+)/(\d+)\.html"[^>]*>([\s\S]*?)</a>');
  static final RegExp _ogTitleRe =
      RegExp(r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"');
  static final RegExp _ogImgRe =
      RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"');
  static final RegExp _ogAuthorRe =
      RegExp(r'<meta[^>]+property="og:novel:author"[^>]+content="([^"]+)"');
  static final RegExp _ogStatusRe =
      RegExp(r'<meta[^>]+property="og:novel:status"[^>]+content="([^"]+)"');
  // 章节正文容器：<div class="word_read"> ... <h1>标题</h1>（h3 兜底）... <div class="read_btn">导航</div>
  static final RegExp _h1Re = RegExp(r'<h1[^>]*>([^<]+)</h1>');
  static final RegExp _h3Re = RegExp(r'<h3[^>]*>([^<]+)</h3>');
  // 正文：document.writeln(qsbs.bb('BASE64'));
  static final RegExp _bbRe =
      RegExp(r"qsbs\.bb\('([^']+)'\)", caseSensitive: false);
  static final RegExp _tagRe = RegExp(r'<[^>]+>');
  static final RegExp _pageSuffixRe = RegExp(r'（第\d+页）$');
  // 列表块：<div class="item">...</dl></div>（桌面版分类页，带封面）
  static final RegExp _itemRe =
      RegExp(r'<div class="item">([\s\S]*?)</dl></div>', caseSensitive: false);
  // 首页推荐：<dl class="rec-focus-book">...</dl>（wap 版首页，带封面）
  static final RegExp _recFocusRe =
      RegExp(r'<dl class="rec-focus-book">([\s\S]*?)</dl>', caseSensitive: false);
  // 分类更新列表：<ul class="sort_list"><li>...</li></ul>（wap 版分类页，无封面）
  static final RegExp _sortItemRe = RegExp(
      r'<li>\s*<span class="s1">[^<]*</span>\s*<span class="s2"><a href="/books_(\d+)/">([^<]+)</a></span>');
  static final RegExp _bookIdRe = RegExp(r'/books_(\d+)/');
  static final RegExp _imgRe = RegExp(r'<img[^>]+src="([^"]+)"');
  static final RegExp _imgAltRe = RegExp(r'<img[^>]+alt="([^"]*)"');
  static final RegExp _dtRe = RegExp(r'<dt>(?:<span>([^<]*)</span>)?[\s\S]*?</dt>');

  @override
  String get id => 'xbiquge';
  @override
  String get name => '新笔趣阁';
  @override
  SourceTier get tier => SourceTier.primary;

  static const Map<String, String> _catNames = {
    '1': '玄幻修真',
    '2': '重生穿越',
    '3': '都市小说',
    '4': '军史小说',
    '5': '网游小说',
    '6': '科幻小说',
    '7': '灵异小说',
    '8': '其他小说',
  };

  @override
  Future<List<Category>> categories() async => [
        for (final e in _catNames.entries) Category(e.key, e.value),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final id = categoryId == 'all' ? '1' : categoryId;
    final body = await SourceHttp.get('xbiquge', '/fenlei/$id/$page.html',
        fallbackHosts: _defaultHosts);
    return _parseItems(body);
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    // 无独立排行页，抓首页推荐书单（rec-focus-book 带封面）。page>1 时仍返回首页。
    final body = await SourceHttp.get('xbiquge', '/',
        fallbackHosts: _defaultHosts);
    return _parseItems(body);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    // 该站搜索需登录态（POST /search.html 会 302 到登录页），返回空列表由 UI 兜底。
    return const [];
  }

  @override
  Future<NovelDetail> detail(String novelId) async {
    final body = await SourceHttp.get('xbiquge', '/books_$novelId/',
        fallbackHosts: _defaultHosts);
    final name = _first(_ogTitleRe, body);
    final cover = _abs(_first(_ogImgRe, body));
    final author = _first(_ogAuthorRe, body);
    final status = _first(_ogStatusRe, body);
    final chapters = <NovelChapter>[];
    final seen = <String>{};
    var idx = 0;
    for (final m in _chapterRe.allMatches(body)) {
      final nid = m.group(1)!;
      final cid = m.group(2)!;
      if (nid != novelId || !seen.add(cid)) continue;
      final title = _clean(m.group(3)!);
      // 跳过"开始阅读"等导航按钮（其标题非章节名）
      if (title.isEmpty || _navTitleLabels.contains(title)) continue;
      chapters.add(NovelChapter('$novelId|$cid', title, index: idx++));
    }
    return NovelDetail(
      ComicItem(novelId, name, cover),
      chapters,
      author: author,
      status: status,
    );
  }

  @override
  Future<NovelContent> chapterContent(String chapterId) async {
    // chapterId 形如 "{novelId}|{cid}"
    final sep = chapterId.indexOf('|');
    if (sep < 0) return NovelContent(chapterId, '', const []);
    final novelId = chapterId.substring(0, sep);
    final cid = chapterId.substring(sep + 1);

    final paragraphs = <String>[];
    String title = '';
    String? prevChapterId;
    String? nextChapterId;
    var page = 0;
    var currentCid = cid;

    // 逐页聚合（多页章节用 _{n}.html 后缀），直到下一章或章末。
    while (true) {
      final suffix = page == 0 ? '' : '_$page';
      final body = await SourceHttp.get('xbiquge',
          '/books_$novelId/$currentCid$suffix.html',
          fallbackHosts: _defaultHosts);
      if (page == 0) {
        // 标题在 <h1>（h3 兜底），去掉"（第N页）"后缀
        title = _first(_h1Re, body);
        if (title.isEmpty) title = _first(_h3Re, body);
        title = title.replaceAll(_pageSuffixRe, '');
        prevChapterId = _resolveChapter(_jsNavPrev(body), novelId, currentCid);
      }
      paragraphs.addAll(_parseParagraphs(body));
      // 本页"下一章"（JS 变量，多页章节指向同章下一页 _{n}.html）
      final nextHref = _jsNavNext(body);
      final nextSeg = _chapterOfHref(nextHref);
      if (nextSeg != null && nextSeg.cid == currentCid) {
        // 同一章节的下一页（_{n}.html），继续聚合
        page++;
        continue;
      }
      nextChapterId = _resolveChapter(nextHref, novelId, currentCid);
      break;
    }

    return NovelContent(
      chapterId,
      title,
      paragraphs,
      prevChapterId: prevChapterId,
      nextChapterId: nextChapterId,
    );
  }

  /// 章节页 JS 导航变量形如 `var hhekgsv='/books_{nid}/{cid}_1.html';var lkldeh='...';`，
  /// 前者是"下一章"、后者是"上一章"（变量名可能混淆，按出现顺序取即可）。
  static final RegExp _jsNavRe = RegExp(
      r"var\s+[A-Za-z0-9_]+='(/books_\d+/\d+(?:_\d+)?\.html)'");

  /// 下一章 href（JS 变量 hhekgsv，多页章节指向同章下一页）。
  static String? _jsNavNext(String body) {
    final l = _jsNavRe.allMatches(body).toList();
    return l.isEmpty ? null : l.first.group(1);
  }

  /// 上一章 href（JS 变量 lkldeh）。
  static String? _jsNavPrev(String body) {
    final l = _jsNavRe.allMatches(body).toList();
    return l.length < 2 ? null : l[1].group(1);
  }

  /// 从 href 解析出 (novelId, cid)；章节目录/书根/跨站链接返回 null。
  static ({String novelId, String cid})? _chapterOfHref(String? href) {
    if (href == null) return null;
    final m = RegExp(r'/books_(\d+)/(\d+)(?:_\d+)?\.html').firstMatch(href);
    if (m == null) return null;
    return (novelId: m.group(1)!, cid: m.group(2)!);
  }

  /// 将导航 href 转为 chapterId；无效（书根/目录/同章分页）返回 null。
  static String? _resolveChapter(String? href, String novelId, String curCid) {
    final seg = _chapterOfHref(href);
    if (seg == null || seg.novelId != novelId) return null;
    if (seg.cid == curCid) return null; // 同章分页，跳过
    return '$novelId|${seg.cid}';
  }

  /// 提取正文段落：解码 qsbs.bb('BASE64') → HTML → 去标签 → 按 <p> 分段落。
  List<String> _parseParagraphs(String html) {
    final paras = <String>[];
    for (final m in _bbRe.allMatches(html)) {
      final decoded = _decodeBase64Utf8(m.group(1) ?? '');
      if (decoded.isEmpty) continue;
      // 解码结果是 <p>...</p> 拼接，按 <p> 切分
      for (final seg in decoded.split(RegExp(r'</?\s*p[^>]*>'))) {
        final clean = seg
            .replaceAll(_tagRe, '')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .trim();
        if (clean.isNotEmpty) paras.add(clean);
      }
    }
    return paras;
  }

  static String _decodeBase64Utf8(String b64) {
    try {
      // 兼容 URL-safe base64
      final s = b64.replaceAll('-', '+').replaceAll('_', '/');
      final bytes = base64.decode(s);
      return utf8.decode(bytes);
    } catch (_) {
      return '';
    }
  }

  /// 解析书列表，兼容三种布局（按优先级依次尝试）：
  /// 1. `.item` 块（桌面版分类页，带封面）
  /// 2. `rec-focus-book` 块（wap 版首页推荐，带封面）
  /// 3. `sort_list` 项（wap 版分类页，无封面）
  List<ComicItem> _parseItems(String html) {
    final items = <ComicItem>[];
    final seen = <String>{};
    void add(ComicItem it) {
      if (seen.add(it.id)) items.add(it);
    }

    for (final m in _itemRe.allMatches(html)) {
      final block = m.group(1)!;
      final idM = _bookIdRe.firstMatch(block);
      if (idM == null) continue;
      final id = idM.group(1)!;
      var title = _first(_imgAltRe, block);
      if (title.isEmpty) {
        final dt = _dtRe.firstMatch(block);
        title = dt == null ? '' : _clean(dt.group(1) ?? '');
      }
      add(ComicItem(id, title, _abs(_first(_imgRe, block))));
    }

    for (final m in _recFocusRe.allMatches(html)) {
      final block = m.group(1)!;
      final idM = _bookIdRe.firstMatch(block);
      if (idM == null) continue;
      add(ComicItem(idM.group(1)!,
          _first(_imgAltRe, block), _abs(_first(_imgRe, block))));
    }

    for (final m in _sortItemRe.allMatches(html)) {
      add(ComicItem(m.group(1)!, _clean(m.group(2)!), ''));
    }
    return items;
  }

  /// 相对路径封面拼 host。
  String _abs(String url) {
    if (url.isEmpty || url.startsWith('http')) return url;
    return '${_defaultHosts[0]}$url';
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
}
