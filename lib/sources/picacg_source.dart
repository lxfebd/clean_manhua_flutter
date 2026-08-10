import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'source_http.dart';

/// 哔咔漫画源（picaapi.picacomic.com）。
/// 协议参考 basonwoo/pica_crawler + AnkiKong 的 API 文档。
/// 签名：HMAC-SHA256(_secretKey, lower(path+time+nonce+method+apiKey))。
/// nonce 为固定值，app-version=2.2.1.2.3.3, build-version=45。
/// ⚠️ 国内直连需走 CF 优选 IP 分流（--resolve 或 Host 头），否则 SSL 握手失败。
class PicacgSource extends ComicSource {
  static const String _api = 'https://picaapi.picacomic.com';
  static const List<String> _fallbackHosts = [_api];
  static const String _apiKey = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
  // 签名算法：HMAC-SHA256，secret key 带 <> 特殊字符（来源 basonwoo/pica_crawler）。
  // 注意：早期 PicaComic 开源项目使用裸 MD5，但那是错误实现；真实协议为 HMAC-SHA256 + 固定 nonce。
  // 实测裸 MD5 返回空 success（被服务端静默封），HMAC-SHA256 返回 400 "invalid email or password"（签名通过但凭据不对）。
  static const String _secretKey =
      r"~d}$Q7$eIni=V)9\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn";

  /// 登录 token（首次需调用 login 获取，成功后持久化到本地）。
  static String token = '';

  /// token 本地持久化文件路径（应用文档目录）。
  static File? _tokenFile;

  PicacgSource() {
    // 注册 Cloudflare 优选 IP：官方 DNS 常解析到不可达 IP，用优选 IP 加速直连。
    Net.preferredHostIps[_api.replaceAll('https://', '').replaceAll('http://', '')] = [
      '172.67.73.79',
      '104.21.80.1',
    ];
  }

  /// 绑定 token 持久化文件（在应用启动时调用）；传 null 则仅从已有文件重载。
  static void bindTokenFile(File? file) {
    if (file != null) _tokenFile = file;
    final f = _tokenFile;
    if (f != null && f.existsSync()) {
      final t = f.readAsStringSync().trim();
      if (t.isNotEmpty) token = t;
    }
  }

  /// 保存 token 到本地文件。
  static void saveToken(String t) {
    token = t;
    try {
      _tokenFile?.writeAsStringSync(t);
    } catch (_) {}
  }

  /// 是否已登录。
  static bool get isLoggedIn => token.isNotEmpty;

  /// 登出，清空 token。
  static void logout() {
    token = '';
    try {
      _tokenFile?.deleteSync();
    } catch (_) {}
  }

  @override
  String get id => 'picacg';
  @override
  String get name => '哔咔漫画';

  /// 登录，成功后保存 token 供后续请求使用。
  Future<String> login(String email, String password) async {
    // (1) Token 换取密码
    final md5Pass = md5.convert(utf8.encode(password)).toString();
    final payload = jsonEncode({'email': email, 'password': md5Pass});
    final headers = _buildHeaders('post', jsonEncode(payload), '/auth/sign-in');
    final text = await SourceHttp.post('picacg', '/auth/sign-in',
        fallbackHosts: _fallbackHosts, headers: headers, body: payload);
    final json = jsonDecode(text) as Map<String, dynamic>;
    final code = json['code'];
    if (code == null || code != 200) {
      final msg = json['message']?.toString() ?? json['error']?.toString() ?? '';
      throw Exception('哔咔登录失败 (code=$code)：$msg');
    }
    final data = json['data'];
    if (data is! Map || data['token'] is! String) {
      final msg = json['message']?.toString() ?? '';
      throw Exception('哔咔返回无 token：$msg\n'
          '可能是：账号未激活 / 邮箱/密码错误 / 服务端临时封禁。');
    }
    final t = data['token'] as String;
    if (t.isEmpty) {
      final msg = json['message']?.toString() ?? '';
      throw Exception('哔咔 token 为空：$msg\n'
          '常见原因：账号注册后未在邮箱中点击激活链接。');
    }
    saveToken(t);
    return t;
  }

