import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'bookshelf_store.dart';
import 'http_client.dart';
import 'local_store.dart';
import 'novel_shelf_store.dart';

/// WebDAV 请求失败：非 2xx 状态码。
class WebDavException implements Exception {
  final int statusCode;
  final String body;
  WebDavException(this.statusCode, this.body);
  @override
  String toString() => 'HTTP $statusCode${body.trim().isEmpty ? '' : '：${body.trim().length > 200 ? body.trim().substring(0, 200) : body.trim()}'}';
}

/// WebDAV 多端同步：把整份用户数据（收藏/历史/进度/设置/源配置）作为
/// 一个 JSON 备份文件存到用户的 WebDAV 网盘（坚果云 / Nextcloud / WebDAV Server
/// 等），实现多端手动同步。
///
/// 协议只用了 WebDAV 的最小子集：
/// - MKCOL  创建目录（不存在时）
/// - PROPFIND 查询远端文件的 lastModified/size，用于判断哪端更新
/// - GET    拉取远端文件
/// - PUT    上传本地文件
///
/// 文件格式：与「导出备份」相同的 JSON（version/createdAt/favorites/...），
/// 启用加密时外层包一层 AES-256-GCM（iv + ciphertext，密钥由用户口令派生），
/// 明文模式下就是备份 JSON 原文。
class WebDavSync {
  WebDavSync._();

  /// 远端目标文件名（放在用户配置的目录下）。
  static const String fileName = 'xingmanxia_sync.json';

  /// 加密文件魔数（明文 JSON 不会以它开头，用于识别是否已加密）。
  static const String magic = 'XMX-SYNC-1:';

  /// 同步配置。明文密码仅保存在内存，持久化只存 bool 的 hasPassword。
  static ({String url, String username, String password, String dir, bool encrypt})? _config;

  /// 供 UI 读取当前配置（密码字段持久化为 hasPassword 占位）。
  static Map<String, dynamic>? get config => _config == null
      ? null
      : {
          'url': _config!.url,
          'username': _config!.username,
          'password': _config!.password,
          'dir': _config!.dir,
          'encrypt': _config!.encrypt,
        };

  static String get _dir => _config?.dir ?? '';

  /// 完整远端文件 URL（目录 + 文件名）。
  static Uri get _fileUri {
    final dir = _dir;
    var u = _config!.url.trim();
    if (!u.endsWith('/')) u += '/';
    var d = dir.trim();
    while (d.startsWith('/')) {
      d = d.substring(1);
    }
    while (d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    if (d.isNotEmpty) d += '/';
    return Uri.parse('$u$d$fileName');
  }

  /// 从 LocalStore 恢复同步配置（应用启动时调用，密码只恢复 hasPassword 标记）。
  static Future<void> restore() async {
    try {
      final j = await LocalStore.readJson('webdav_config');
      if (j is Map) {
        _config = (
          url: (j['url'] as String?) ?? '',
          username: (j['username'] as String?) ?? '',
          password: (j['password'] as String?) ?? '',
          dir: (j['dir'] as String?) ?? '',
          encrypt: (j['encrypt'] as bool?) ?? false,
        );
      }
    } catch (_) {
      // 恢复失败按未配置处理
    }
  }

  /// 保存配置到 LocalStore。明文密码不落盘。
  static Future<void> saveConfig({
    required String url,
    required String username,
    required String password,
    required String dir,
    required bool encrypt,
  }) async {
    _config = (url: url, username: username, password: password, dir: dir, encrypt: encrypt);
    await LocalStore.writeJson('webdav_config', {
      'url': url,
      'username': username,
      'password': password.isEmpty ? '' : 'saved', // 仅标记：非空表示已设置密码
      'dir': dir,
      'encrypt': encrypt,
    });
  }

  static bool get hasConfig => _config != null && _config!.url.trim().isNotEmpty;

  static String? get _username => _config?.username.trim().isNotEmpty == true ? _config!.username.trim() : null;

  /// 认证头（Basic）。无用户名时可能用匿名 WebDAV。
  static Map<String, String> _authHeaders() {
    final h = <String, String>{};
    final u = _username;
    if (u != null) {
      final cred = base64Encode(utf8.encode('$u:${_config!.password}'));
      h['Authorization'] = 'Basic $cred';
    }
    return h;
  }

  /// 在 _config 上执行一次 WebDAV 请求，返回原始响应（供 GET/PROPFIND 读取 body）。
  /// 非 2xx 抛 [WebDavException]（带状态码与响应体）。
  static Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    Uri uri,
    {String? body,
    Map<String, String>? headers,
    Duration? timeout}) async {
    final req = await client.openUrl(method, uri);
    req.headers.set('User-Agent', Net.defaultUA);
    req.headers.set('Accept', '*/*');
    headers?.forEach((k, v) => req.headers.set(k, v));
    if (body != null) {
      req.headers.set('Content-Type', 'application/octet-stream');
      req.add(utf8.encode(body));
    }
    final res = await req.close().timeout(timeout ?? const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final err = await _readBody(res);
      throw WebDavException(res.statusCode, err);
    }
    return res;
  }

