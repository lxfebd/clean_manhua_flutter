import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'backup_cipher.dart';
import 'backup_restore.dart';
import 'bookshelf_store.dart';
import 'http_client.dart';
import 'local_store.dart';
import 'net_conn.dart';
import 'novel_shelf_store.dart';
import '../utils/compression_guard.dart';


/// WebDAV 请求失败：非 2xx 状态码。
/// 同步被**有意阻断**（P1-05）。
///
/// 与 [WebDavException]（服务端返回错误）区分开：这个代表"我们主动不发请求"，
/// 最常见的原因是重启后内存里没有真实口令。UI 应据此提示用户重新输入，
/// 而不是显示成网络错误。
class WebDavBlocked implements Exception {
  WebDavBlocked(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class WebDavException implements Exception {
  final int statusCode;
  final String body;
  WebDavException(this.statusCode, this.body);
  @override
  // P2-19：响应体默认不进 message。WebDAV 服务器的错误页可能回显请求头
  // （含 Authorization）、完整 URL（含口令查询参数）甚至目录结构；而这条
  // message 最终会写进错误日志、被用户打包反馈。只保留状态码 + 脱敏后的
  // 长度信息，够定位「是 401 还是 507」而不泄露内容。
  String toString() {
    final b = body.trim();
    final hint = b.isEmpty ? '' : '：响应体 ${b.length} 字节（内容不外传）';
    return 'HTTP $statusCode$hint';
  }
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
  /// v1 = 旧裸 SHA-256 派生密钥；v2 = PBKDF2-HMAC-SHA256 迭代派生。
  static const String magic = 'XMX-SYNC-1:';
  static const String magicV2 = 'XMX-SYNC-2:';

  /// 同步配置。
  ///
  /// ## P1-05：认证口令与加密口令**分开**
  /// 旧实现只有一个 `password`，同时用于 Basic 认证和备份加密。问题有三：
  /// 1. WebDAV 服务端本身知道这个口令 → 用它加密防不住服务端运营者；
  /// 2. 重启后真实口令不落盘（只存 "saved" 标记），内存里恒为空 →
  ///    要么认证失败，要么用**空口令**派生密钥去解密，无论如何都不对；
  /// 3. `hasPassword` 因为磁盘标记仍返回 true，界面显示"已设置"——骗人。
  ///
  /// 现在拆成：
  /// - [authPassword]：只用于 Basic 认证。
  /// - [encPassword]：只用于备份加解密。可以为空（不加密），
  ///   但**一旦开启加密就必须非空**，空口令一律禁止加密。
  ///
  /// 两者都只存在内存；重启后为空，此时同步进入 [syncBlocked] 状态，
  /// 绝不发送空 Basic 密码、也不用空口令生成备份。
  static ({
    String url,
    String username,
    String authPassword,
    String encPassword,
    String dir,
    bool encrypt,
  })? _config;

  /// 磁盘上是否已设置**认证**口令（仅标记，不存真值）。
  static bool _diskHasPassword = false;

  /// 磁盘上是否已设置**加密**口令（仅标记，不存真值）。
  static bool _diskHasEncPassword = false;

  /// 供 UI 读取当前配置。
  ///
  /// ⚠️ 口令字段返回空字符串，UI 只能通过 [hasPassword] / [hasEncPassword]
  /// 知道"是否设置过"——绝不能把假值当真实口令回填到输入框或用于请求。
  static Map<String, dynamic>? get config => _config == null
      ? null
      : {
          'url': _config!.url,
          'username': _config!.username,
          'password': '',
          'hasPassword': hasPassword,
          'hasEncPassword': hasEncPassword,
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

  /// 远端目录 URL（末尾必带 '/'）。供 probe 判定「目录是否可达」使用，
  /// 与 [_fileUri] 走同一套目录归一化逻辑，但拼接的是目录本身而非目录 + 文件名。
  static Uri get _dirUri {
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
    return Uri.parse('$u$d');
  }

  /// 测试专用：清空内存配置与磁盘标记缓存，重置为未配置状态。
  @visibleForTesting
  static void resetForTest() {
    _config = null;
    _diskHasPassword = false;
  }

  /// 从 LocalStore 恢复同步配置（应用启动时调用）。
  ///
  /// **口令一律不恢复**（磁盘上只有 "saved" 标记，没有真值可恢复）。
  /// 恢复后 [_config] 的口令字段为空，[syncBlocked] 会返回 true，
  /// 同步被明确阻断直到用户重新输入——绝不用空口令去认证或加密。
  static Future<void> restore() async {
    try {
      final j = await LocalStore.readJson('webdav_config');
      _diskHasPassword = false;
      _diskHasEncPassword = false;
      if (j is Map) {
        _config = (
          url: (j['url'] as String?) ?? '',
          username: (j['username'] as String?) ?? '',
          // 口令不回填：磁盘上本来就没有真值。
          authPassword: '',
          encPassword: '',
          dir: (j['dir'] as String?) ?? '',
          encrypt: (j['encrypt'] as bool?) ?? false,
        );
        _diskHasPassword = (j['password'] as String?)?.trim().isNotEmpty == true;
        _diskHasEncPassword =
            (j['encPassword'] as String?)?.trim().isNotEmpty == true;
      }
    } catch (_) {
      // 恢复失败按未配置处理
    }
  }

  /// 保存配置。真口令不落盘，只存 "saved" 标记。
  ///
  /// [password] 留空表示「沿用已存认证口令」；
  /// [encPassword] 留空表示「沿用已存加密口令」或「不加密」。
  ///
  /// P1-05：`encrypt=true` 但最终没有有效加密口令时，**拒绝开启加密**
  /// 并返回 false（空口令加密等于没有加密）。
  static Future<bool> saveConfig({
    required String url,
    required String username,
    required String password,
    required String dir,
    required bool encrypt,
    String? encPassword,
  }) async {
    var hadDiskPass = false;
    var hadDiskEncPass = false;
    try {
      final j = await LocalStore.readJson('webdav_config');
      hadDiskPass = j is Map &&
          ((j['password'] as String?)?.trim().isNotEmpty == true);
      hadDiskEncPass = j is Map &&
          ((j['encPassword'] as String?)?.trim().isNotEmpty == true);
    } catch (_) {}

    final nextAuth = password.isNotEmpty
        ? password
        : (_config?.authPassword.isNotEmpty == true
            ? _config!.authPassword
            : '');
    final nextEnc = (encPassword != null && encPassword.isNotEmpty)
        ? encPassword
        : (_config?.encPassword.isNotEmpty == true
            ? _config!.encPassword
            : '');

    // 空口令禁止加密（P1-05）：否则「加密」只是个魔数前缀，任何拿到文件的人
    // 都能用空串解出内容。
    if (encrypt && nextEnc.isEmpty) return false;

    _config = (
      url: url,
      username: username,
      authPassword: nextAuth,
      encPassword: nextEnc,
      dir: dir,
      encrypt: encrypt,
    );
    if (nextAuth.isNotEmpty) hadDiskPass = true;
    if (nextEnc.isNotEmpty) hadDiskEncPass = true;
    _diskHasPassword = hadDiskPass;
    _diskHasEncPassword = hadDiskEncPass;
    await LocalStore.writeJson('webdav_config', {
      'url': url,
      'username': username,
      'password': hadDiskPass ? 'saved' : '', // 仅标记
      'encPassword': hadDiskEncPass ? 'saved' : '', // 仅标记
      'dir': dir,
      'encrypt': encrypt,
    });
    return true;
  }

  static bool get hasConfig => _config != null && _config!.url.trim().isNotEmpty;

  /// 用户是否**曾经**设置过 WebDAV 认证口令（磁盘标记）。
  ///
  /// ⚠️ 这不代表当前内存里有可用口令——重启后为 true 但 [_config] 里是空串。
  /// 判断"现在能不能同步"必须用 [syncBlocked]。
  static bool get hasPassword =>
      _diskHasPassword || (_config?.authPassword.isNotEmpty ?? false);

  /// 用户是否设置过备份加密口令（磁盘标记）。语义同 [hasPassword]。
  static bool get hasEncPassword =>
      _diskHasEncPassword || (_config?.encPassword.isNotEmpty ?? false);

  /// 当前同步是否被**阻断**（P1-05 的核心语义）。
  ///
  /// 返回中文原因，null 表示可同步。阻断条件：
  /// - 配置了用户名但内存里没有真实认证口令（重启后必然如此）
  /// - 开启了加密但内存里没有真实加密口令
  ///
  /// 用途：push/pull/probe 入口统一检查，UI 也用它显示"需要重新输入口令"，
  /// 而不是在 `hasPassword==true` 时让用户以为一切正常。
  static String? get syncBlocked {
    final c = _config;
    if (c == null) return '未配置 WebDAV 服务器';
    if (c.url.trim().isEmpty) return '未配置 WebDAV 服务器';
    // P1-27：WebDAV 必须走 HTTPS。
    //
    // HTTP WebDAV 会把 Basic 认证头（用户名+口令的 base64，等于明文）和
    // 全部阅读数据一起暴露在同一条链路上——这是比"内容站被篡改"严重得多
    // 的问题，因为泄漏的是用户凭据。旧实现允许 http:// 且 Android 全局
    // 放开明文，等于默认处于这种状态。
    final schemeError = _checkHttpsOnly(c.url);
    if (schemeError != null) return schemeError;
    if (c.username.trim().isNotEmpty && c.authPassword.isEmpty) {
      return '需要重新输入 WebDAV 口令（口令不会落盘，重启后须重输）';
    }
    if (c.encrypt && c.encPassword.isEmpty) {
      return '需要重新输入备份加密口令（已开启加密但当前无有效口令）';
    }
    return null;
  }

  /// 测试专用：允许 HTTP 回环地址（`127.0.0.1` / `localhost`）。
  ///
  /// ## 为什么需要
  /// 集成测试用 `HttpServer` 起本地 WebDAV 服务器验证 push/pull 语义，
  /// 那个服务器是纯 HTTP。P1-27 强制 HTTPS 后会正确拦下它们——但那是
  /// 测试基础设施，不是真实风险（流量不出本机）。
  ///
  /// ## 为什么不是"测试里关掉检查"
  /// 关掉检查等于测试跑的是**未经校验的路径**，通过也不代表生产安全。
  /// 这里只放行回环地址，公网 HTTP 仍然被拒。
  @visibleForTesting
  static bool allowHttpLoopbackForTest = false;

  /// 校验 WebDAV 地址必须是 https://。返回中文原因（null = 通过）。
  ///
  /// ## 为什么不给 NAS 开 HTTP 例外
  /// 局域网内网也算：同一 Wi-Fi 下的其他人、被入侵的路由器、ARP 欺骗都能
  /// 读到 Basic 认证头。自签证书场景已经有 [SelfSignedTrust] 的
  /// 「主机 + 指纹」通道可用——那才是正确的解法，不是退回 HTTP。
  static String? _checkHttpsOnly(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null) return '服务器地址格式不正确';
    if (u.scheme == 'https') return null;
    if (u.scheme == 'http') {
      // 测试豁免：仅回环地址，且必须显式开启。
      if (allowHttpLoopbackForTest && _isLoopbackHost(u.host)) return null;
      return 'WebDAV 必须使用 https://（http 会明文发送账号口令）。'
          '若你的服务器是自签证书，请在设置里登记该主机与证书指纹。';
    }
    return '服务器地址必须以 https:// 开头';
  }

  static bool _isLoopbackHost(String host) {
    final h = host.trim().toLowerCase();
    return h == '127.0.0.1' || h == 'localhost' || h == '::1';
  }

  static String? get _username => _config?.username.trim().isNotEmpty == true ? _config!.username.trim() : null;

  /// 认证头（Basic）。
  ///
  /// P1-05：**没有真实认证口令时直接抛错**，绝不发送
  /// `Authorization: Basic base64("user:")` 这种空口令头——旧实现在重启后
  /// 就是这样发的，服务端要么 401（用户看不懂）要么被当成匿名/空密码账号。
  static Map<String, String> _authHeaders() {
    final h = <String, String>{};
    final u = _username;
    if (u != null) {
      final pass = _config?.authPassword ?? '';
      if (pass.isEmpty) {
        throw WebDavBlocked('需要重新输入 WebDAV 口令（口令不会落盘，重启后须重输）');
      }
      final cred = base64Encode(utf8.encode('$u:$pass'));
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

  /// 复用统一连接策略：全局代理 / 信任自签证书（家庭 NAS 常见自签）。
  static HttpClient _client() {
    return Net.clientForRequest(Uri.parse(_config!.url).host);
  }

  static Future<String> _readBody(HttpClientResponse res) async {
    // P2-30/P1-10：旧的 `res.fold` 先把整个响应体无上限堆进内存，再 gzip
    // 一步展开——两层都没有闸门。现在：输入侧有字节上限，解压侧走带闸门的
    // 流式解码（超限抛 DecompressionBombException）。
    final bytes = await NetConn.readLimited(
        res, kMaxWebDavResponseBytes, const Duration(seconds: 30));
    final enc = res.headers.value('Content-Encoding') ?? '';
    if (enc.contains('gzip')) {
      final decoded = await gzipDecodeGuarded(
          bytes, maxBytes: kMaxDecodedBytesSmall);
      return utf8.decode(decoded, allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// WebDAV 响应体上限：备份内容是用户自己产生的 json/txt，正常远小于此。
  static const int kMaxWebDavResponseBytes = 64 * 1024 * 1024;

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

  /// PROPFIND 指定路径（默认目标文件）。404 → null；其他 4xx/5xx → 抛
  /// [WebDavException]。probe 用来对目录再发一次 PROPFIND 判定「目录是否存在」。
  static Future<({DateTime mtime, int size})?> _propfindUri(Uri uri) async {
    final client = _client();
    try {
      final res = await _send(client, 'PROPFIND', uri,
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

  /// 上传当前本地备份（PUT → 临时文件 → MOVE 原子替换）。
  /// 返回远端 mtime 供 UI 展示。
  ///
  /// ⚠️ 原子性：直接 PUT 到目标文件时，传输中断会在远端留下**半截备份**，
  /// 另一台设备 pull 到的是截断的 JSON（解密/解析失败，数据看起来"丢了"）。
  /// 先 PUT 到临时文件，完成后再用 WebDAV MOVE（Overwrite: T）覆盖正式文件
  /// ——MOVE 在服务端是重命名，不会出现半截文件。
  static Future<DateTime> push() async {
    if (!hasConfig) throw Exception('未配置 WebDAV 服务器');
    // P1-05：统一阻断检查。重启后没有真实口令时必须明确 blocked，
    // 不能悄悄用空口令发请求或生成空口令备份。
    final blocked = syncBlocked;
    if (blocked != null) throw WebDavBlocked(blocked);
    final data = await LocalStore.collectBackup(
      bookshelfData: BookshelfStore.exportData(),
      novelShelfData: NovelShelfStore.exportData(),
    );
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final payload = _config!.encrypt ? _encrypt(json) : json;
    await _ensureDir();
    final client = _client();
    try {
      final tmpUri = Uri.parse('${_fileUri.toString()}.tmp');
      final res = await _send(client, 'PUT', tmpUri,
          headers: _authHeaders(), body: payload);
      await res.drain<void>().timeout(const Duration(seconds: 20));
      // 临时文件上传完成 → MOVE 覆盖正式文件（Overwrite: T 允许替换）。
      final mv = await _send(client, 'MOVE', tmpUri, headers: {
        ..._authHeaders(),
        'Destination': _fileUri.toString(),
        'Overwrite': 'T',
      });
      await mv.drain<void>().timeout(const Duration(seconds: 20));
      final now = DateTime.now().toUtc();
      // 记住本次上传的本地快照时间，避免 pull 时误判本地更旧
      await LocalStore.writeJson('webdav_last_upload', now.millisecondsSinceEpoch);
      return now;
    } finally {
      client.close(force: true);
    }
  }

  /// 连通性探测：用给定凭据校验「URL 可达 + 账号密码有效 + 目录可达」。
  /// 不修改 _config，供「保存前校验」与设置页连通性测试复用。
  ///
  /// 语义（首次接入场景友好）：
  /// - 对用户填的目录（空 = 服务器根）发一次 PROPFIND；
  ///   2xx + body 含 lastModified → 目录可达；
  ///   404 / 空 body → 目录不可达，抛「保存目录不可达」异常提示换目录；
  ///   401/403 → 账号/密码无效，_send 原样抛给 UI；
  /// - 目标文件是否存在**不再**作为探测判定（旧实现把文件 404 视为失败，
  ///   导致用户首次接入——远端还没有同步文件——永远卡在"连接失败"、
  ///   保存配置永不执行，即本次修复的 P0 缺陷）；
  /// - 目录可达但目标文件不存在时，实际上传由 _ensureDir 自动 MKCOL；
  /// - 网络/超时/URL 不可达等 → 由 _send 抛出的底层异常向上传播。
  static Future<void> probe({
    required String url,
    required String username,
    required String password,
    required String dir,
  }) async {
    final base = url.trim();
    if (base.isEmpty) throw Exception('服务器地址不能为空');
    // P1-27：出网前就拦住 HTTP（否则探针本身会把口令明文发出去）。
    final schemeError = _checkHttpsOnly(base);
    if (schemeError != null) throw WebDavBlocked(schemeError);
    // 探针请求与真实同步走同一套 URL 拼接（目录 + 目标文件名）。
    final saved = _config;
    try {
      _config = (
        url: base,
        username: username.trim(),
        authPassword: password,
        encPassword: _config?.encPassword ?? '',
        dir: dir.trim(),
        encrypt: saved?.encrypt ?? true,
      );
      // 目录 PROPFIND：凭据 + URL + 目录存在性判定，最关键的一步。
      // 目录 = 服务器根（用户未填 dir）时，PROPFIND base URL 本身——
      // 服务器只要可访问就返回 2xx（多数服务器返回 207），凭据无效则 401/403
      // 由 _send 原样抛出。目标文件是否存在对首次接入无关：不存在时
      // _ensureDir 上传阶段会自动 MKCOL。
      final dirInfo = await _propfindUri(_dirUri);
      if (dirInfo == null) {
        // 目录 404：首次接入常见（用户填了新子目录但服务器还没有），
        // 直接 MKCOL 创建后再验一次，避免「保存目录不可达」的假阴性。
        // 创建失败（无权限/凭据只读）→ 再 PROPFIND 仍 null，落到下面的
        // 真实不可达错误。空 dir（服务器根）在 _ensureDir 内部短路。
        try {
          await _ensureDir();
        } catch (_) {
          // 忽略：下面的复查 PROPFIND 才是最终判据
        }
        final retry = await _propfindUri(_dirUri);
        if (retry == null) {
          throw Exception(
              '远端保存目录不可达（目录不存在且无法创建），请检查服务器地址、账号权限与保存目录');
        }
      }
      // 目录可达 → 凭据 + URL + 目录均 OK，probe 成功。
      return;
    } finally {
      _config = saved;
    }
  }

  /// 拉取远端备份并恢复到本地。返回是否成功。
  /// 拉取远端备份并恢复到本地。
  ///
  /// 返回是否成功。**失败时抛异常，且保证本地数据未被改动**（P1-06）。
  ///
  /// 流程刻意分成「先全部校验 → 再一次提交」：
  /// 1. 读响应体（带大小上限，防超大文件打爆内存）
  /// 2. 解密（加密模式下拒绝明文降级）
  /// 3. JSON 解析 + schema 校验
  /// 4. 交给 [BackupRestore.apply]，它内部做两阶段提交（失败回滚）
  static Future<bool> pull() async {
    // P1-05：与 push 同样的阻断检查。
    final blocked = syncBlocked;
    if (blocked != null) throw WebDavBlocked(blocked);
    final client = _client();
    try {
      final res = await _send(client, 'GET', _fileUri, headers: _authHeaders());
      final body = await _readBody(res);

      // P1-06：大小上限。正常备份是几十 KB 到几 MB，64MB 已经极端宽松；
      // 超过上限说明要么文件被替换，要么远端异常，直接拒绝而不是尝试解析。
      const maxBackupBytes = 64 * 1024 * 1024;
      if (body.length > maxBackupBytes) {
        throw WebDavException(0,
            '远端备份过大（$body.length 字节 > $maxBackupBytes），已拒绝导入');
      }

      final json = _decode(body);
      if (json.length > maxBackupBytes) {
        throw WebDavException(0, '解密后内容过大，已拒绝导入');
      }

      final data = jsonDecode(json);
      if (data is! Map<String, dynamic>) {
        throw WebDavException(0, '远端文件不是有效的同步数据（顶层不是对象）');
      }
      // schema 校验：必须有 version，且已知字段类型要对。
      if (data['version'] == null) {
        throw WebDavException(0, '远端文件不是有效的同步数据（缺少 version 字段）');
      }
      _validateBackupSchema(data);

      // 全部校验通过才动本地数据。BackupRestore.apply 内部事务化：
      // 写失败会回滚并抛 BackupRestoreException，不会留下新旧混合状态。
      await BackupRestore.apply(data);
      return true;
    } on WebDavException catch (e) {
      if (e.statusCode == 404) throw Exception('远端还没有同步文件，请先点「上传同步」');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 备份 schema 校验（P1-06）：缺字段/类型错一律拒绝，不"尽力恢复"。
  ///
  /// 为什么严格：能写 WebDAV 文件的人可以构造任意 JSON。如果对坏数据做
  /// 宽容处理（比如把 `settings` 是字符串忽略掉），结果是**部分恢复**——
  /// 用户看到书架回来了但设置没回来，比直接失败更难排查。
  static void _validateBackupSchema(Map<String, dynamic> data) {
    const mapKeys = {
      'favorites',
      'history',
      'bookmarks',
      'video_records',
      'video_progress',
      'settings',
      'novel_read_settings',
      'reading_stats',
      'gesture_config',
      'sources_config',
      'source_plugins',
      'source_health',
      'webdav_config',
      'update_check',
      'bookshelf',
      'novel_shelf',
    };
    // 注意：downloads / search_history / custom_sources / shelf_folders
    // 在 collectBackup 里是**列表**不是对象。把它们放进 mapKeys 会让
    // 每一份正常备份都被判成"类型错误"——这正是首版校验写错的地方。
    const listKeys = {
      'search_history',
      'downloads',
      'custom_sources',
      'shelf_folders',
    };

    for (final k in mapKeys) {
      final v = data[k];
      if (v != null && v is! Map) {
        throw WebDavException(0, '备份字段「$k」类型错误（应为对象，实际为 ${v.runtimeType}）');
      }
    }
    for (final k in listKeys) {
      final v = data[k];
      if (v != null && v is! List) {
        throw WebDavException(0, '备份字段「$k」类型错误（应为列表，实际为 ${v.runtimeType}）');
      }
    }
  }

  /// 解密或识别明文（委托 [BackupCipher]，明文穿透）。
  /// 解密远端备份（P1-06：**不再接受明文降级**）。
  ///
  /// ## 旧行为的问题
  /// 旧实现对没有魔数的内容直接当明文返回。这意味着**任何能写 WebDAV 文件
  /// 的人**（服务端运营者、共享账号的其他人、中间人）只要放一份明文 JSON，
  /// 就能完全绕过 GCM 认证，污染用户的阅读数据/设置/自定义源——
  /// 自定义源尤其危险，改掉 baseUrl 就能引导 App 去访问攻击者的服务器。
  ///
  /// 现在：开启加密时只接受当前加密格式。明文一律拒绝并明确报错，
  /// 由用户显式关闭加密开关（那代表用户自己知情地选择了不加密）。
  static String _decode(String body) {
    final cfg = _config;
    // 未配置时不该走到这里（push/pull 都有前置检查），但测试会直接调
    // testDecrypt；给出明确错误而不是 null 崩溃。
    if (cfg == null) {
      if (!BackupCipher.isEncrypted(body)) return body;
      throw WebDavBlocked('未配置 WebDAV，无法解密');
    }
    final pass = cfg.encPassword;
    if (cfg.encrypt) {
      if (!BackupCipher.isEncrypted(body)) {
        throw WebDavException(
            0,
            '远端文件未加密，但本机开启了加密同步。已拒绝导入'
            '（可能是他人替换的文件）。若确实要导入明文备份，请先关闭加密开关再试。');
      }
      if (pass.isEmpty) {
        throw WebDavBlocked('备份加密口令为空，无法解密（口令不会落盘，请重新输入）');
      }
      return BackupCipher.decrypt(body, pass);
    }
    // 未开启加密：接受明文；但已加密的文件仍要尝试解（用户可能中途关了开关）。
    if (!BackupCipher.isEncrypted(body)) return body;
    if (pass.isEmpty) {
      throw WebDavBlocked('远端是加密备份，但当前没有加密口令（请重新输入）');
    }
    return BackupCipher.decrypt(body, pass);
  }

  /// AES-256-GCM 加密（委托 [BackupCipher]，统一 v2 派生）。
  static String _encrypt(String json) {
    final pass = _config!.encPassword;
    // P1-05：空口令禁止加密。走到这里说明状态被绕过了，直接拒绝。
    if (pass.isEmpty) {
      throw WebDavBlocked('备份加密口令为空，拒绝生成备份（空口令加密等于没有加密）');
    }
    // P1-05：新写出一律走 v3（随机盐），不再用固定盐的 v2。
    return BackupCipher.encryptV3(json, pass);
  }

  /// 测试用：仅加解密（无网络），验证往返一致与防篡改。
  @visibleForTesting
  static String testEncrypt(String json) => _encrypt(json);

  /// 测试用：仅加解密（无网络）。
  @visibleForTesting
  static String testDecrypt(String body) => _decode(body);

  static Future<int> _localUploadTime() async =>
      (await LocalStore.readJson('webdav_last_upload') as num?)?.toInt() ?? 0;

  /// 上次成功上传（push）的 UTC 毫秒时间戳；0 = 从未同步。供设置页展示。
  static Future<int> lastSyncMillis() => _localUploadTime();

  /// 记录拉取时间（备用；目前仅供审计）。
  static Future<void> recordPull() async {
    await LocalStore.writeJson('webdav_last_pull', DateTime.now().toUtc().millisecondsSinceEpoch);
  }
}
