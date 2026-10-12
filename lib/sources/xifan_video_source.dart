import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'video_source.dart';
import 'dsl/html_parser.dart' show htmlUnescape;

/// 稀饭动漫 (XIFAN / xifan.moe) 视频源 —— next.xifanacg.com
///
/// 数据流（Next.js 新站，2026-10 实测）：
/// - 列表 / 搜索：Supabase RPC POST /rest/v1/rpc/search_animes
///     headers 需带 apikey（publishable key，站点前端公开常量）与 Authorization。
///     body: search_term?/page_number/items_per_page/sort_by?/filter_*?
///     返回 [{id,title,cover_url,description,bangumi_score,view_count,is_finished,
///           total_episodes,current_episodes,format,anime_type,rank,...}]
/// - 详情：GET /anime/{id} 服务端渲染，Schema.org JSON-LD(TVSeries) 给元信息，
///     HTML 剧集列表 <li><a href="/anime/{id}/play/{epid}?source={code}">。
///     多线路为 tab（默认线路的剧集完整渲染在 HTML 中，其余线路客户端请求）。
/// - 播放：GET /anime/{id}/play/{epid}?source={code} 播放页，直链由站点 JS
///     请求 issue-web-playback 后注入 <video>。App 返回播放页地址交给内嵌
///     WebView 通道（执行 JS、捕获直链），不再尝试 Dart 侧解析。
class XifanVideoSource extends VideoSource {
  static const String _host = 'https://next.xifanacg.com';
  static const String _apiBase = 'https://api.xifanacg.com/rest/v1/rpc/search_animes';
  // 站点前端公开常量：supabase createBrowserClient(url, key)（05pvawgvkihwy.js）。
  static const String _sbKey =
      'sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA';
  static const int _perPage = 24;

  static final RegExp _ldRe =
      RegExp(r'<script type="application/ld\+json">([\s\S]*?)</script>');
  static final RegExp _titleRe = RegExp(r'<title>([^<]*)</title>');
  static final RegExp _descRe = RegExp(
      r'<meta[^>]+name="description"[^>]+content="([^"]*)"',
      dotAll: true);
  static final RegExp _playRe = RegExp(
      r'href="/anime/\d+/play/(\d+)\?source=([a-z0-9]+)"');
  static final RegExp _epNumRe = RegExp(
      r'<span class="text-lg leading-none font-semibold tabular-nums">(\d+)</span>');
  static final RegExp _epTitleRe = RegExp(
      r'<span class="mt-1 line-clamp-1 text-xs text-ink-muted">([^<]*)</span>');
  static final RegExp _lineRe = RegExp(
      r'aria-label="播放线路"[\s\S]{0,1600}?<span class="relative z-10">([^<]+)</span>');

  /// 详情页解析出的剧集映射：videoId → (episode → epid + 线路代码)。
  /// playUrl(videoId, season, episode) 不携带剧集列表，靠此缓存还原 epid；
  /// 缓存未命中时重新请求详情页补充。
  ///
  /// 上限保护：FIFO 淘汰，避免长时间浏览大量作品时驻留全部详情页解析结果。
  static const int _epCacheMax = 64;
  static final Map<String, Map<int, _EpMap>> _epCache = {};

  static void _cacheEps(String videoId, Map<int, _EpMap> mapping) {
    if (_epCache.length >= _epCacheMax && !_epCache.containsKey(videoId)) {
      _epCache.remove(_epCache.keys.first);
    }
    _epCache[videoId] = mapping;
  }

  @override
  String get id => 'xifan';
  @override
  String get name => '稀饭动漫';

