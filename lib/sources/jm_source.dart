import 'dart:convert';

import '../models/comic_item.dart';
import '../net/circuit_breaker.dart';
import '../net/http_client.dart';
import '../net/jm_crypto.dart';
import 'comic_source.dart';
import 'source_config.dart';

/// 禁漫天堂源（App API 版）。
///
/// 协议参照 hect0x7/JMComic-Crawler-Python 的 JmApiClient：
///   1. 请求带 `token` (MD5) 与 `tokenparam` (ts,ver) 头；
///   2. 响应 data 是 AES-256-ECB 加密的 JSON（key = MD5("{ts}{secret}").hex utf-8）；
///   3. 图片 URL：`https://{cdn}/media/photos/{photo_id}/{filename}`。
///
/// 关键改造：
///   1. 域名/镜像外置到 [SourceConfigStore]，可由用户在「数据源管理」调整，免发版。
///   2. 每源熔断器，连续失败自动冷却。
///   3. 图片加扰还原由 [JmScramble]（按 aid + filename MD5 算分块数 + 纵向块倒序）处理。
///
/// 注意：禁漫域名变动频繁，且在国内网络下可能需代理/镜像才能连通。
class JmSource extends ComicSource {
  /// API 兜底域名（用户在源配置可覆盖）。取自 JMComic 最新配置 + 域名服务器解析。
  static const List<String> _builtinHosts = [
    'https://www.cdnhjk.net',
    'https://www.cdngwc.cc',
    'https://www.cdngwc.net',
    'https://www.cdngwc.club',
    'https://www.cdnutc.me',
  ];

  /// 图片 CDN 兜底域名。
  static const List<String> _builtinImageHosts = [
    'https://cdn-msp2.jmapiproxy2.cc',
    'https://cdn-msp.jmapinodeudzn.net',
    'https://cdn-msp.jmapiproxy1.cc',
  ];

  /// 封面默认 URL 模板：`https://{cdn}/media/albums/{id}.jpg`。
  static const String _coverPathTemplate = '/media/albums/';

  /// 章节图片 URL 模板：`https://{cdn}/media/photos/{photo_id}/{filename}`。
  static const String _photoPathTemplate = '/media/photos/';

  static int _workingHostIndex = 0;
  static String? _currentHost;

  @override
  String get id => 'jm';

  @override
  String get name => '禁漫天堂';

  @override
  SourceTier get tier => SourceTier.fallback;

  String get baseUrl => _currentHost ?? _builtinHosts[_workingHostIndex];