  /// 注册哔咔账号。成功后返回提示信息（通常仍需去邮箱激活）。
  /// 注册字段参考哔咔官方 API：email / password / question / birth / gender / name。
  Future<String> register({
    required String email,
    required String password,
    required String name,
    required String question,
    required String answer,
    required int gender,
    required String birth, // 形如 2000-01-01
  }) async {
    final body = jsonEncode({
      'email': email,
      'password': password,
      'name': name,
      'question': question,
      'answer': answer,
      'gender': gender, // 0 保密 1 男 2 女
      'birth': birth,
    });
    final headers = _buildHeaders('post', '', '/auth/register');
    final text = await SourceHttp.post('picacg', '/auth/register',
        fallbackHosts: _fallbackHosts, headers: headers, body: body);
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json['code'] != 200) {
      throw Exception('注册失败：${json['message'] ?? ''}');
    }
    return json['message']?.toString() ?? '注册成功，请前往邮箱激活';
  }

  @override
  Future<List<Category>> categories() async {
    final text = await _get('/categories');
    final root = jsonDecode(text) as Map;
    _checkAuth(root);
    final data = root['data'] as Map?;
    if (data == null) return const [];
    final list = data['categories'] as List? ?? const [];
    return list.map((c) {
      final m = c as Map;
      return Category(m['title'] as String, m['title'] as String);
    }).toList();
  }

  @override
  Future<List<ComicItem>> rank(int page) async =>
      _parseComics(await _get('/comics/leaderboard?tt=H24&page=$page'));

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final query = Uri.encodeQueryComponent(categoryId);
    return _parseComics(
        await _get('/comics?page=$page&c=$query&s=dd&t=%E6%9C%80%E6%96%B0'));
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final body = jsonEncode({'keyword': keyword, 'sort': 'dd'});
    final headers = _buildHeaders('post', '', '/comics/advanced-search?page=$page');
    final text = await SourceHttp.post(
        'picacg', '/comics/advanced-search?page=$page',
        fallbackHosts: _fallbackHosts, headers: headers, body: body);
    return _parseComics(text);
  }

  @override
  Future<ComicDetail> detail(String comicId) async {
    final text = await _get('/comics/$comicId');
    final comic = ((jsonDecode(text) as Map)['data'] as Map)['comic'] as Map;
    final title = comic['title'] as String? ?? '';
    final author = comic['author'] as String? ?? '';
    final cover = _thumb(comic['thumb'] as Map?);

    final epsText = await _get('/comics/$comicId/eps?page=1');
    final eps = ((jsonDecode(epsText) as Map)['data'] as Map)['eps'] as Map;
    final docs = eps['docs'] as List;
    final chapters = docs.map((e) {
      final m = e as Map;
      final order = m['order']?.toString() ?? '0';
      return Chapter(order, m['title'] as String? ?? '第$order话');
    }).toList();

    return ComicDetail(
      ComicItem(comicId, title, cover)..author = author,
      chapters.reversed.toList(),
      author: author,
    );
  }

  @override
  Future<List<String>> chapterPics(String chapterId) async {
    // chapterId 形如 "comicId/order"
    final parts = chapterId.split('/');
    final comicId = parts[0];
    final order = parts[1];
    final text = await _get('/comics/$comicId/order/$order/pages?page=1');
    final pages = ((jsonDecode(text) as Map)['data'] as Map)['pages'] as Map;
    final docs = pages['docs'] as List;
    return docs.map((e) {
      final media = (e as Map)['media'] as Map;
      return _thumb(media);
    }).toList();
  }

  List<ComicItem> _parseComics(String text) {
    final root = jsonDecode(text) as Map;
    _checkAuth(root);
    final data = root['data'] as Map?;
    // 未登录时接口返回 200 但无 data，提示用户去登录。
    if (data == null || data['comics'] is! Map) {
      if (token.isEmpty) {
        throw Exception('请先在「我的」页登录哔咔账号');
      }
      return const [];
    }
    final comics = data['comics'] as Map;
    final docs = comics['docs'] as List;
    return docs.map((e) {
      final m = e as Map;
      return ComicItem(
        m['_id'] as String,
        m['title'] as String? ?? '',
        _thumb(m['thumb'] as Map?),
      )..author = m['author'] as String? ?? '';
    }).toList();
  }

  /// 检测哔咔未授权/未登录响应，抛出清晰提示。
  static void _checkAuth(Map root) {
    final code = root['code'];
    if (code != null && code != 200) {
      throw Exception('哔咔返回错误(码 $code)：${root['message'] ?? ''}'
          '${code == 1005 || code == 1002 ? '\n请先在「我的」页登录哔咔账号' : ''}');
    }
  }

  String _thumb(Map? m) {
    if (m == null) return '';
    final fs = m['fileServer'] as String? ?? '';
    final path = m['path'] as String? ?? '';
    if (fs.isEmpty || path.isEmpty) return '';
    return '$fs/static/$path';
  }

  Future<String> _get(String path) async {
    final headers = _buildHeaders('get', '', path);
    return SourceHttp.get('picacg', path,
        fallbackHosts: _fallbackHosts, headers: headers);
  }

  /// 生成哔咔签名请求头。
  /// Pica 真实签名 = HMAC-SHA256(key=_secretKey, msg=lower(path+time+nonce+method+apiKey))。
  /// nonce 固定值（与 basonwoo/pica_crawler 对齐）。
  static Map<String, String> _buildHeaders(
      String method, String _, String path) {
    final time =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    // 固定 nonce — 多个开源项目均用此值
    const nonce = 'b1ab87b4800d4d4590a11701b8551afa';
    final sigData = (path + time + nonce + method + _apiKey).toLowerCase();
    final hmacSha256 = Hmac(sha256, utf8.encode(_secretKey));
    final sig = hmacSha256.convert(utf8.encode(sigData)).toString();
    return {
      'api-key': _apiKey,
      'accept': 'application/vnd.picacomic.com.v1+json',
      'app-channel': '2',
      'authorization': token,
      'time': time,
      'nonce': nonce,
      'app-version': '2.2.1.2.3.3',
      'app-uuid': 'defaultUuid',
      'image-quality': 'original',
      'app-platform': 'android',
      'app-build-version': '45',
      'Content-Type': 'application/json; charset=UTF-8',
      'user-agent': 'okhttp/3.8.1',
      'signature': sig,
    };
  }
}
