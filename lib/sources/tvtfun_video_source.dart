import 'dart:convert';

import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'dsl/html_parser.dart' show htmlUnescape;
import 'source_config.dart';
import 'video_source.dart';

/// TvTFun 动漫视频源（www.tvtfun.net）。
///
/// ## 2026-11-04 站点改版：JSON API 全量重写
/// 站点从 Next.js 改为 **Nuxt 3 SPA**，旧接口（`/api/videos`、
/// `/api/videos/search`、`/api/videos/resolve-play-url`）全部下线（404
/// 「接口不存在」）。新版接口从 SSR 的 `__NUXT_DATA__` 载荷与
/// `_nuxt/*.js` 路由 chunk 中逆向得到（详见各方法注释）：
///
/// | 用途 | 接口 |
/// |---|---|
/// | 列表/筛选 | `GET /api/client/anime?page&pageSize&tag&area&year&order` |
/// | 搜索 | `GET /api/client/anime?keyword=...&page` |
/// | 筛选维度 | `GET /api/client/site-modules/video-filter` |
/// | 首页热门 | `GET /api/client/site-modules/video-hot-rank` |
/// | 最近更新 | `GET /api/client/site-modules/video-recent?page&limit` |
/// | 详情（含剧集） | `GET /api/client/anime/{slug}` |
/// | 播放线路 | `GET /api/client/anime/watch/{slug}/{ep}/playback` |
/// | 线路解析 | `POST /api/site-auth/playback-resolve` |
///
/// ## 播放为什么走 WebView 而不是自己解析直链
/// `playback-resolve` 有**人机验证门闸**：`GET /api/site-auth/playback-access`
/// 返回 `{"enabled":true,"verified":false,"cap":{...}}`（站点 `/cap/` 验证
/// 组件），未验证时 resolve 直接 403「请先完成播放验证」，且验证状态绑定在
/// 浏览器会话里（原生 HTTP 客户端拿不到）。因此在 App 内无法静默解析直链。
///
/// 处置：`playUrl()` 返回站内播放页 `/watch/{slug}/{ep}`，交给 WebView：
/// 用户在网页里完成一次验证后，站点自带的 artplayer 正常起播；同时
/// `anime_player_page` 的注入脚本会拦截 m3u8/mp4 响应并把直链交给原生播放器
/// （可走 Anime4K 超分），拦截不到时退化为网页内播放，两条路都能看。
///
/// 列表/搜索/详情**不经过验证**，全部走原生 JSON，速度与原生源一致。
class TvTfunVideoSource extends VideoSource {
  static const String base = 'https://www.tvtfun.net';

  /// Cloudflare 优选 IP，用于绕过 DNS 解析失败/污染（沿用旧实现）。
  static const String cloudflareIp = '104.16.150.186';

  /// 每页条数。接口实测 `pageSize` 可调（`limit` 会 400）。
  static const int _pageSize = 30;

  /// 分组缓存：`'$slug|$season|$episode'` → 站内 `watchPath`。
  /// `playUrl` 只拿得到 (slug, season, episode)，而站点的播放键是
  /// `watchPath` 末段（不一定等于集号），故在 `detail()` 时建立映射。
  final Map<String, String> _watchPath = {};

  /// 分类缓存：`video-filter` 是静态维度表，拉一次即可。
  List<Category>? _categories;

  @override
  String get id => 'tvtfun';

  @override
  String get name => 'TvTFun 番剧';

  /// 2026-11-04 重写后可正常使用；站点列表/搜索/详情均为纯 JSON。
  /// （此前因旧 API 全 404 曾临时置为 disabled。）
  @override
  SourceTier get tier => SourceTier.fallback;

  // ── 基础请求 ────────────────────────────────────────────────────────

  /// GET 一个 `{"code":0,"data":{…}}` 形态的接口，返回 `data`。
  Future<Map<String, dynamic>> _apiGet(
    String path, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var url = '$base$path';
    if (query != null && query.isNotEmpty) {
      final qs = query.entries
          .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      url = '$url?$qs';
    }
    final body = await Net.get(
      url,
      headers: const {'Accept': 'application/json'},
      timeout: timeout,
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('TvTFun：接口返回非 JSON 对象');
    }
    final code = decoded['code'];
    if (code != 0) {
      // 站点错误体有两种：{"code":400,"message":…} 与
      // {"error":true,"statusCode":403,"message":…}，都取 message 报出。
      final msg = decoded['message'] ?? decoded['statusMessage'] ?? '$code';
      throw Exception('TvTFun：$msg');
    }
    final data = decoded['data'];
    return data is Map<String, dynamic> ? data : const {};
  }