  @override
  Future<List<Category>> categories() async => [
        Category('all', '全部'),
        Category('serial', '连载新番'),
        Category('finished', '完结旧番'),
        Category('tv', 'TV动画'),
        Category('movie', '剧场版'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    return _searchAnimes(_categoryBody(categoryId)..['page_number'] = page
      ..['items_per_page'] = _perPage);
  }

  static Map<String, dynamic> _categoryBody(String categoryId) {
    return {
      if (categoryId == 'serial') 'filter_type_id': 1,
      if (categoryId == 'finished') 'filter_type_id': 2,
      if (categoryId == 'tv') 'filter_format': 'tv',
      if (categoryId == 'movie') 'filter_format': 'movie',
    };
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    if (keyword.trim().isEmpty) return const [];
    // 网络/解析失败直接上抛，由列表页错误态处理，避免把"加载失败"伪装成"无结果"
    return _searchAnimes({
      'search_term': keyword.trim(),
      'page_number': page,
      'items_per_page': _perPage,
    });
  }

  Future<List<ComicItem>> _searchAnimes(Map<String, dynamic> body) async {
    final raw = await Net.post(
      _apiBase,
      headers: _sbHeaders(),
      body: jsonEncode(body),
      // 响应可能较大（24 条 × 长简介），放宽字节上限。
      maxBytes: 4 * 1024 * 1024,
    );
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(_toItem)
        .toList(growable: false);
  }

  static Map<String, String> _sbHeaders() => {
        'apikey': _sbKey,
        'Authorization': 'Bearer $_sbKey',
        'Content-Type': 'application/json',
      };

  ComicItem _toItem(Map<String, dynamic> m) {
    final score = m['bangumi_score'];
    final views = m['view_count'];
    return ComicItem(
      (m['id']?.toString() ?? ''),
      // 列表标题原样保留：站点用年份括号区分同名重制版（实测「福星小子(1981)」
      // 与「福星小子」id=898 是两部作品），清洗会让它们在列表里无法分辨。
      (m['title'] as String? ?? '').trim(),
      (m['cover_url'] as String? ?? '').trim(),
    )
      ..score = (score is num && score > 0) ? score.toString() : null
      ..hits = (views is num && views > 0) ? views.toString() : null
      ..remarks = _remarks(m);
  }

  static String? _remarks(Map<String, dynamic> m) {
    final finished = m['is_finished'] == true;
    final total = m['total_episodes'];
    final cur = m['current_episodes'];
    if (finished) {
      return (total is num && total > 0) ? '全${total.toInt()}集' : '完结';
    }
    if (cur is num && cur > 0) return '更新至${cur.toInt()}集';
    return null;
  }

  @override
  Future<VideoDetail> detail(String videoId) async {
    final html = await Net.get('$_host/anime/$videoId',
        headers: {'Accept': 'text/html'}, timeout: const Duration(seconds: 20));
    return _detailFromHtml(html, videoId);
  }

  /// 测试入口：跳过网络，直接解析给定的详情页 HTML。
  @visibleForTesting
  Future<VideoDetail> detailForTest(String html, String videoId) async =>
      _detailFromHtml(html, videoId);

  /// 测试入口：列表条目 JSON → ComicItem 映射（不请求网络）。
  @visibleForTesting
  List<ComicItem> itemsForTest(List<Map<String, dynamic>> list) =>
      list.map(_toItem).toList(growable: false);

  /// 测试入口：分类 → RPC body 筛选映射。
  @visibleForTesting
  Map<String, dynamic> bodyForTest(String categoryId) =>
      _categoryBody(categoryId);

  Future<VideoDetail> _detailFromHtml(String html, String videoId) async {
    final ld = _ld(html);
    final title = _cleanTitle(ld?['name'] as String? ?? _first(_titleRe, html));
    final cover = _ldImage(ld) ?? '';
    final description =
        ld?['description'] as String? ?? htmlUnescape(_first(_descRe, html));

    final parsed = _parseEpisodes(html);
    if (parsed.episodes.isNotEmpty) _cacheEps(videoId, parsed.mapping);

    final countryRaw = ld?['countryOfOrigin'];
    final country = countryRaw is String
        ? countryRaw
        : (countryRaw is List
            ? countryRaw.whereType<String>().join(' ')
            : '');
    final genre = _genreList(ld);
    final date = ld?['datePublished'] as String? ?? '';
    final year = date.isNotEmpty ? date.split('-').first : null;
    final rating = _rating(ld);
    final type = _typeFrom(genre, date);
    final tags = _tagsFrom(genre, year, country.isNotEmpty ? country : null);
    final line = _lineName(html);

    final item = ComicItem(
      videoId,
      htmlUnescape(title),
      cover,
    );
    if (rating != null) item.score = rating;

    return VideoDetail(
      item,
      parsed.episodes,
      description: description.isNotEmpty ? description : null,
      cover: cover.isNotEmpty ? cover : null,
      area: country.isNotEmpty ? country : null,
      year: year,
      type: type,
      tags: tags,
      lang: _langFrom(genre),
      sourceNames: line == null ? null : {1: line},
    );
  }

  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    final ep = _epCache[videoId]?[episode];
    if (ep != null) return _playPath(videoId, ep);
    // 缓存未命中（如跨会话/清除）：重新请求详情页补 epid 映射。
    final html = await Net.get('$_host/anime/$videoId',
        headers: {'Accept': 'text/html'}, timeout: const Duration(seconds: 20));
    final parsed = _parseEpisodes(html);
    if (parsed.episodes.isEmpty) throw Exception('稀饭：未找到剧集信息');
    _cacheEps(videoId, parsed.mapping);
    final found = _epCache[videoId]?[episode];
    if (found == null) throw Exception('稀饭：未找到第 $episode 集的播放地址');
    return _playPath(videoId, found);
  }

