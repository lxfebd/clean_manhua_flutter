import 'dart:convert';
import 'dart:io';

import 'package:cronet_http/cronet_http.dart' as cronet;
import 'package:http/http.dart' as http;

/// 零第三方依赖 HTTP 客户端（基于 dart:io HttpClient）。
/// 注意：类名用 Net，避免与 dart:io 的 HttpClient 冲突。
class Net {
  static const Duration _timeout = Duration(seconds: 15);

  /// 单个候选 IP 的连接超时（用于优选 IP 轮询/自愈）。
  /// 比总超时更短，避免全部 IP 不可达时长时间挂起。
  static const Duration _ipTryTimeout = Duration(seconds: 6);

  static const String defaultUA =
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile';

  /// 需要强制走特定 IP 的域名 -> 候选 IP 列表（Cloudflare 优选 IP 加速）。
  /// 用于部分源官方 DNS 解析到不可达 IP（被墙/超时），而优选 IP 可连通。
  /// 通过 connectionFactory 强制直连候选 IP，同时保留 Host/SNI 走 HTTPS。
  static final Map<String, List<String>> preferredHostIps = {
    // TvTFun（Cloudflare CDN）：部分网络环境下系统 DNS 解析失败/被限，
    // 直连 Cloudflare 任一节点 IP + SNI 即可访问。
    'www.tvtfun.net': [
      '104.16.150.186',
      '104.16.151.210',
      '104.16.150.96',
      '104.16.151.161',
      '104.16.150.33',
      '104.16.151.88',
    ],
  };

  /// 当前域名已尝试到的候选 IP 下标，失败时轮询切换。
  static final Map<String, int> _ipIndex = {};

  /// 构造 HttpClient；若该 host 配置了优选 IP，则通过 connectionFactory 强制直连。
  /// 优选 IP 全部失败时，自动回退到系统 DNS 解析，避免整源因写死 IP 失效而挂死。
  static HttpClient _client(String host) {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..autoUncompress = false
      ..badCertificateCallback = (cert, h, port) => true; // 允许自签证书，兼容部分源
    final ips = preferredHostIps[host];
    if (ips != null && ips.isNotEmpty) {
      client.connectionFactory = (url, proxyHost, proxyPort) async {
        final port = url.hasPort
            ? url.port
            : (url.scheme == 'https' ? 443 : 80);
        // 依次尝试每个候选 IP
        for (int attempt = 0; attempt < ips.length; attempt++) {
          final idx = ((_ipIndex[host] ?? 0) + attempt) % ips.length;
          final ip = ips[idx];
          try {
            final socket =
                await Socket.connect(ip, port, timeout: _ipTryTimeout);
            final secure = await SecureSocket.secure(socket,
                host: url.host, onBadCertificate: (_) => true);
            return ConnectionTask.fromSocket<SecureSocket>(
                Future.value(secure), () {});
          } catch (_) {
            // 该 IP 不可用，尝试下一个
          }
        }
        // 全部优选 IP 失败 → 回退系统 DNS
        try {
          final addr = (await InternetAddress.lookup(url.host)).first;
          final socket =
              await Socket.connect(addr, port, timeout: _ipTryTimeout);
          final secure = await SecureSocket.secure(socket,
              host: url.host, onBadCertificate: (_) => true);
          return ConnectionTask.fromSocket<SecureSocket>(
              Future.value(secure), () {});
        } catch (_) {
          // 回退也失败，抛出由上层捕获
          rethrow;
        }
      };
    }
    return client;
  }

  /// GET 请求，返回响应体字符串（UTF-8）。
  static Future<String> get(String urlStr,
      {Map<String, String>? headers, Duration? timeout}) async {
    final t = timeout ?? _timeout;
    final client = _client(Uri.parse(urlStr).host);
    try {
      final req = await _request(client, 'GET', Uri.parse(urlStr), headers);
      final res = await req.close().timeout(t);
      final bytes = await _readBytes(res, t);
      _onDone(res, urlStr);
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }

  /// 基于 Cronet 的 GET 请求（Android 上使用 Chromium 网络栈，TLS/HTTP2 指纹类浏览器，
  /// 可规避部分站点对 dart:io HttpClient 指纹的 Cloudflare 质询拦截）。
  /// 返回响应体字符串（UTF-8）。Cronet 内部自动解压 gzip，故不重复解压。
  /// 非 Android 或 Cronet 不可用（无 GMS/初始化失败）时自动回退到 [get]（dart:io）。
  ///
  /// 探测策略：只在第一次请求时真正走 Cronet（[probeTimeout] 限时），一旦失败/超时
  /// 就把 [_cronetUsable] 置为 false，后续请求直接走 dart:io，不再反复消耗超时预算。
  static Future<String> getCronet(String urlStr,
      {Map<String, String>? headers, Duration? timeout}) async {
    if (_cronetUsable == false) {
      return get(urlStr, headers: headers, timeout: timeout);
    }
    final t = timeout ?? _timeout;
    final probe = t < const Duration(seconds: 8)
        ? t
        : const Duration(seconds: 6);
    try {
      final s = await _attemptCronet(
          urlStr, headers, t, probe,
          accept: '*/*', asBytes: false);
      return s as String;
    } catch (_) {
      _cronetUsable = false;
      return get(urlStr, headers: headers, timeout: timeout);
    }
  }

  /// 基于 Cronet 的 GET 请求，返回原始响应字节（Android 上使用 Chromium 网络栈，
  /// 规避对 dart:io HttpClient 指纹的 Cloudflare 质询拦截）。Cronet 自动解压 gzip。
  /// 非 Android 或 Cronet 初始化失败时自动回退到 [getBytes]。
  static Future<List<int>> getBytesCronet(String urlStr,
      {Map<String, String>? headers, Duration? timeout}) async {
    if (_cronetUsable == false) {
      return getBytes(urlStr, headers: headers);
    }
    final t = timeout ?? _timeout;
    final probe = t < const Duration(seconds: 8)
        ? t
        : const Duration(seconds: 6);
    try {
      final b = await _attemptCronet(
          urlStr, headers, t, probe,
          accept: 'image/webp,image/*,*/*', asBytes: true);
      if (b is List<int>) return b;
      return getBytes(urlStr, headers: headers);
    } catch (_) {
      _cronetUsable = false;
      return getBytes(urlStr, headers: headers);
    }
  }

  /// Cronet 是否已确认可用；null=未探测，false=已确认不可用（跳过 Cronet）。
  static bool? _cronetUsable;

  /// 真正走一次 Cronet 的完整请求（探测 + 响应），整体受 [probe] 限时。
  /// 成功返回 String 或 List<int>（按 [asBytes]），失败抛异常由调用方回退 dart:io。
  static Future<Object> _attemptCronet(
      String urlStr, Map<String, String>? headers, Duration t, Duration probe,
      {required String accept, required bool asBytes}) async {
    return Future<Object>(() async {
      final client = cronet.CronetClient.defaultCronetEngine();
      try {
        final req = http.Request('GET', Uri.parse(urlStr));
        req.headers['User-Agent'] = defaultUA;
        req.headers['Accept'] = accept;
        headers?.forEach((k, v) => req.headers[k] = v);
        final streamed = await client.send(req).timeout(t);
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          final body = await streamed.stream.toBytes().timeout(t);
          throw Exception(
              'HTTP ${streamed.statusCode}: ${utf8.decode(body, allowMalformed: true)}');
        }
        final bytes = await streamed.stream.toBytes().timeout(t);
        if (asBytes) return bytes;
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        client.close();
      }
    }).timeout(probe);
  }

