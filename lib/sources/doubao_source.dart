import 'dart:convert';
import 'dart:typed_data';

import '../models/comic_item.dart';
import '../net/aes_cbc.dart';
import 'comic_source.dart';
import 'source_http.dart';

/// 豆包漫画源（www.doubaomanhua.com）。
/// 列表/分类/搜索/详情章节均为明文 HTML，可直接解析；
/// 章节图片通过 AES-128-CBC(PKCS7) 解密获得（key=5V&RoR%Jf@pJPydF）。
class DoubaoSource extends ComicSource {
  static const String _base = 'https://www.doubaomanhua.com';
  static const List<String> _fallbackHosts = [_base];
  static final Uint8List _key = Uint8List.fromList(
      '5V&RoR%Jf@pJPydF'.codeUnits);

  static final RegExp _itemRe = RegExp(
      r'<a\s+href="/detail/([A-Za-z0-9]+)"\s+title="([^"]*)">[\s\S]*?data-original="([^"]*)"');
  static final RegExp _chapterRe = RegExp(
      r'ewave-playlist-item">\s*<a class="text-overflow" href="/detail/([A-Za-z0-9]+)/(\d+)\.html">([^<]*)</a>');

  static final RegExp _h1Re = RegExp(r'<h1[^>]*>([^<]*)</h1>');
  // 详情页没有 <h1>，标题在 <title>（形如「XX - XX漫画免费阅读 - 豆包漫画」）
  static final RegExp _titleRe =
      RegExp(r'<title>\s*([^<]*?)\s*-\s*(?:[^-<]*?)\s*</title>');
  static final RegExp _coverRe =
      RegExp(r'data-original="(https://img\.doubaomanhua\.com[^"]*)"');
  static final RegExp _paramsRe =
      RegExp(r'''var\s+params\s*=\s*['"]([A-Za-z0-9+/=_-]+)['"]''');

  @override
  String get id => 'doubao';
  @override
  String get name => '豆包漫画';

  @override
  Future<List<Category>> categories() async => [
        Category('guonei', '国内'),
        Category('riben', '日本'),
        Category('hanguo', '韩国'),
        Category('oumei', '欧美'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async =>
      await _parseList(await SourceHttp.get('doubao',
          '/list/area/$categoryId?page=$page',
          fallbackHosts: _fallbackHosts));

  @override
  Future<List<ComicItem>> rank(int page) async =>
      await _parseList(await SourceHttp.get('doubao', '/list?page=$page',
          fallbackHosts: _fallbackHosts));

  @override
  Future<List<ComicItem>> search(String keyword, int page) async =>
      await _parseList(await SourceHttp.get('doubao',
          '/search?q=${Uri.encodeQueryComponent(keyword)}&page=$page',
          fallbackHosts: _fallbackHosts));

  @override
  Future<ComicDetail> detail(String comicId) async {
    final body = await SourceHttp.get('doubao', '/detail/$comicId',
        fallbackHosts: _fallbackHosts);
    // 详情页通常有 <h1>，缺失时回退到 <title>（形如「XX - XX漫画免费阅读 - 豆包漫画」）
    var title = _first(_h1Re, body);
    if (title.isEmpty) title = _first(_titleRe, body);
    final cover = _first(_coverRe, body);
    final chapters = _chapterRe.allMatches(body).map((m) => Chapter(
        '${m.group(1)}/${m.group(2)}', _unescape(m.group(3) ?? ''))).toList();
    // ignore: avoid_print
    print('[DOUBAO-DEBUG] id=$comicId bodyLen=${body.length} '
        'hasChapterRe=${_chapterRe.hasMatch(body)} '
        'chapterCount=${chapters.length} titleRe=${title.isNotEmpty} '
        'sample=${body.length > 200 ? body.substring(0, 200) : body}');
    return ComicDetail(ComicItem(comicId, title, cover), chapters);
  }

  @override
  Future<List<String>> chapterPics(String chapterId) async {
    final body = await SourceHttp.get('doubao', '/detail/$chapterId.html',
        fallbackHosts: _fallbackHosts);
    final m = _paramsRe.firstMatch(body);
    if (m == null) return const <String>[];
    final payload = m.group(1)!;
    final cipherBytes = _b64UrlDecode(payload);
    if (cipherBytes == null || cipherBytes.length < 32) return const <String>[];
    final iv = Uint8List.sublistView(cipherBytes, 0, 16);
    final cipher = Uint8List.sublistView(cipherBytes, 16);
    Uint8List plain;
    try {
      plain = AesCbc.decryptCbc(cipher, _key, iv);
    } catch (_) {
      return const <String>[];
    }
    final text = utf8.decode(plain);
    final Map<String, dynamic> obj = jsonDecode(text) as Map<String, dynamic>;
    final list = obj['chapter_images'];
    if (list is! List) return const <String>[];
    // 章节图片是相对路径（如 /scomic/...），需按 cms.js 的 getImageUrl 逻辑
    // 补上 images_hosts 里的图床域名，否则无法加载。
    final hosts = obj['images_hosts'];
    final host =
        hosts is List && hosts.isNotEmpty ? hosts.first.toString() : null;
    if (host == null || host.isEmpty) {
      return list.whereType<String>().where((s) => s.isNotEmpty).toList();
    }
    return list.whereType<String>().where((s) => s.isNotEmpty).map((s) {
      if (s.startsWith('http://') ||
          s.startsWith('https://') ||
          s.startsWith('//')) {
        return s;
      }
      return '$host${s.startsWith('/') ? s : '/$s'}';
    }).toList();
  }

  Future<List<ComicItem>> _parseList(String html) async {
    final base = await SourceHttp.pickHost('doubao', _fallbackHosts);
    return _itemRe.allMatches(html).map((m) {
      final cover = m.group(3)!;
      return ComicItem(m.group(1)!, _unescape(m.group(2)!),
          cover.startsWith('http') ? cover : '$base$cover');
    }).toList();
  }

  static String _unescape(String s) =>
      s.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'");

  static String _first(RegExp re, String s) {
    final m = re.firstMatch(s);
    return m == null ? '' : _unescape(m.group(1) ?? '');
  }

  /// 豆包的加密 payload 用了 URL/文件安全型 base64（-/_），这里只接受字母数字+/= 和 -_。
  static Uint8List? _b64UrlDecode(String s) {
    try {
      var str = s.replaceAll('-', '+').replaceAll('_', '/');
      final mod = str.length % 4;
      if (mod != 0) str = str.padRight(str.length + (4 - mod), '=');
      return Uint8List.fromList(base64.decode(str));
    } catch (_) {
      return null;
    }
  }
}