  // ── 分类 ────────────────────────────────────────────────────────────

  @override
  Future<List<Category>> categories() async {
    final cached = _categories;
    if (cached != null) return cached;

    // 维度表：rows = [{key:'tag'|'year'|'area'|'order', label, options:[{label,value}]}]
    // tag 有 100 项、year 55 项，全塞进分类胶囊会挤爆 UI，故各取前 N 项；
    // order 是排序维度（更新时间/创建时间/播放量/评分），不是内容分类，跳过。
    try {
      final data = await _apiGet('/api/client/site-modules/video-filter');
      final cats = <Category>[Category('all', '全部')];
      final rows = data['rows'];
      if (rows is List) {
        for (final row in rows) {
          if (row is! Map) continue;
          final key = row['key']?.toString() ?? '';
          if (key.isEmpty || key == 'order') continue;
          final limit = key == 'tag' ? 16 : (key == 'year' ? 6 : 12);
          final options = row['options'];
          if (options is! List) continue;
          for (final opt in options.take(limit)) {
            if (opt is! Map) continue;
            final value = opt['value']?.toString() ?? '';
            final label = opt['label']?.toString() ?? value;
            if (value.isEmpty) continue;
            cats.add(Category('$key:$value', label));
          }
        }
      }
      return _categories = cats;
    } catch (_) {
      // 维度表拉取失败不阻断首页：给出「全部 + 排序」最小可用集。
      return _categories = [
        Category('all', '全部'),
        Category('order:hits', '最多播放'),
        Category('order:score', '最高评分'),
      ];
    }
  }

  // ── 列表 / 排行 / 搜索 ──────────────────────────────────────────────

  /// 把 `Category.id`（`all` 或 `tag:xxx` / `area:xxx` / `year:xxx` /
  /// `order:xxx`）解析成接口查询参数。
  Map<String, String> _filterOf(String categoryId) {
    final out = <String, String>{};
    final i = categoryId.indexOf(':');
    if (i > 0) {
      final key = categoryId.substring(0, i);
      final value = categoryId.substring(i + 1);
      if (value.isNotEmpty &&
          (key == 'tag' || key == 'area' || key == 'year' || key == 'order')) {
        out[key] = value;
      }
    }
    return out;
  }