  @override
  Future<List<Category>> categories() async {
    return [
      Category('hanman', '韩漫'),
      Category('doujin', '同人'),
      Category('single', '单本'),
      Category('short', '短篇'),
      Category('meiman', '美漫'),
      Category('another', '其他'),
    ];
  }

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    // c = 分类代码；o = 排序（mv=最新，mv_m=本月热门，mv_w=本周热门）
    final json = await _getJson(
        '/categories/filter?page=$page&order=&c=$categoryId&o=mv');
    return _parseList(json);
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    final json =
        await _getJson('/categories/filter?page=$page&order=&c=all&o=mv');
    return _parseList(json);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final q = Uri.encodeQueryComponent(keyword);
    // main_tag=0 (all); o=mv 最新; t=0 (all time)
    final json = await _getJson(
        '/search?main_tag=0&search_query=$q&page=$page&o=mv&t=0');
    return _parseList(json);
  }

  @override
  Future<ComicDetail> detail(String comicId) async {
    final json = await _getJson('/album?id=$comicId');
    final album = json;
    final title = _str(album['name']) ?? '漫画$comicId';
    final author = _str(album['author']) ?? '';

    // 章节列表：series 数组（多数本）; 单章节本 series=[] 但有 series_id + total_photos
    final seriesRaw = album['series'] ?? [];
    final List<dynamic> series =
        seriesRaw is List ? seriesRaw : const <dynamic>[];
    final chapters = <Chapter>[];
    for (int i = 0; i < series.length; i++) {
      final s = _asMap(series[i]);
      if (s == null) continue;
      final cid = _str(s['id']) ?? '';
      if (cid.isEmpty) continue;
      final cname = _str(s['name']) ?? '第${i + 1}话';
      chapters.add(Chapter(cid, cname));
    }
    // 单章节本：series 为空但有 series_id 指向唯一的 photo id
    if (chapters.isEmpty) {
      final sid = _str(album['series_id']);
      if (sid != null && sid.isNotEmpty) {
        chapters.add(Chapter(sid, _str(album['name']) ?? '开始阅读'));
      } else {
        // 完全无章节：尝试用 album id 当 chapter id（仍会触底错误）
        chapters.add(Chapter(comicId, '开始阅读'));
      }
    }

    return ComicDetail(
      ComicItem(comicId, title, await _coverUrl(comicId))..author = author,
      chapters,
      author: author,
      description: _str(album['description']),
    );
  }

  @override
  Future<List<String>> chapterPics(String chapterId) async {
    final json = await _getJson('/chapter?id=$chapterId');
    final chapter = json;
    final imagesRaw = chapter['images'] ?? [];
    final List<dynamic> images =
        imagesRaw is List ? imagesRaw : const <dynamic>[];
    if (images.isEmpty) {
      throw Exception('禁漫章节图片为空（可能需登录或域名失效）。');
    }
    // 用 imageHosts 拼图 URL（每个文件名 + 第一个可用 CDN）
    final imgHosts =
        await SourceConfigStore.imageHostsFor('jm', _builtinImageHosts);
    final baseCdn = imgHosts.first;
    final result = <String>[];
    for (final raw in images) {
      final name = _str(raw);
      if (name == null || name.isEmpty) continue;
      result.add('$baseCdn$_photoPathTemplate$chapterId/$name');
    }
    return result;
  }

  /// 解析列表（categories/filter 与 search 共用结构）。
  Future<List<ComicItem>> _parseList(Map<String, dynamic> json) async {
    final listRaw = json['content'] ?? json['data'] ?? json['docs'] ?? [];
    final List<dynamic> list = listRaw is List ? listRaw : const <dynamic>[];
    if (list.isEmpty) {
      throw Exception('禁漫未返回漫画列表（可能签名/版本已变）。');
    }
    final items = <ComicItem>[];
    for (final m in list) {
      final mm = _asMap(m);
      if (mm == null) continue;
      final id = _str(mm['id']) ?? '';
      if (id.isEmpty) continue;
      final name = _str(mm['name']) ?? _str(mm['title']) ?? '未命名';
      final author = _str(mm['author']) ?? '';
      items.add(ComicItem(id, name, await _coverUrl(id))..author = author);
    }
    return items;
  }

  /// 封面 URL：API 列表/详情都不直接给封面，按固定模板 `media/albums/{id}.jpg` 构造。
  Future<String> _coverUrl(String albumId) async {
    final imgHosts =
        await SourceConfigStore.imageHostsFor('jm', _builtinImageHosts);
    return '${imgHosts.first}$_coverPathTemplate$albumId.jpg';
  }

  /// 发起请求：生成 ts+token，逐个镜像域名尝试，解密 AES 响应。
  Future<Map<String, dynamic>> _getJson(String path) async {
    final hosts = await SourceConfigStore.hostsFor('jm', _builtinHosts);
    final cb = CircuitBreakerRegistry.forHost('jm');
    if (!cb.allowRequest()) {
      throw Exception('禁漫源暂时不可用（熔断冷却中，请稍后重试）。');
    }

    Exception? lastErr;
    final order = <int>[];
    for (int i = 0; i < hosts.length; i++) {
      order.add((_workingHostIndex + i) % hosts.length);
    }
    for (final idx in order) {
      final host = hosts[idx];
      try {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final auth = JmCrypto.makeHeaders(ts);
        final text = await Net.get('$host$path', headers: {
          'User-Agent': _ua,
          'Accept': 'application/json, text/plain, */*',
          'Accept-Encoding': 'gzip, deflate',
          'token': auth.token,
          'tokenparam': auth.tokenparam,
        });
        final outer = jsonDecode(text);
        if (outer is! Map) {
          throw Exception('禁漫接口返回非 JSON（可能域名失效）。');
        }
        _workingHostIndex = idx;
        _currentHost = host;
        cb.recordSuccess();
        // 解密 data（如果 code!=200，data 通常为空/errorMsg 直接抛）
        final code = outer['code'];
        final data = outer['data'];
        if (code == 200) {
          if (data is String && data.isNotEmpty) {
            final plain = JmCrypto.decryptResponseData(data, ts);
            final inner = jsonDecode(plain);
            if (inner is Map<String, dynamic>) return inner;
          }
          if (data is Map<String, dynamic>) return data;
        }
        throw Exception('禁漫接口错误码 $code：${outer['errorMsg'] ?? ''}');
      } catch (e) {
        lastErr = e is Exception ? e : Exception(e.toString());
      }
    }
    cb.recordFailure();
    throw Exception(
        '禁漫天堂暂时无法连接（所有镜像域名均失败）。\n'
        '可能是国内网络被限制或签名密钥已轮换。\n'
        '原始错误：${lastErr?.toString() ?? '未知'}');
  }

  /// App UA（必须与 jmcomic 一致，server 据此识别）。
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 9; V1938CT Build/PQ3A.190705.11211812; wv) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/91.0.4472.114 Safari/537.36';

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map<String, dynamic> ? v : (v is Map ? Map<String, dynamic>.from(v) : null);

  static String? _str(dynamic v) => v == null ? null : v.toString();
}