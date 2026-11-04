                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                import '../models/comic_item.dart';
import 'dsl/html_parser.dart' show firstCleanMatch, stripHtmlTags;
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
///
/// ## 2026-11-04 实测：本模板站点已全灭
/// - `tobiquge.com`：HTTP 302 跳 `http://www.js96110.com.cn/`（江苏反诈拦截页），
///   HTTPS 直接 TLS 握手失败——站点已被反诈系统接管，不是临时故障。
/// - `xbiquge.com`：HTTPS 连接 15s 超时，无响应。
/// - 另测 16 个常见笔趣阁镜像（bqg128 / biquge365 / beqege / biqu5200 / bqg70 /
///   biquge5200 / xbiquge.la / biquge.info / tobiquge.net / bqg221 / biqugse…），
///   无一使用本源的 `/bqg/{id}/{cid}.html` + `/rank.html` + `/list-{cat}-{page}/`
///   模板（要么已挂，要么换成随机路径反爬），因此**无法靠换域名救活**。
///
/// 处置：`tier` 由 `primary` 降为 `fallback`——小说首页默认源改为能用的
/// 新笔趣阁（[XbiqugeNovelSource]，xbiquge.bz 实测正常）。本源保留在源管理页
/// 供网络环境不同的用户手动启用；若后续找到同模板站点，把域名加进
/// [_defaultHosts] 并把 tier 调回 primary 即可（解析规则无需改动）。
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
  static final RegExp _brRe = RegExp(r'(<br\s*/?>|</p>|&nbsp;)',
      caseSensitive: false);
  static final RegExp _htmlCommentRe = RegExp(r'<!--[\s\S]*?-->');
  static final RegExp _bookLinkRe =
      RegExp(r'<a\s+href="/bqg/(\d+)/"[^>]*>([^<]+)</a>');

  @override
  String get id => 'biquge';
  @override
  String get name => '笔趣阁';
  @override
  // 2026-11-04：主站 tobiquge/xbiquge 全灭（tobiquge 被反诈页接管），
  // 同模板镜像无一存活，无法换域名救活。降为 fallback 让小说首页默认
  // 用新笔趣阁（xbiquge.bz 正常）；保留本源供网络不同的用户手动启用。
  SourceTier get tier => SourceTier.fallback;

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
    final name = firstCleanMatch(_ogTitleRe, body);
    final cover = firstCleanMatch(_ogImgRe, body);
    final desc = firstCleanMatch(_descRe, body);
    final chapters = <NovelChapter>[];
    final seen = <String>{};
    var idx = 0;
    for (final m in _chapterRe.allMatches(body)) {
      final nid = m.group(1)!;
      final cid = m.group(2)!;
      // 站点在章节列表头部放 cid=0 的无效占位链接（如「/bqg/{id}/0.html」），需跳过
      if (cid == '0') continue;
      if (nid != novelId || !seen.add(cid)) continue;
      chapters.add(
          NovelChapter('$novelId|$cid', stripHtmlTags(m.group(3)!),
              index: idx++));
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
    final title = firstCleanMatch(_h1Re, body);
    final paragraphs = _parseContent(body);
    final prev = _firstGroup(_prevRe, body);
    final next = _firstGroup(_nextRe, body);
    return NovelContent(
      chapterId,
      stripHtmlTags(title),
      paragraphs,
      prevChapterId: prev != null ? '$novelId|$prev' : null,
      nextChapterId: next != null ? '$novelId|$next' : null,
    );
  }

  List<String> _parseContent(String html) {
    final m = _contentRe.firstMatch(html);
    if (m == null) return const [];
    final raw = m.group(1)!
        .replaceAll(_htmlCommentRe, '')
        .replaceAll(_brRe, '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
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
    for (final m in _bookLinkRe.allMatches(html)) {
      final id = m.group(1)!;
      if (items.any((e) => e.id == id)) continue;
      items.add(ComicItem(id, stripHtmlTags(m.group(2)!), ''));
    }
    return items;
  }

  static String? _firstGroup(RegExp re, String s) =>
      re.firstMatch(s)?.group(2);
}
