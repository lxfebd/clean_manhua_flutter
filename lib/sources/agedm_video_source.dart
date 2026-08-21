import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'video_source.dart';

/// AGE 动漫视频源（www.agedm.io）。
/// HTML 站点，剧集列表与播放入口（iframe m3u8 解析器）均在 HTML 中可直接解析。
/// 真实的 m3u8 URL 被站点 JS 加密后放在 iframe URL 参数里；
/// 这里把 iframe URL 直接返回给 WebView 进行播放。
class AgedMVideoSource implements VideoSource {
  static const String _base = 'https://www.agedm.io';

  static final RegExp _cardRe = RegExp(
      r'<div class="video_item">.*?'
      r'data-original="([^"]+)"[^>]*class="video_thumbs.*?'
      r'href="(?:https?://(?:www\.)?agedm\.io)?/detail/(\d+)"[^>]*>([^<]+)</a>',
      dotAll: true);
  static final RegExp _searchCardRe = RegExp(
      r'<a href="(?:https?://(?:www\.)?agedm\.io)?/detail/(\d+)"[^>]*title="([^"]*)"[^>]*>'
      r'[\s\S]*?data-original="([^"]+)"',
      dotAll: true);
  static final RegExp _coverRe = RegExp(
      r'<img[^>]*data-original="([^"]+)"[^>]*class="video_thumbs',
      dotAll: true);
  static final RegExp _epRe = RegExp(
      r'<a href="(/play/\d+/(\d+)/(\d+))"[^>]*>([^<]+)</a>',
      dotAll: true);
  static final RegExp _iframeRe = RegExp(
      r'<iframe[^>]+src="(https?://[^"]+/vip/\?url=[^"]+)"',
      dotAll: true);
  static final RegExp _titleRe =
      RegExp(r'<h2 class="video_detail_title">([^<]+)</h2>');
  static final RegExp _infoRe =
      RegExp(r'<div class="video_detail_info"><span>([^<]+)</span>([^<]+)</div>');

  @override
  String get id => 'agedm';
  @override
  String get name => 'AGE 动漫';

  static final _genres = <Category>[
    Category('all-all-all-all-all-time-1', '全部'),
    Category('all-all-all-all-jp-time-1', '日本'),
    Category('all-all-all-all-cn-time-1', '国创'),
    Category('all-all-all-all-us-time-1', '欧美'),
  ];

  @override
  Future<List<Category>> categories() async => _genres;

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    // home 页直接展示最新番剧，无服务端过滤；简化处理：忽略 page，按类别标记返回全部
    if (page > 1) return const <ComicItem>[];
    final html = await Net.get(_base, headers: const {'Cookie': 'adult=1'});
    return _parseCards(html);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final url =
        '$_base/search?keyword=${Uri.encodeQueryComponent(keyword)}&page=$page';
    final html = await Net.get(url, headers: {'Cookie': 'adult=1'});
    return _parseCards(html);
  }

  @override
  Future<VideoDetail> detail(String videoId) async {
    final html =
        await Net.get('$_base/detail/$videoId', headers: {'Cookie': 'adult=1'});
    final title = _unescape(_first(_titleRe, html).trim());
    final cover = _first(_coverRe, html);
    final desc = _extractDescription(html);
    String? area, year, type;
    for (final m in _infoRe.allMatches(html)) {
      final k = m.group(1)?.trim() ?? '';
      final v = m.group(2)?.trim() ?? '';
      if (k.startsWith('地区')) area = v;
      if (k.startsWith('年代')) year = v;
      if (k.startsWith('动画种类')) type = v;
    }
    final episodes = <VideoEpisode>[];
    for (final m in _epRe.allMatches(html)) {
      final s = int.tryParse(m.group(2) ?? '');
      final e = int.tryParse(m.group(3) ?? '');
      if (s == null || e == null) continue;
      episodes.add(VideoEpisode(s, e, _unescape(m.group(4) ?? '')));
    }
    return VideoDetail(
      ComicItem(videoId, title, cover),
      episodes,
      description: desc,
      cover: cover,
      area: area,
      year: year,
      type: type,
    );
  }

  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    final html = await Net.get(
      '$_base/play/$videoId/$season/$episode',
      headers: {'Cookie': 'adult=1'},
    );
    final m = _iframeRe.firstMatch(html);
    if (m == null) {
      throw Exception('未找到播放入口 iframe');
    }
    return m.group(1)!;
  }

  List<ComicItem> _parseCards(String html) {
    final out = <ComicItem>[];
    final seen = <String>{};

    // 首页：整卡片块（img 与标题链接一一对应）
    for (final m in _cardRe.allMatches(html)) {
      final id = m.group(2)!;
      if (!seen.add(id)) continue;
      out.add(ComicItem(
          id,
          _unescape(m.group(3) ?? '').trim(),
          _resolveCover(m.group(1)!)));
    }
    if (out.isNotEmpty) return out;

    // 搜索页：<a title="标题"><img data-original="封面"></a>
    for (final m in _searchCardRe.allMatches(html)) {
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      out.add(ComicItem(
          id,
          _unescape(m.group(2) ?? '').trim(),
          _resolveCover(m.group(3)!)));
    }
    return out;
  }

  /// 解析封面图 URL：百度图片代理 URL（/gimg/app=...&src=<实际图片>）取真实 src。
  /// 注意：原始 URL 含 &amp; HTML 实体，需先 _unescape 才能被 Uri 正确解析。
  static String _resolveCover(String raw) {
    final unescaped = raw
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    if (!unescaped.contains('src=')) return unescaped;
    final fixed = unescaped.contains('?') ? unescaped : unescaped.replaceFirst('&', '?');
    final u = Uri.tryParse(fixed);
    return u?.queryParameters['src'] ?? unescaped;
  }

  String _extractDescription(String html) {
    final i = html.indexOf('简介');
    if (i < 0) return '';
    final start = html.indexOf('>', i) + 1;
    final end = html.indexOf('</p>', start);
    if (end < 0) return '';
    return _unescape(html.substring(start, end).trim());
  }

  static String _first(RegExp re, String s) =>
      re.firstMatch(s)?.group(1)?.trim() ?? '';

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}