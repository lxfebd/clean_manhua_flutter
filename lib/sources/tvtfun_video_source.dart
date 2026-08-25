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
/// - 列表 / 分类 / 搜索：HTTP JSON API
///     https://www.tvtfun.net/api/videos?pageIndex=N&pageSize=M[&area=X][&tag=Y]
///     https://www.tvtfun.net/api/videos/search?q=关键词&pageSize=M&page=N
///   返回 list[].slug / name / pic / remarks / score / tag / area / year
/// - 详情：HTML 页面解析剧集与元信息（年份/地区/标签）
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

  /// 服务端渲染的元信息行：<span ...>年份</span><span class="truncate">2026</span>
  static final RegExp _metaRowRe = RegExp(
      r'<span class="shrink-0 text-white/50">([^<]+)</span>'
      r'<span class="truncate">([^<]+)</span>');

  /// Next.js RSC 内嵌 JSON 里的 tag 字段：..."tag":"动画,动作冒险,奇幻",...
  /// （RSC payload 是 JS 字符串，双引号被转义为 \"）
  static final RegExp _embeddedTagRe = RegExp(
      r'\\"tag\\":\\"([^"\\]+)\\"');

  @override
  String get id => 'tvtfun';
  @override
  String get name => 'TvTFun 番剧';

  @override
  Future<List<Category>> categories() async => [
        Category('all', '全部'),
        Category('jp', '日本'),
        Category('cn', '国创'),
        Category('kr', '韩国'),
        Category('movie', '剧场版'),
        Category('tag_恋爱', '恋爱'),
        Category('tag_搞笑', '搞笑'),
        Category('tag_奇幻', '奇幻'),
        Category('tag_科幻', '科幻'),
        Category('tag_治愈', '治愈'),
        Category('tag_校园', '校园'),
        Category('tag_战斗', '战斗'),
        Category('year_2026', '2026年'),
        Category('year_2025', '2025年'),
        Category('year_2024', '2024年'),
        Category('year_2023', '2023年'),
        Category('year_2022', '2022年'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final params = <String, String>{
      'pageIndex': page.toString(),
      'pageSize': '20',
    };
    if (categoryId == 'jp') {
      params['area'] = '日本';
    } else if (categoryId == 'cn') {
      params['area'] = '中国';
    } else if (categoryId == 'kr') {
      params['area'] = '韩国';
    } else if (categoryId == 'movie') {
      params['tag'] = '剧场版';
    } else if (categoryId.startsWith('tag_')) {
      params['tag'] = categoryId.substring(4);
    } else if (categoryId.startsWith('year_')) {
      params['year'] = categoryId.substring(5);
    }
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final json = jsonDecode(await Net.get('$base/api/videos?$query',
        headers: const {'Cookie': 'quality=1080'},
        timeout: const Duration(seconds: 30)));
    final videos = (json['data']?['videos'] as List? ?? const []);
    return videos.map<ComicItem>((v) => _toItem(v as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    if (keyword.trim().isEmpty) return const [];
    final url = '$base/api/videos/search'
        '?q=${Uri.encodeQueryComponent(keyword)}&pageSize=10&page=$page';
    final json = jsonDecode(await Net.get(url,
        headers: const {'Cookie': 'quality=1080'},
        timeout: const Duration(seconds: 30)));
    final videos = (json['data']?['videos'] as List? ?? const []);
    return videos
        .map<ComicItem>((v) => _toItem(v as Map<String, dynamic>))
        .toList();
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

    // 年份/地区/语言来自服务端渲染的元信息行
    String? area;
    String? year;
    String? type;
    String? lang;
    for (final m in _metaRowRe.allMatches(html)) {
      final label = m.group(1)?.trim() ?? '';
      final value = _unescape(m.group(2)?.trim() ?? '');
      if (label == '年份') year = value;
      if (label == '地区') area = value;
      if (label == '类型') type = value;
      if (label == '语言') lang = value;
    }

    // 标签来自 RSC 内嵌 JSON 的 tag 字段（以逗号分隔）
    final tags = _embeddedTagRe
        .firstMatch(html)
        ?.group(1)
        ?.split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList() ??
        const <String>[];

    final item = ComicItem(videoId, title, cover ?? '')
      ..lang = lang;
    return VideoDetail(
      item,
      episodes,
      description: description,
      cover: cover,
      area: area,
      year: year,
      type: type,
      lang: lang,
      tags: tags,
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

  /// API 条目 -> ComicItem（带评分 / 更新提示 / 别名等元信息）
  ComicItem _toItem(Map<String, dynamic> v) {
    final slug = (v['slug'] as String? ?? '').isNotEmpty
        ? v['slug'] as String
        : (v['id'] as String? ?? '');
    var cover = (v['pic'] as String? ?? '');
    // 解码 Next.js 图片代理 URL
    if (cover.contains('/_next/image')) {
      final u = Uri.tryParse(cover);
      final real = u?.queryParameters['url'];
      if (real != null && real.isNotEmpty) {
        cover = Uri.decodeComponent(real);
      }
    }
    final score = v['score'];
    final hits = v['hitsMonth'] ?? v['hits'];
    return ComicItem(
      slug,
      (v['name'] as String?) ?? '',
      cover,
    )
      ..yname = (v['sub'] as String?) ?? ''
      ..score = score?.toString()
      ..hits = hits?.toString()
      ..content = (v['content'] as String?) ?? ''
      ..remarks = (v['remarks'] as String?) ?? ''
      ..lang = (v['lang'] as String?) ?? '';
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
