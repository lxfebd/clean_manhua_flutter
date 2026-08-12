import '../models/comic_item.dart';
import 'comic_source.dart';
import 'source_config.dart';
import 'source_http.dart';

/// 包子漫画源（www.baozimh.com / cn.bzmgcn.com / www.bzmgcn.com）。
///
/// 全站免登录、无 Cloudflare 挑战、章节图为直链 `<img>`（CDN 域名按章节变化：
/// s1.bzcdn.net / s2.bzcdn.net ...），无需解密/反爬。作为对登录墙花火漫画的替代源。
class BaoziMangaSource extends ComicSource {
  static const String _web = 'https://www.baozimh.com';
  static const String _detailHost = 'https://cn.bzmgcn.com';
  static const String _chapterHost = 'https://www.bzmgcn.com';

  static final RegExp _coverRe =
      RegExp(r'<amp-img[^>]+src="(https://static-tw\.bzmgcn\.com/cover/[^"?]+)');
  static final RegExp _cardRe = RegExp(
      r'<a\s+href="/comic/([^"]+)"\s+title="([^"]*)"[^>]*>\s*<amp-img[^>]+src="([^"]+)"');
  static final RegExp _h1Re = RegExp(r'<h1[^>]*>([^<]*)</h1>');
  static final RegExp _ogTitleRe =
      RegExp(r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"');
  static final RegExp _ogImgRe =
      RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"');
  static final RegExp _ogDescRe =
      RegExp(r'<meta[^>]+property="og:description"[^>]+content="([^"]+)"');
  // 章节链接：/user/page_direct?comic_id=SLUG&section_slot=S&chapter_slot=C
  static final RegExp _chapterRe = RegExp(
      r'href="[^"]*page_direct\?comic_id=([^&]+)&[^"]*section_slot=(\d+)[^"]*chapter_slot=(\d+)"[^>]*>(.*?)</a>',
      dotAll: true);
  static final RegExp _imgRe =
      RegExp(r'<img[^>]+(?:src|data-src)="([^"]+)"', caseSensitive: false);

  @override
  String get id => 'baozi';
  @override
  String get name => '包子漫画';
  @override
  SourceTier get tier => SourceTier.primary;

  @override
  Future<List<Category>> categories() async => [
        Category('all', '全部'),
        Category('lianai', '恋爱'),
        Category('chunai', '纯爱'),
        Category('gufeng', '古风'),
        Category('xuanyi', '悬疑'),
        Category('juqing', '剧情'),
        Category('kehuan', '科幻'),
        Category('qihuan', '奇幻'),
        Category('xuanhuan', '玄幻'),
        Category('chuanyue', '穿越'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final url =
        '$_web/classify?type=$categoryId&region=all&state=all&filter=%2a&page=$page';
    return _parseList(await SourceHttp.getUrl('baozi', url));
  }

  @override
  Future<List<ComicItem>> rank(int page) async =>
      _parseList(await SourceHttp.getUrl('baozi', '$_web/list/new?page=$page'));

  @override
  Future<List<ComicItem>> search(String keyword, int page) async => _parseList(
      await SourceHttp.getUrl('baozi',
          '$_web/search?q=${Uri.encodeQueryComponent(keyword)}&page=$page'));

  @override
  Future<ComicDetail> detail(String comicId) async {
    final body = await SourceHttp.getUrl(
        'baozi', '$_detailHost/comic/$comicId');
    final title = _first(_ogTitleRe, body) ??
        _first(_h1Re, body)?.replaceAll(RegExp(r'\s*-\s*包子漫画$'), '') ??
        comicId;
    final cover = _first(_ogImgRe, body);
    final desc = _first(_ogDescRe, body);
    final chapters = _chapterRe.allMatches(body).map((m) {
      final slug = m.group(1)!;
      final sec = m.group(2)!;
      final ch = m.group(3)!;
      final rawTitle = _stripTags(m.group(4) ?? '');
      // chapterId 编码 slug 与 section_chapter，便于 chapterPics 还原。
      return Chapter('$slug|${sec}_$ch',
          rawTitle.isEmpty ? '第$ch话' : _unescape(rawTitle));
    }).toList();
    return ComicDetail(
      ComicItem(comicId, title, cover ?? ''),
      chapters,
      description: desc,
    );
  }

  @override
  Future<List<String>> chapterPics(String chapterId) async {
    final parts = chapterId.split('|');
    if (parts.length != 2) return const <String>[];
    final slug = parts[0];
    final sc = parts[1]; // {section}_{chapter}
    final url = '$_chapterHost/comic/chapter/$slug/$sc.html';
    final body = await SourceHttp.getUrl('baozi', url);
    final urls = <String>{};
    for (final m in _imgRe.allMatches(body)) {
      final u = _unescape(m.group(1)!);
      if (_isImage(u)) urls.add(u);
    }
    return urls.toList();
  }

  static bool _isImage(String u) {
    final lower = u.toLowerCase();
    if (lower.contains('bzcdn.net')) return true;
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp');
  }

  Future<List<ComicItem>> _parseList(String html) async {
    final items = <ComicItem>[];
    for (final m in _cardRe.allMatches(html)) {
      final slug = m.group(1)!;
      final name = _unescape(m.group(2)!);
      final coverRaw = m.group(3)!;
      final cover = coverRaw.split('?').first;
      items.add(ComicItem(slug, name, cover));
    }
    // 兜底：部分列表页用 coverRe 的 slug 关联
    if (items.isEmpty) {
      for (final m in _coverRe.allMatches(html)) {
        final cover = m.group(1)!;
        final slug = RegExp(r'/cover/([^.]+)\.jpg')
            .firstMatch(cover)
            ?.group(1);
        if (slug != null) items.add(ComicItem(slug, slug, cover));
      }
    }
    return items;
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll('\n', ' ').trim();

  static String? _first(RegExp re, String s) {
    final m = re.firstMatch(s);
    return m == null ? null : _unescape(m.group(1) ?? '');
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}
