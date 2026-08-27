import 'dart:convert';

import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'video_source.dart';

/// Anime1.me 动画源（anime1.me）。
///
/// 纯文本站点（无封面图、无简介），结构：
/// - 全量番剧目录：https://anime1.me/animelist.json
///   `[catId, 标题, 状态, 年, 季度, 类型]`；catId=0 为 18+ 条目，不入列表。
/// - 单部番剧页：https://anime1.me/?cat={catId}，页内列出全部剧集，
///   每集一个独立播放页 https://anime1.me/{epId}，剧集标题带 `[NN]` 集号。
/// - 播放：播放页内 `<video>` 带 data-apireq 参数，站点 JS 将其 POST 到
///   v.anime1.me/api 换取 CDN mp4 直链；API 响应会 Set-Cookie（h/p/e，
///   路径限定 .v.anime1.me/{cat}/{ep}.mp4），是直链访问凭证，原生播放器
///   无法携带这些 Cookie，故播放走 WebView（同域自动携带），[playUrl]
///   直接返回剧集页 URL，由 AnimePlayerPage 拦截/播放处理。
class Anime1VideoSource implements VideoSource {
  static const String _base = 'https://anime1.me';
  static const String _listUrl = '$_base/animelist.json';

  @override
  String get id => 'anime1';
  @override
  String get name => 'Anime1';

  // ---- 全量目录（内存缓存 10 分钟，约 2k 条）----
  static List<_AnimeEntry>? _cache;
  static DateTime? _cacheAt;

  /// 剧集页 URL 映射缓存：key=catId，value=episode(1 基) -> epId。
  /// detail() 解析后填充，playUrl 直接复用，避免重复拉取番剧页。
  static final Map<String, Map<int, String>> _epIdCache = {};

  static final RegExp _epLinkRe = RegExp(
      r'href="(?:https?://(?:www\.)?anime1\.me)?/(\d+)"[^>]*>[^<]*\[(\d+)\][^<]*</a>');
  static final RegExp _h1Re = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>');
  static final RegExp _plainEpRe = RegExp(
      r'href="(?:https?://(?:www\.)?anime1\.me)?/(\d+)"');

  Future<List<_AnimeEntry>> _entries() async {
    final now = DateTime.now();
    if (_cache != null &&
        _cacheAt != null &&
        now.difference(_cacheAt!).inMinutes < 10) {
      return _cache!;
    }
    try {
      final body = await Net.get(_listUrl, timeout: const Duration(seconds: 20));
      final list = jsonDecode(body) as List;
      final out = <_AnimeEntry>[];
      for (final raw in list) {
        final a = raw as List;
        final catId = a.isNotEmpty ? int.tryParse(a[0].toString()) ?? 0 : 0;
        if (catId <= 0) continue; // catId=0 为 18+，不入列表
        out.add(_AnimeEntry(
          catId,
          a.length > 1 ? a[1].toString().trim() : '',
          a.length > 2 ? a[2].toString().trim() : '',
          a.length > 3 ? a[3].toString().trim() : '',
          a.length > 4 ? a[4].toString().trim() : '',
          a.length > 5 ? a[5].toString().trim() : '',
        ));
      }
      out.sort((a, b) => b.catId.compareTo(a.catId)); // 新版在前
      _cache = out;
      _cacheAt = now;
      return out;
    } catch (e) {
      // 有缓存就用缓存（合理降级）；首次加载无缓存则上抛，由首页错误态提示重试
      if (_cache != null) return _cache!;
      rethrow;
    }
  }

  static const Map<String, int> _seasonOrder = {
    '冬': 1,
    '春': 2,
    '夏': 3,
    '秋': 4,
  };

