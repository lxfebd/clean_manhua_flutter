import 'dart:convert';
import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'video_source.dart';

/// TvTFun 动漫视频源（www.tvtfun.net）。
///
/// 数据源配置借鉴自开源聚合追番项目 Animeko（open-ani/animeko）的
/// 在线源定义（creamycake css1 源集）。
///
/// 数据流：
/// - 搜索：HTTP JSON API，返回 slug / name / cover
/// - 详情：HTML 页面解析剧集与元信息
/// - 播放：返回播放页 URL，由 WebView 加载并拦截 resolve-play-url API，
///   获取视频直链后交给 NativePlayer（media_kit）播放
class TvTfunVideoSource implements VideoSource {
  static const String base = 'https://www.tvtfun.net';

  /// Cloudflare 优选 IP，用于绕过 DNS 解析失败。
  /// 模拟器/部分网络环境无法解析 tvtfun.net 的 DNS，使用此 IP 直连。
  static const String cloudflareIp = '104.16.150.186';

  /// 匹配剧集链接：<a href=".../play?...">任意内容</a>
  /// 提取 href 和显示的文本内容（如"第01集"）
  static final RegExp _epRe = RegExp(
      r'<a[^>]+href="(/video/[^"]+/play[^"]*)"[^>]*>([\s\S]*?)</a>',
      dotAll: true);

  static final RegExp _titleRe = RegExp(r'<title>([^<]+)</title>');
  static final RegExp _descRe = RegExp(
      r'<meta[^>]+name="description"[^>]+content="([^"]+)"', dotAll: true);
  static final RegExp _ogImageRe = RegExp(
      r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"');

  @override
  String get id => 'tvtfun';
  @override
  String get name => 'TvTFun 番剧';

  @override
  Future<List<Category>> categories() async => [
        Category('all', '全部'),
        Category('jp', '日本'),
        Category('cn', '国创'),
        Category('movie', '剧场版'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    if (page > 1) return const <ComicItem>[];
    final html = await Net.get(base,
        headers: const {'Cookie': 'quality=1080'},
        timeout: const Duration(seconds: 40));
    return _parseHome(html);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final url = '$base/api/videos/search'
        '?q=${Uri.encodeQueryComponent(keyword)}&pageSize=10';
    final json = jsonDecode(await Net.get(url));
    final videos = (json['data']?['videos'] as List? ?? const []);
    return videos.map<ComicItem>((v) {
      final slug = v['slug'] as String? ?? '';
      var cover = (v['cover'] as String? ?? '');
      // 解码 Next.js 图片代理 URL
      if (cover.contains('/_next/image')) {
        final u = Uri.tryParse(cover);
        final real = u?.queryParameters['url'];
        if (real != null && real.isNotEmpty) {
          cover = Uri.decodeComponent(real);
        }
      }
      return ComicItem(
        slug,
        (v['name'] as String?) ?? '',
        cover,
      );
    }).toList();
  }

  @override
  Future<VideoDetail> detail(String videoId) async {
    final html = await Net.get('$base/video/$videoId',
        headers: const {'Cookie': 'quality=1080'},
        timeout: const Duration(seconds: 30));

    // 提取标题
    final title = _extractTitle(html) ?? videoId;

    // 提取剧集列表
    final episodes = _parseEpisodes(html);

    // 提取元信息
    final description = _first(_descRe, html);
    final cover = _first(_ogImageRe, html);

    return VideoDetail(
      ComicItem(videoId, title, cover ?? ''),
      episodes,
      description: description,
      cover: cover,
    );
  }

  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    final normal = '$base/video/$videoId/play?source=0&episode=$episode';
    // 默认走真实域名；若网络不可达（DNS 污染/被墙），回退 Cloudflare 优选 IP 直连。
    // 注意：WebView 直连 IP 受 TLS 证书（SNI=IP 不匹配）限制，可能在部分环境仍失败，
    // 此时需在网络层解决（可用网络 / 系统 hosts 映射）。
    try {
      await Net.get(base, timeout: const Duration(seconds: 10));
    } catch (_) {
      return cloudflarePlayUrl(videoId, season, episode);
    }
    return normal;
  }

  /// 返回使用 Cloudflare 优选 IP 的播放页 URL（绕过 DNS 解析失败）。
  /// 配合 [cloudflareHeaders] 使用，设置正确的 Host 头。
  String cloudflarePlayUrl(String videoId, int season, int episode) {
    final path = '/video/$videoId/play?source=0&episode=$episode';
    return 'https://$cloudflareIp$path';
  }

  /// 返回使用 Cloudflare IP 直连时需要的请求头（Host 头）。
  Map<String, String> get cloudflareHeaders => {'Host': 'www.tvtfun.net'};

  /// 解析首页卡片列表
  List<ComicItem> _parseHome(String html) {
    final items = <ComicItem>[];
    // TvTFun 首页卡片结构：<a class="..." href="/video/video-XXX">...<img alt="标题" src="封面">
    final cardRe = RegExp(
        r'<a\b[^>]*?href="(/video/video-[^"]+)"[^>]*>(.*?)</a>',
        dotAll: true);
    for (final m in cardRe.allMatches(html)) {
      final href = m.group(1) ?? '';
      final inner = m.group(2) ?? '';
      final imgAlt =
          RegExp(r'<img[^>]*alt="([^"]+)"').firstMatch(inner)?.group(1);
      var imgSrc =
          RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(inner)?.group(1) ?? '';
      // 解码 Next.js 图片代理 URL
      imgSrc = _resolveNextImageUrl(imgSrc);
      if (href.isEmpty || imgAlt == null) continue;
      items.add(ComicItem(
        href.replaceAll('/video/', ''),
        _unescape(imgAlt.trim()),
        imgSrc,
      ));
    }
    return items;
  }

  /// 解析剧集列表
  List<VideoEpisode> _parseEpisodes(String html) {
    final episodes = <VideoEpisode>[];
    final seen = <String>{};
    for (final m in _epRe.allMatches(html)) {
      final href = m.group(1)?.trim() ?? '';
      if (!seen.add(href)) continue;

      // 提取显示文本（去除 HTML 标签）
      var name = m.group(2) ?? '';
      name = name.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      name = _unescape(name);

      // 提取集数
      final epMatch = RegExp(r'episode=(\d+)').firstMatch(href);
      final ep = int.tryParse(epMatch?.group(1) ?? '') ?? 0;

      episodes.add(VideoEpisode(1, ep, name));
    }
    // 按集数排序
    episodes.sort((a, b) => a.episode.compareTo(b.episode));
    return episodes;
  }

  /// 提取标题（去除站点后缀）
  String? _extractTitle(String html) {
    final raw = _first(_titleRe, html);
    if (raw == null) return null;
    return raw.replaceAll(RegExp(r'\s*[-_|].*$'), '').trim();
  }

  /// 解码 Next.js 图片代理 URL
  String _resolveNextImageUrl(String url) {
    if (url.isEmpty) return url;
    final u = Uri.tryParse(url);
    if (u != null && u.path == '/_next/image') {
      final real = u.queryParameters['url'];
      if (real != null && real.isNotEmpty) {
        return Uri.decodeComponent(real);
      }
    }
    return url;
  }

  String? _first(RegExp re, String html) {
    final m = re.firstMatch(html);
    return m?.group(1);
  }

  String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}