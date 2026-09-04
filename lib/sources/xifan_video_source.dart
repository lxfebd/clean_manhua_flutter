import 'dart:convert';

import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'video_source.dart';

/// 稀饭动漫 (XIFAN / xifan.moe) 视频源 —— anime.xifanacg.com
///
/// 数据流：
/// - 列表 / 搜索：苹果CMS v10 风格 JSON 接口
///     https://anime.xifanacg.com/index.php/ajax/data.html?mid=1&page=N
///     https://anime.xifanacg.com/index.php/ajax/data.html?mid=1&wd=关键词&page=N
///   返回 list[].vod_id / vod_name / vod_pic / vod_remarks / vod_class
/// - 详情 / 剧集：HTML 页面解析（/bangumi/{id}.html）
/// - 剧集链接：/watch/{id}/{season}/{episode}.html
/// - 播放：播放页内直接给出视频直链（moedot.net 的 mp4，302 跳转到 pan.wo.cn 签名直链，
///   无需 Referer），由 media_kit 直接播放（走 NativePlayerPage，接系统音量/亮度）。
class XifanVideoSource implements VideoSource {
  static const String _host = 'https://anime.xifanacg.com';
  static const String _api = '$_host/index.php/ajax/data.html';

  static final RegExp _titleRe = RegExp(r'<title>([^<]*)</title>');
  static final RegExp _coverRe =
      RegExp(r'<img[^>]*src="(https://img2\.xfmanga\.top/[^"]+)"');
  static final RegExp _descRe = RegExp(
      r'<meta[^>]+name="description"[^>]+content="([^"]*)"',
      dotAll: true);
  // /watch/{videoId}/{线路line}/{集ep}.html —— 只抓取后两个数字（线路=季，集=集）。
  static final RegExp _epRe = RegExp(
      r'href="/watch/\d+/(\d+)/(\d+)\.html"[^>]*>([\s\S]*?)</a>');
  static final RegExp _mp4Re = RegExp(
      r'https?://[^\s"<>]+moedot\.net[^\s"<>]*\.(?:mp4|m3u8)');
  static final RegExp _mp4FallbackRe =
      RegExp(r'https?://[^\s"<>]+\.(?:mp4|m3u8)');

  @override
  String get id => 'xifan';
  @override
  String get name => '稀饭动漫';