  /// 智能字节请求：优先 Cronet（类浏览器 TLS/HTTP2 指纹，规避 Cloudflare 质询）；
  /// 仅对配置了优选 IP 直连的 host（如 TvTFun）保留 dart:io 的 connectionFactory 优化。
  /// 供图片缓存等通用图片加载使用。
  static Future<List<int>> getBytesAuto(String urlStr,
      {Map<String, String>? headers, Duration? timeout}) {
    final host = Uri.parse(urlStr).host;
    if (preferredHostIps.containsKey(host)) {
      return getBytes(urlStr, headers: headers);
    }
    return getBytesCronet(urlStr, headers: headers, timeout: timeout);
  }

  /// GET 请求，返回原始响应字节。
  static Future<List<int>> getBytes(String urlStr,
      {Map<String, String>? headers}) async {
    final client = _client(Uri.parse(urlStr).host);
    try {
      final req = await _request(client, 'GET', Uri.parse(urlStr), headers);
      final res = await req.close().timeout(_timeout);
      final bytes = await _readBytes(res, _timeout);
      _onDone(res, urlStr);
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  /// 读取响应字节，自动处理 gzip/deflate 压缩。
  static Future<List<int>> _readBytes(HttpClientResponse res, Duration t) async {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // 读取错误体用于抛出
      final errBytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(t);
      throw Exception('HTTP ${res.statusCode}: ${utf8.decode(errBytes, allowMalformed: true)}');
    }
    final enc = res.headers.value('Content-Encoding') ?? '';
    if (enc.contains('gzip')) {
      return await res.transform(gzip.decoder).fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(t);
    }
    if (enc.contains('deflate')) {
      return await res.transform(zlib.decoder).fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(t);
    }
    return await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(t);
  }

  /// POST 请求，body 为表单/JSON 字符串，返回响应体字符串（UTF-8）。
  static Future<String> post(String urlStr,
      {Map<String, String>? headers, String? body}) async {
    final client = _client(Uri.parse(urlStr).host);
    try {
      final req = await _request(client, 'POST', Uri.parse(urlStr), headers);
      if (body != null) {
        req.write(body);
      }
      final res = await req.close().timeout(_timeout);
      final bytes = await _readBytes(res, _timeout);
      _onDone(res, urlStr);
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }

  static Future<HttpClientRequest> _request(
      HttpClient client, String method, Uri uri,
      Map<String, String>? headers) async {
    final req =
        await (method == 'POST' ? client.postUrl(uri) : client.getUrl(uri));
    req.headers.set('User-Agent', defaultUA);
    req.headers.set('Accept', '*/*');
    headers?.forEach((k, v) => req.headers.set(k, v));
    return req;
  }

  /// 请求完成后，若该 host 配置了优选 IP 且遇到服务器错误/限流，切换下一个候选 IP。
  static void _onDone(HttpClientResponse res, String urlStr) {
    final host = Uri.parse(urlStr).host;
    final ips = preferredHostIps[host];
    if (ips == null || ips.isEmpty) return;
    if (res.statusCode >= 500 || res.statusCode == 429 || res.statusCode == 0) {
      final cur = _ipIndex[host] ?? 0;
      _ipIndex[host] = (cur + 1) % ips.length;
    }
  }

  /// 拼接 query 参数。
  static String buildUrl(String base, Map<String, String> params) {
    if (params.isEmpty) return base;
    final buf = StringBuffer(base);
    var first = !base.contains('?');
    params.forEach((k, v) {
      buf.write(first ? '?' : '&');
      first = false;
      buf.write(k);
      buf.write('=');
      buf.write(v);
    });
    return buf.toString();
  }
}