  @override
  Future<List<Category>> categories() async {
    final list = await _entries();
    final cats = <Category>[
      Category('all', '全部'),
      Category('ongoing', '連載中'),
    ];
    final seen = <String>{};
    final combos = <(String, String)>[];
    for (final e in list) {
      // 只取季度字段为单一季节的条目（少数跨季/跨年番不进季度分类，避免脏 id）
      if (e.normYear.isEmpty || !_seasonOrder.containsKey(e.season)) continue;
      final key = '${e.normYear}${e.season}';
      if (seen.add(key)) combos.add((e.normYear, e.season));
    }
    combos.sort((a, b) {
      final c = b.$1.compareTo(a.$1);
      if (c != 0) return c;
      return (_seasonOrder[b.$2] ?? 0).compareTo(_seasonOrder[a.$2] ?? 0);
    });
    for (final (y, s) in combos.take(12)) {
      cats.add(Category('$y$s', '$y $s番'));
    }
    return cats;
  }

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final list = await _entries();
    Iterable<_AnimeEntry> filtered;
    if (categoryId == 'ongoing') {
      filtered = list.where((e) => e.status.contains('連載中'));
    } else if (categoryId.length >= 5) {
      final y = categoryId.substring(0, 4);
      final s = categoryId.substring(4);
      filtered =
          list.where((e) => e.normYear == y && e.season == s);
    } else {
      filtered = list;
    }
    return _page(filtered.toList(), page).map(_toItem).toList();
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return const [];
    final list = await _entries();
    final hit = list.where((e) => e.title.toLowerCase().contains(kw)).toList();
    return _page(hit, page).map(_toItem).toList();
  }

  @override
  Future<VideoDetail> detail(String videoId) async {
    final catId = videoId;
    final html = await Net.get('$_base/?cat=$catId',
        timeout: const Duration(seconds: 20));

    // 标题取页面最后一个 h1（首个 h1 是站点标题「Anime1.me 動畫線上看」）。
    // 不同页面 h1 class 不统一（page-title / entry-title），故不用 class 匹配。
    var title = '';
    for (final m in _h1Re.allMatches(html)) {
      final t = _unescape(_stripTags(m.group(1) ?? '')).trim();
      if (t.isNotEmpty) title = t;
    }
    if (title == 'Anime1.me 動畫線上看' || title.isEmpty) {
      title = _fallbackTitle(catId);
    }

    final epId = <int, String>{};
    final episodes = <VideoEpisode>[];
    for (final m in _epLinkRe.allMatches(html)) {
      final eid = m.group(1)!;
      final n = int.tryParse(m.group(2) ?? '');
      if (n == null || epId.containsKey(n)) continue;
      epId[n] = eid;
      episodes.add(VideoEpisode(1, n, '第${_pad(n)}話'));
    }
    // 兜底：剧集标题无 [NN] 的站点按出现顺序编号
    if (episodes.isEmpty) {
      final seen = <String>{};
      var n = 0;
      for (final m in _plainEpRe.allMatches(html)) {
        if (!seen.add(m.group(1)!)) continue;
        n++;
        epId[n] = m.group(1)!;
        episodes.add(VideoEpisode(1, n, '第${_pad(n)}話'));
      }
    }
    episodes.sort((a, b) => a.episode.compareTo(b.episode));
    _epIdCache[catId] = epId;

    // 用目录元信息补全年份/类型/季度
    _AnimeEntry? meta;
    for (final e in await _entries()) {
      if (e.catId.toString() == catId) {
        meta = e;
        break;
      }
    }

    return VideoDetail(
      ComicItem(catId, title, ''),
      episodes,
      description: null,
      area: null,
      year: (meta == null || meta.year.isEmpty) ? null : meta.year,
      type: (meta == null || meta.genre.isEmpty) ? null : meta.genre,
      tags: [if (meta != null && meta.season.isNotEmpty) '${meta.season}番'],
    );
  }

  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    var map = _epIdCache[videoId];
    if (map == null || !map.containsKey(episode)) {
      await detail(videoId); // 未先经过 detail：重新建立剧集映射
      map = _epIdCache[videoId] ?? const {};
    }
    final eid = map[episode];
    if (eid == null) {
      throw Exception('Anime1：未找到第 $episode 話的播放地址');
    }
    return '$_base/$eid';
  }

  static List<_AnimeEntry> _page(List<_AnimeEntry> all, int page) {
    const size = 20;
    final start = (page - 1) * size;
    if (start >= all.length) return const [];
    final end = (start + size).clamp(0, all.length);
    return all.sublist(start, end);
  }

  static ComicItem _toItem(_AnimeEntry e) {
    return ComicItem(e.catId.toString(), e.title, '')
      ..remarks = e.status.isEmpty ? null : e.status
      ..yname = e.genre.isEmpty ? null : e.genre;
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), '').trim();

  /// 标题兜底：从全量目录（animelist.json）按 catId 反查番剧标题。
  String _fallbackTitle(String catId) {
    for (final e in _cache ?? const <_AnimeEntry>[]) {
      if (e.catId.toString() == catId) return e.title;
    }
    return '番剧 $catId';
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// animelist.json 单条：[catId, 标题, 状态, 年, 季度, 类型]。
class _AnimeEntry {
  final int catId;
  final String title;
  final String status; // 如「連載中(08)」「1-12」
  final String year;
  final String season; // 冬/春/夏/秋
  final String genre;
  _AnimeEntry(this.catId, this.title, this.status, this.year, this.season,
      this.genre);

  /// 归一化年份：跨年番年份字段可能是「2025/2026」，取最后一个 4 位年份，
  /// 保证分类 id（如 2026夏）可被 listByCategory 稳定 substring 解析。
  String get normYear {
    final m = RegExp(r'(\d{4})\s*$').firstMatch(year.trim());
    return m?.group(1) ?? '';
  }
}