  @override
  Future<List<Category>> categories() async => [
        Category('all', '全部'),
        Category('tv', '番剧'),
        Category('manga', '漫画改'),
        Category('novel', '轻小说改'),
        Category('original', '原创'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    if (categoryId == 'all') return _list(page);
    final kws = _classKeywords(categoryId);
    if (kws.isEmpty) return _list(page);
    final out = <ComicItem>[];
    // 列表接口不含地区/年份字段，按 vod_class 标签过滤（TV/剧场版/OVA·SP）。
    // 翻页为累积式：最多向后拉 5 页，凑够约一屏（18 条）后返回。
    for (int p = page; p < page + 8 && out.length < 18; p++) {
      List<Map<String, dynamic>> raw;
      try {
        raw = _parseListRaw(await Net.get('$_api?mid=1&page=$p',
            timeout: const Duration(seconds: 20)));
      } catch (_) {
        break;
      }
      if (raw.isEmpty) break;
      for (final m in raw) {
        final c = (m['vod_class'] as String? ?? '');
        if (kws.any((k) => c.contains(k))) out.add(_toItem(m));
      }
    }
    return out;
  }

  static List<String> _classKeywords(String id) {
    switch (id) {
      case 'tv':
        return const ['TV'];
      case 'manga':
        return const ['漫画改'];
      case 'novel':
        return const ['轻小说改'];
      case 'original':
        return const ['原创'];
      default:
        return const [];
    }
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    if (keyword.trim().isEmpty) return const [];
    final url = '$_api?mid=1&wd=${Uri.encodeQueryComponent(keyword)}&page=$page';
    // 网络/解析失败直接上抛，由列表页错误态处理，避免把"加载失败"伪装成"无结果"
    return _parseList(
        await Net.get(url, timeout: const Duration(seconds: 20)));
  }

  Future<List<ComicItem>> _list(int page) async {
    final url = '$_api?mid=1&page=$page';
    return _parseList(
        await Net.get(url, timeout: const Duration(seconds: 20)));
  }

  List<Map<String, dynamic>> _parseListRaw(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    // code != 1 视为无结果（如翻页越界），返回空列表；
    // 但 jsonDecode/类型转换异常自然上抛，不再被吞掉伪装成"无结果"。
    if (json['code'] != 1) return const [];
    final list = (json['list'] as List?) ?? const [];
    return list
        .map<Map<String, dynamic>>((e) => e as Map<String, dynamic>)
        .toList();
  }

  ComicItem _toItem(Map<String, dynamic> m) {
    final pic = (m['vod_pic'] as String? ?? '').trim();
    return ComicItem(
      (m['vod_id']?.toString() ?? ''),
      _cleanTitle((m['vod_name'] as String? ?? '').trim()),
      pic,
    );
  }

  List<ComicItem> _parseList(String body) => _parseListRaw(body).map(_toItem).toList();

  @override
  Future<VideoDetail> detail(String videoId) async {
    final html = await Net.get('$_host/bangumi/$videoId.html',
        timeout: const Duration(seconds: 20));

    final title = _cleanTitle(_first(_titleRe, html));
    final cover = _first(_coverRe, html);
    final description = _unescape(_first(_descRe, html));

    final episodes = _parseEpisodes(html);
    final rawNames = _parseSourceNames(html);
    Map<int, String>? sourceNames;
    if (rawNames.isNotEmpty) {
      sourceNames = {for (int i = 0; i < rawNames.length; i++) i + 1: rawNames[i]};
    }

    return VideoDetail(
      ComicItem(videoId, title, cover),
      episodes,
      description: description.isNotEmpty ? description : null,
      cover: cover,
      area: _metaText(html, '地区'),
      year: _metaText(html, '年份'),
      type: _metaText(html, '类型'),
      sourceNames: sourceNames,
    );
  }

  /// 解析详情页 [anthology-tab] 里的播放源（线路）名称，按出现顺序返回。
  ///
  /// 例如：稀饭新番主线-1 / 稀饭新番主线-2 / 稀饭备用-1，下标 i 对应
  /// 剧集链接里的 season = i+1。解析失败时返回空列表（不分组）。
  List<String> _parseSourceNames(String html) {
    final tabIdx = html.indexOf('anthology-tab');
    if (tabIdx < 0) return const [];
    // 只取 anthology-tab 到第一个剧集列表块之间，避免误匹配其它 swiper-slide
    final listIdx = html.indexOf('anthology-list-play', tabIdx);
    final rawEnd = listIdx > 0 ? listIdx : (tabIdx + 4000);
    final end = rawEnd > html.length ? html.length : rawEnd;
    final block = html.substring(tabIdx, end);
    final names = <String>[];
    final re =
        RegExp(r'<a[^>]*class="[^"]*swiper-slide[^"]*"[^>]*>([\s\S]*?)</a>');
    for (final m in re.allMatches(block)) {
      final t = _stripTags(m.group(1) ?? '')
          .replaceAll('&nbsp;', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (t.isNotEmpty) names.add(_unescape(t));
    }
    return names;
  }

  // 直链缓存：播放页每次返回 moedot.net 的 302 签名直链，重复请求浪费。
  // 同一集缓存 30 分钟（约等于 pan.wo.cn 签名有效期），过期重新解析播放页。
  static final Map<String, _CachedUrl> _urlCache = {};

  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    final key = '$videoId/$season/$episode';
    final cached = _urlCache[key];
    if (cached != null && !cached.expired) return cached.url;
    // 网络抖动/超时重试一次，避免偶发失败直接打断播放
    String raw;
    try {
      raw = await Net.get('$_host/watch/$videoId/$season/$episode.html',
          timeout: const Duration(seconds: 20));
    } catch (_) {
      raw = await Net.get('$_host/watch/$videoId/$season/$episode.html',
          timeout: const Duration(seconds: 25));
    }
    // 播放页在 <script> 的 JSON 字符串里给出视频地址，斜杠被转义为 \/，
    // 还原成普通 / 后再用正则取直链。
    final html = raw.replaceAll(r'\/', '/');
    final m = _mp4Re.firstMatch(html) ?? _mp4FallbackRe.firstMatch(html);
    if (m == null) {
      // 命中反爬/人机校验落地页时给出可读提示，而非笼统的"未找到直链"
      if (html.contains('captcha') ||
          html.contains('verify') ||
          html.contains('cf-challenge')) {
        throw Exception('稀饭：该线路触发人机校验，请稍后重试或换线路');
      }
      throw Exception('稀饭：未找到播放直链');
    }
    final url = m.group(0)!;
    _urlCache[key] = _CachedUrl(url);
    return url;
  }

  List<VideoEpisode> _parseEpisodes(String html) {
    final episodes = <VideoEpisode>[];
    final seen = <String>{};
    for (final m in _epRe.allMatches(html)) {
      final s = int.tryParse(m.group(1) ?? '');
      final e = int.tryParse(m.group(2) ?? '');
      if (s == null || e == null) continue;
      final key = '$s-$e';
      if (!seen.add(key)) continue;
      final raw = _stripTags(m.group(3) ?? '').trim();
      final title = raw.isEmpty ? '第${_pad(e)}集' : _unescape(raw);
      episodes.add(VideoEpisode(s, e, title));
    }
    episodes.sort((a, b) => a.season == b.season
        ? a.episode.compareTo(b.episode)
        : a.season.compareTo(b.season));
    return episodes;
  }

  /// 提取 label（地区/年份/状态/类型）之后、直到下一个标签或块的纯文本。
  String? _metaText(String html, String label) {
    final i = html.indexOf(label);
    if (i < 0) return null;
    // 截断点：下一个元信息标签，或进入简介/角色区，或首个「·」分隔（类型标签后常接 年·地区）。
    const stops = [
      '地区', '年份', '状态', '动画种类', '简介', '角色', '播放', '分享',
      '收藏', 'Bangumi', '·', '</li>', '</ul>',
    ];
    var end = html.length;
    for (final s in stops) {
      if (s == label) continue;
      final j = html.indexOf(s, i + label.length);
      if (j >= 0 && j < end) end = j;
    }
    final seg = html.substring(i, end);
    var text = seg.replaceAll(RegExp(r'<[^>]+>'), ' ');
    text = text.replaceFirst(
        RegExp('^\\s*${RegExp.escape(label)}\\s*[:：]?\\s*'), '');
    text = text.replaceAll(RegExp(r'[,\s]+$'), ''); // 去掉截断产生的尾部逗号/空白
    return _collapse(text);
  }

  static String _cleanTitle(String raw) {
    var t = raw.split(' - ').first.trim();
    t = t.replaceAll(
        RegExp(r'_(完结|连载中|完结旧番|更新中|TV版|剧场版|OVA|SP)\s*$'), '');
    return t;
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), '').trim();

  static String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _first(RegExp re, String html) =>
      re.firstMatch(html)?.group(1)?.trim() ?? '';

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

class _CachedUrl {
  final String url;
  final DateTime fetched;
  _CachedUrl(this.url) : fetched = DateTime.now();
  bool get expired => DateTime.now().difference(fetched).inMinutes >= 30;
}