  Future<List<ComicItem>> _listQuery(
    Map<String, String> filter,
    int page, {
    String? keyword,
  }) async {
    final query = <String, String>{
      'page': '$page',
      'pageSize': '$_pageSize',
      if (keyword != null && keyword.trim().isNotEmpty) 'keyword': keyword,
      ...filter,
    };
    final data = await _apiGet('/api/client/anime', query: query);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => _toItem(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) =>
      _listQuery(_filterOf(categoryId), page);

  @override
  Future<List<ComicItem>> search(String keyword, int page) {
    if (keyword.trim().isEmpty) return Future.value(const []);
    return _listQuery(const {}, page, keyword: keyword);
  }

  // ── 详情 ────────────────────────────────────────────────────────────

  @override
  Future<VideoDetail> detail(String videoId) async {
    final data = await _apiGet(
      '/api/client/anime/${Uri.encodeComponent(videoId)}',
      timeout: const Duration(seconds: 30),
    );

    final name = htmlUnescape(data['name']?.toString() ?? videoId);
    final poster = _firstNonEmpty([
      data['posterUrl'],
      data['coverUrl'],
      data['pic'],
      data['picThumb'],
    ]);
    final summary = (data['summary'] ?? data['blurb'])?.toString();
    final area = data['area']?.toString();
    final year = data['year']?.toString();
    final tags = (data['tags'] is List)
        ? (data['tags'] as List)
            .map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toList()
        : const <String>[];

    // 状态 → 展示用类型（TV / 剧场版由 totalEpisodes 推断）
    final total = data['totalEpisodes'];
    final type = (total is int && total <= 1) ? '剧场版' : 'TV';

    final episodes = <VideoEpisode>[];
    final seasons = data['seasons'];
    if (seasons is List) {
      for (var si = 0; si < seasons.length; si++) {
        final season = seasons[si];
        if (season is! Map) continue;
        final seasonNo = _asInt(season['seasonNo']) ?? (si + 1);
        final rawEps = season['episodes'];
        if (rawEps is! List) continue;
        for (var ei = 0; ei < rawEps.length; ei++) {
          final ep = rawEps[ei];
          if (ep is! Map) continue;
          final watchPath = ep['watchPath']?.toString() ?? '';
          if (watchPath.isEmpty) continue;
          // 站点的 `number` 字段存在重复（特别篇/重制版与正片共用集号，
          // 航海王实测 number=1 出现 3 次；`watchPath` 才是唯一键）。若按
          // number 建缓存会互相覆盖、播放串集（选了第 1 集却拉回第 3 个 1）。
          // 故集号一律取 season 内连续序号（1..N，与站点列表顺序一致）。
          final epNo = ei + 1;
          _watchPath['$videoId|$seasonNo|$epNo'] = watchPath;
          final title = ep['title']?.toString().trim();
          episodes.add(VideoEpisode(
            seasonNo,
            epNo,
            (title == null || title.isEmpty) ? '第$epNo集' : title,
          ));
        }
      }
    }
    // 兜底：剧集缺失但 totalEpisodes 已知时，按集号直接生成（playUrl 走
    // `/watch/{slug}/{n}` 约定，与站点 URL 规则一致）。
    if (episodes.isEmpty && total is int && total > 0) {
      for (var n = 1; n <= total; n++) {
        episodes.add(VideoEpisode(1, n, '第$n集'));
        _watchPath['$videoId|1|$n'] = '/watch/$videoId/$n';
      }
    }
    episodes.sort((a, b) => a.season != b.season
        ? a.season.compareTo(b.season)
        : a.episode.compareTo(b.episode));

    final item = ComicItem(videoId, name, poster ?? '')
      ..content = summary
      ..score = data['score']?.toString()
      ..hits = data['playCount']?.toString()
      ..remarks = (total is int && total > 0) ? '全$total集' : null;

    return VideoDetail(
      item,
      episodes,
      description: summary,
      cover: poster,
      area: area,
      year: year,
      type: type,
      tags: tags,
    );
  }

  // ── 播放 ────────────────────────────────────────────────────────────

  /// 返回站内播放页（非直链）→ 播放器按 `isDirectMediaUrl` 判定后走 WebView。
  ///
  /// 播放页内的验证与解析由站点自己完成；注入的 JS 会顺带捕获 m3u8 交给
  /// 原生播放器。见类注释「播放为什么走 WebView」。
  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    final cached = _watchPath['$videoId|$season|$episode'];
    final path = cached ?? '/watch/$videoId/$episode';
    // 域名解析失败/被污染时回退 Cloudflare 优选 IP（沿用旧实现的行为）。
    try {
      await Net.get(base, timeout: const Duration(seconds: 10));
      return '$base$path';
    } catch (_) {
      return 'https://$cloudflareIp$path';
    }
  }

  /// 返回使用 Cloudflare 优选 IP 的播放页 URL（绕过 DNS 解析失败）。
  String cloudflarePlayUrl(String videoId, int season, int episode) {
    final path = _watchPath['$videoId|$season|$episode'] ?? '/watch/$videoId/$episode';
    return 'https://$cloudflareIp$path';
  }

  // ── 条目映射与工具 ──────────────────────────────────────────────────

  /// API 条目 → [ComicItem]。
  ///
  /// 新版条目字段：`{id, code, slug, name, originalName, bangumiScore,
  /// totalEpisodes, posterUrl, coverUrl, tags, summary, hits, playCount}`
  ComicItem _toItem(Map<String, dynamic> v) {
    final slug = _firstNonEmpty([v['slug'], v['id']]) ?? '';
    final poster = _firstNonEmpty([
      v['posterUrl'],
      v['coverUrl'],
      v['pic'],
      v['picThumb'],
    ]) ?? '';
    final total = _asInt(v['totalEpisodes']);
    final remarks = (total != null && total > 0)
        ? (total <= 1 ? '剧场版' : '全$total集')
        : null;
    return ComicItem(slug, htmlUnescape(v['name']?.toString() ?? ''), poster)
      ..yname = htmlUnescape(v['originalName']?.toString() ?? '')
      ..score = v['bangumiScore']?.toString()
      ..hits = (v['hits'] ?? v['playCount'])?.toString()
      ..content = v['summary']?.toString()
      ..remarks = remarks;
  }

  static String? _firstNonEmpty(List<dynamic> values) {
    for (final v in values) {
      final s = v?.toString().trim() ?? '';
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }
}