  /// 使用与 [Net._client] 一致的连接策略：全局代理启用时走代理，
  /// 否则直连（WebDAV 通常是自己的服务器，不套优选 IP 逻辑）。
  static HttpClient _client() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = false
      ..badCertificateCallback = (cert, h, port) => true; // 自签证书（常见于家庭 NAS）
    if (Net.proxyEnabled) {
      c.findProxy = (url) => Net.proxyDirective!;
    }
    return c;
  }

  static Future<String> _readBody(HttpClientResponse res) async {
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 30));
    final enc = res.headers.value('Content-Encoding') ?? '';
    if (enc.contains('gzip')) {
      return utf8.decode(gzip.decode(bytes), allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 确保远端目录存在（MKCOL；405/409 表示已存在，视为成功）。
  static Future<void> _ensureDir() async {
    final dir = _dir.trim().replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (dir.isEmpty) return; // 根目录无需创建
    // 逐级创建，兼容不存在中间目录的服务器
    final parts = dir.split('/');
    final base = _config!.url.trim();
    var cur = base.endsWith('/') ? base : '$base/';
    final client = _client();
    try {
      for (var i = 0; i < parts.length; i++) {
        cur += '${parts[i]}/';
        final uri = Uri.parse(cur);
        try {
          final res = await _send(client, 'MKCOL', uri, headers: _authHeaders());
          await res.drain<void>().timeout(const Duration(seconds: 15));
        } on WebDavException catch (e) {
          if (e.statusCode != 405 && e.statusCode != 409) rethrow;
          // 已存在 → 继续下一级
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  /// PROPFIND 远端文件信息。返回 (lastModified, size)；不存在（404）返回 null。
  static Future<({DateTime mtime, int size})?> _propfind() async {
    final client = _client();
    try {
      final res = await _send(client, 'PROPFIND', _fileUri,
          headers: {
            ..._authHeaders(),
            'Depth': '0',
            'Content-Type': 'application/xml',
          },
          body: '<?xml version="1.0"?><propfind xmlns="DAV:"><prop><getlastmodified/><getcontentlength/></prop></propfind>');
      final body = await _readBody(res);
      final m = RegExp(r'<D:getlastmodified>([^<]+)</D:getlastmodified>|<d:getlastmodified>([^<]+)</d:getlastmodified>', caseSensitive: false)
          .firstMatch(body);
      final s = RegExp(r'<D:getcontentlength>(\d+)</D:getcontentlength>|<d:getcontentlength>(\d+)</d:getcontentlength>', caseSensitive: false)
          .firstMatch(body);
      if (m == null && s == null) return null;
      DateTime? dt;
      final ms = m?.group(1) ?? m?.group(2);
      if (ms != null) {
        // WebDAV 时间格式：Tue, 01 Jan 2024 00:00:00 GMT
        dt = _parseHttpDate(ms);
      }
      return (mtime: dt ?? DateTime.fromMillisecondsSinceEpoch(0), size: int.tryParse(s?.group(1) ?? s?.group(2) ?? '') ?? 0);
    } on WebDavException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static DateTime? _parseHttpDate(String s) {
    try {
      return HttpDate.parse(s);
    } catch (_) {
      return null;
    }
  }

  /// 上传当前本地备份（PUT）。返回远端 mtime 供 UI 展示。
  static Future<DateTime> push() async {
    if (!hasConfig) throw Exception('未配置 WebDAV 服务器');
    final data = await LocalStore.collectBackup(
      bookshelfData: BookshelfStore.exportData(),
      novelShelfData: NovelShelfStore.exportData(),
    );
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final payload = _config!.encrypt ? _encrypt(json) : json;
    await _ensureDir();
    final client = _client();
    try {
      final res = await _send(client, 'PUT', _fileUri,
          headers: _authHeaders(), body: payload);
      await res.drain<void>().timeout(const Duration(seconds: 20));
      final now = DateTime.now().toUtc();
      // 记住本次上传的本地快照时间，避免 pull 时误判本地更旧
      await LocalStore.writeJson('webdav_last_upload', now.millisecondsSinceEpoch);
      return now;
    } finally {
      client.close(force: true);
    }
  }

  /// 拉取远端备份并恢复到本地。返回是否成功。
  static Future<bool> pull() async {
    if (!hasConfig) throw Exception('未配置 WebDAV 服务器');
    final client = _client();
    try {
      final res = await _send(client, 'GET', _fileUri, headers: _authHeaders());
      final body = await _readBody(res);
      final json = _decode(body);
      final data = jsonDecode(json);
      if (data is! Map<String, dynamic> || data['version'] == null) {
        throw Exception('远端文件不是有效的同步数据');
      }
      if (data['bookshelf'] is Map) {
        BookshelfStore.importData(data['bookshelf'] as Map<String, dynamic>);
      }
      if (data['novel_shelf'] is Map) {
        NovelShelfStore.importData(data['novel_shelf'] as Map<String, dynamic>);
      }
      await LocalStore.restoreBackup(data);
      return true;
    } on WebDavException catch (e) {
      if (e.statusCode == 404) throw Exception('远端还没有同步文件，请先点「上传同步」');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 解密或识别明文。
  static String _decode(String body) {
    if (!body.startsWith(magic)) return body; // 明文
    final lines = body.split('\n');
    if (lines.length < 3) throw Exception('加密文件格式损坏');
    final ivB64 = lines[1].trim();
    final ctB64 = lines.sublist(2).join('\n').trim();
    final iv = base64Decode(ivB64);
    final ct = base64Decode(ctB64);
    final key = _deriveKey(_config!.password);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final out = Uint8List(gcm.getOutputSize(ct.length));
    var off = gcm.processBytes(ct, 0, ct.length, out, 0);
    off += gcm.doFinal(out, off);
    return utf8.decode(Uint8List.sublistView(out, 0, off));
  }

  /// AES-256-GCM 加密（随机 IV，派生密钥；GCM 自带认证，篡改会抛异常）。
  static String _encrypt(String json) {
    final key = _deriveKey(_config!.password);
    final iv = Uint8List.fromList(List<int>.generate(12, (_) => Random.secure().nextInt(256)));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final pt = utf8.encode(json);
    final out = Uint8List(gcm.getOutputSize(pt.length));
    var off = gcm.processBytes(pt, 0, pt.length, out, 0);
    off += gcm.doFinal(out, off);
    // 只编码实际写入的字节：getOutputSize 按块对齐会含尾部零填充，
    // 全量编码会把零填充带进密文，解密的 MAC 校验失败。
    return '$magic\n${base64Encode(iv)}\n${base64Encode(Uint8List.sublistView(out, 0, off))}';
  }

  /// 口令 → 32 字节密钥（SHA-256 派生，简单够用）。
  static Uint8List _deriveKey(String password) {
    final digest = SHA256Digest();
    final input = utf8.encode(password);
    final out = Uint8List(32);
    var off = 0;
    digest.update(input, 0, input.length);
    off += digest.doFinal(out, off);
    return out;
  }

  /// 测试用：仅加解密（无网络），验证往返一致与防篡改。
  @visibleForTesting
  static String testEncrypt(String json) => _encrypt(json);

  /// 测试用：仅加解密（无网络）。
  @visibleForTesting
  static String testDecrypt(String body) => _decode(body);

  /// 判断哪端更新：'remote'（远端比本地最后上传新，建议先拉取）/
  /// 'same'（远端就是本地最后上传的内容）/ 'local'（远端还没有文件，建议上传）。
  static Future<String> diff() async {
    if (!hasConfig) throw Exception('未配置 WebDAV 服务器');
    final remote = await _propfind();
    if (remote == null) return 'local';
    final lastPush = await _localUploadTime();
    if (remote.mtime.millisecondsSinceEpoch > lastPush + 2000) {
      return 'remote';
    }
    return 'same';
  }

  static Future<int> _localUploadTime() async =>
      (await LocalStore.readJson('webdav_last_upload') as num?)?.toInt() ?? 0;

  /// 记录拉取时间（备用；目前仅供审计）。
  static Future<void> recordPull() async {
    await LocalStore.writeJson('webdav_last_pull', DateTime.now().toUtc().millisecondsSinceEpoch);
  }
}