  static String _playPath(String videoId, _EpMap ep) =>
      '$_host/anime/$videoId/play/${ep.epid}?source=${ep.source}';

  /// 从详情页 JSON-LD 脚本解析出结构化对象（TVSeries）。无则返回 null。
  Map<String, dynamic>? _ld(String html) {
    for (final m in _ldRe.allMatches(html)) {
      try {
        final d = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        final t = d['@type'];
        if (t == 'TVSeries' || t == 'Movie' || t == 'VideoObject') return d;
      } catch (_) {
        // 某个 JSON-LD 损坏不影响其余解析
      }
    }
    return null;
  }

  static String? _ldImage(Map<String, dynamic>? ld) {
    final img = ld?['image'];
    if (img is String && img.isNotEmpty) return img;
    if (img is Map && img['url'] is String) return img['url'] as String;
    return null;
  }

  static List<String> _genreList(Map<String, dynamic>? ld) {
    final g = ld?['genre'];
    if (g is List) return g.whereType<String>().toList();
    if (g is String && g.isNotEmpty) {
      return g.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  static String? _rating(Map<String, dynamic>? ld) {
    final r = ld?['aggregateRating'];
    if (r is Map) {
      final v = r['ratingValue'];
      if (v is num && v > 0) return v.toString();
    }
    return null;
  }

  /// 动画形式：从 genre 里取 TV/剧场版/OVA/Web 等词；取不到则按日期年份判断
  /// （2010 年前多为 TV 动画，仅作兜底）。
  static String? _typeFrom(List<String> genre, String date) {
    const forms = ['TV', '剧场版', 'OVA', 'OAD', 'SP', 'Web', '网络动画'];
    for (final f in forms) {
      if (genre.contains(f)) return '$f动画';
    }
    final y = int.tryParse(date.split('-').first);
    if (y != null && y >= 2010) return 'TV动画';
    return null;
  }

  /// 标签集合：genre 里剔除形式/地区/年份类噪声，保留题材词。
  static List<String> _tagsFrom(
      List<String> genre, String? year, String? country) {
    final skip = <String>{
      'TV', '剧场版', 'OVA', 'OAD', 'SP', 'Web', '网络动画', '动画', '日本', '国产',
      if (year != null) year, if (country != null && country.isNotEmpty) country,
    };
    final tags = <String>[];
    for (final g in genre) {
      final t = g.trim();
      if (t.isEmpty || skip.contains(t) || tags.contains(t)) continue;
      tags.add(t);
    }
    return tags;
  }

  /// 配音语言：genre 里常见「日语」「国语」「中配」等词。
  static String? _langFrom(List<String> genre) {
    for (final g in genre) {
      if (g.contains('语') || g.contains('配')) return g;
    }
    return null;
  }

  /// 解析详情页剧集列表（默认线路，服务端完整渲染）。
  /// 返回 [episodes]（按集号排序）与 [mapping]（集号 → epid+线路，供 playUrl）。
  _ParsedEpisodes _parseEpisodes(String html) {
    final episodes = <VideoEpisode>[];
    final mapping = <int, _EpMap>{};
    final seen = <int>{};
    final matches = _playRe.allMatches(html).toList();
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final epid = int.tryParse(m.group(1) ?? '');
      final source = m.group(2) ?? '';
      if (epid == null || source.isEmpty) continue;
      // 解析窗口：700 字符足够容纳一个剧集 <li>（真实快照实测 ~650）；
      // 同时截止在下一个 play 链接之前，绝不跨项取邻居的集号。
      var end = m.end + 700 < html.length ? m.end + 700 : html.length;
      if (i + 1 < matches.length && matches[i + 1].start < end) {
        end = matches[i + 1].start;
      }
      final tail = html.substring(m.end, end);
      // 「立即观看」按钮的 href 也是 /play/{epid}（嵌在首集卡片内，其后紧跟
      // <button>），且与真正剧集项 epid 相同；按钮之后 700 字符内没有集号
      // span，据此跳过——不占 seen 位，否则真正的首集列表项会被误去重。
      final numM = _epNumRe.firstMatch(tail);
      final epNum = int.tryParse(numM?.group(1) ?? '');
      if (epNum == null || !seen.add(epid)) continue;
      final titleM = _epTitleRe.firstMatch(tail);
      final sub = titleM?.group(1)?.trim() ?? '';
      final label = '第${_pad(epNum)}集';
      episodes.add(VideoEpisode(
        1,
        epNum,
        sub.isEmpty ? label : '$label $sub',
        epid: epid,
      ));
      mapping[epNum] = _EpMap(epid, source);
    }
    episodes.sort((a, b) => a.episode.compareTo(b.episode));
    return _ParsedEpisodes(episodes, mapping);
  }

  /// 默认线路名（第一个 aria-label="播放线路" 的 tab 文本），无则 null。
  String? _lineName(String html) {
    final m = _lineRe.firstMatch(html);
    if (m == null) return null;
    final t = _collapse(m.group(1) ?? '');
    return t.isEmpty ? null : htmlUnescape(t);
  }

  /// 标题清洗。JSON-LD 的 name 已是干净标题；只有当它缺失、退回 `<title>`
  /// 时才需要去噪——实测新站 `<title>` 统一为「{标题} ({年份}) · 稀饭动漫 Next」
  /// （588/946/2068/3170/3240 五例一致），故只去站点后缀与年份尾巴。
  ///
  /// 旧站遗留的 `split(' - ')` 与 `_完结` 类后缀正则在实测 600 条标题中
  /// 命中 0 次，且会误伤以「OVA / 剧场版 / SP」结尾的合法标题
  /// （如「少女与战车 剧场版」），已删除。
  static final RegExp _siteSuffixRe = RegExp(r'\s*[·|]\s*稀饭动漫.*$');
  static final RegExp _yearTailRe = RegExp(r'\s*\((?:\d{4}|\d{4}\s*[-–]\s*\d{4})\)\s*$');

  @visibleForTesting
  static String cleanTitleForTest(String raw) => _cleanTitle(raw);

  static String _cleanTitle(String raw) {
    return raw
        .replaceAll(_siteSuffixRe, '')
        .replaceAll(_yearTailRe, '')
        .trim();
  }

  static String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _first(RegExp re, String html) =>
      re.firstMatch(html)?.group(1)?.trim() ?? '';

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// playUrl 需要的剧集映射：epid + 线路代码。
class _EpMap {
  final int epid;
  final String source;
  _EpMap(this.epid, this.source);
}

/// 剧集解析结果：展示列表 + epid 映射。
class _ParsedEpisodes {
  final List<VideoEpisode> episodes;
  final Map<int, _EpMap> mapping;
  _ParsedEpisodes(this.episodes, this.mapping);
}