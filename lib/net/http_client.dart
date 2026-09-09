import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cronet_http/cronet_http.dart' as cronet;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'local_store.dart';

/// 带状态码的 HTTP 异常：让重试逻辑能区分 5xx/429（可重试）与 4xx（不可重试）。
class HttpStatusException implements Exception {
  final int statusCode;
  final String body;
  HttpStatusException(this.statusCode, this.body);
  @override
  String toString() => 'HTTP $statusCode: $body';
}

/// 每域名令牌桶限流：控制对源站的请求频率与并发，避免对源站造成过大压力，
/// 降低 IP 被封风险（爬虫礼仪）。默认每域名 3 req/s、并发 ≤5。
class RateLimiter {
  RateLimiter._();

  static final RateLimiter instance = RateLimiter._();

  /// 每域名每秒最大请求数（令牌桶速率）。
  static const double _tokensPerSec = 3.0;

  /// 桶容量（突发上限）。
  static const double _burst = 5.0;

  /// 每域名最大并发请求数。
  static const int _maxConcurrent = 5;

  /// 测试环境下跳过限流：widget 测试无真实网络流量（HttpClient 恒返回 400），
  /// 且 fake-async 不允许测试结束时仍有挂起计时器。单元测试需用
  /// [debugForceEnabled] 强制开启以验证限流语义。
  static bool get _enabled =>
      debugForceEnabled || !Platform.environment.containsKey('FLUTTER_TEST');

  /// 测试辅助：强制开启限流（配合单元测试）。
  @visibleForTesting
  static bool debugForceEnabled = false;

  static final Map<String, _Bucket> _buckets = {};
  static final Map<String, int> _inflight = {};
  static final Random _random = Random();

  /// 请求开始前调用：等待令牌 + 并发槽位（限流排队，不丢请求）。
  static Future<void> acquire(String host) async {
    if (!_enabled) return;
    final bucket = _bucketFor(host);
    while (true) {
      bucket.refill();
      final inflight = _inflight[host] ?? 0;
      if (inflight < _maxConcurrent && bucket.tokens >= 1.0) {
        bucket.tokens -= 1.0;
        _inflight[host] = inflight + 1;
        return;
      }
      // 队列等待；并发满或令牌不足时让出事件循环
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 请求完成后调用：释放并发槽位。批量请求间可加随机小延迟错峰。
  static void release(String host, {bool jitter = false}) {
    if (!_enabled) return;
    final inflight = _inflight[host] ?? 0;
    _inflight[host] = inflight > 0 ? inflight - 1 : 0;
    if (jitter && _random.nextDouble() < 0.3) {
      // 30% 概率在释放后稍等 0~150ms，打散批量请求的节奏
      Future<void>.delayed(Duration(
          milliseconds: 50 + _random.nextInt(100))).ignore();
    }
  }

  static _Bucket _bucketFor(String host) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = _buckets[host];
    if (b != null) {
      b.lastRefillMs = now;
      return b;
    }
    final nb = _Bucket(now);
    _buckets[host] = nb;
    return nb;
  }

  /// 测试辅助：清空限流状态。
  @visibleForTesting
  static void reset() {
    _buckets.clear();
    _inflight.clear();
  }

  /// 测试辅助：当前某域名的并发数。
  @visibleForTesting
  static int debugInflight(String host) => _inflight[host] ?? 0;
}

class _Bucket {
  double tokens;
  int lastRefillMs;
  _Bucket(this.lastRefillMs) : tokens = RateLimiter._burst;

  /// 按经过时间补充令牌（1 秒 3 个）。
  void refill() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - lastRefillMs;
    if (elapsed <= 0) return;
    lastRefillMs = now;
    tokens = min(RateLimiter._burst, tokens + elapsed * RateLimiter._tokensPerSec / 1000);
  }
}

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

  /// 全局代理（`socks5://host:port` / `http://host:port` / `https://host:port`）。
  /// 空串/null 表示直连。仅对 dart:io 路径生效；配置代理后 Cronet 路径自动跳过
  /// （Cronet 默认引擎不读代理配置，避免 Android 上代理被绕过）。
  static String? proxy;

  /// 将代理解析为 dart:io findProxy 返回的 PAC 风格指令；null 表示直连。
  /// 仅支持 host:port（不带 scheme）时按 http 代理处理。
  static String? _proxyDirective(String? p) {
    if (p == null || p.trim().isEmpty) return null;
    final s = p.trim();
    var scheme = 'http';
    var rest = s;
    final i = s.indexOf('://');
    if (i > 0) {
      scheme = s.substring(0, i).toLowerCase();
      rest = s.substring(i + 3);
    }
    switch (scheme) {
      case 'socks5':
      case 'socks5h':
        return 'SOCKS5 $rest';
      case 'socks4':
        return 'SOCKS4 $rest';
      default:
        return 'PROXY $rest';
    }
  }

  /// 单次请求是否走代理：proxy=null 走全局代理/直连；proxy='' 强制直连；
  /// proxy=具体串 强制走该代理（单源代理覆盖全局）。

  /// 构造 HttpClient；若该 host 配置了优选 IP，则通过 connectionFactory 强制直连。
  /// 优选 IP 全部失败时，自动回退到系统 DNS 解析，避免整源因写死 IP 失效而挂死。
  /// 代理启用时优先走代理（findProxy 自动处理 CONNECT 隧道），
  /// 与 connectionFactory 互斥——代理模式下不设 connectionFactory。
  static HttpClient _client(String host, {String? proxy}) {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..autoUncompress = false
      ..badCertificateCallback = (cert, h, port) => true; // 允许自签证书，兼容部分源
    // 单源代理（proxy != null 且非空）> 全局代理（_effectiveProxy）；空串表示直连
    final p = (proxy == null) ? _effectiveProxy : (proxy.isEmpty ? null : proxy);
    if (p != null) {
      final directive = _proxyDirective(p);
      if (directive != null) {
        client.findProxy = (url) => directive;
        return client;
      }
    }
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

  /// 带代理失败回退的 GET：先用代理（若有），连接层异常/超时后自动换直连重试一次。
  /// 避免代理节点故障导致整源不可用。
  static Future<String> _getWithFallback(String urlStr,
      Map<String, String>? headers, Duration? timeout, String? proxy) async {
    if (proxy == null && _effectiveProxy == null) {
      return _getOnce(urlStr, headers, timeout, proxy: null);
    }
    try {
      return await _getOnce(urlStr, headers, timeout, proxy: proxy);
    } catch (e) {
      // 只有网络层失败才回退直连；HTTP 4xx/5xx 是源站响应，不是代理问题
      if (!_retryable(e)) rethrow;
      return _getOnce(urlStr, headers, timeout, proxy: '');
    }
  }

  /// 带代理失败回退的字节 GET。
  static Future<List<int>> _getBytesWithFallback(String urlStr,
      Map<String, String>? headers, Duration? timeout, String? proxy) async {
    if (proxy == null && _effectiveProxy == null) {
      return _getBytesOnce(urlStr, headers, proxy: null, timeout: timeout);
    }
    try {
      return await _getBytesOnce(urlStr, headers, proxy: proxy, timeout: timeout);
    } catch (e) {
      if (!_retryable(e)) rethrow;
      return _getBytesOnce(urlStr, headers, proxy: '', timeout: timeout);
    }
  }

  /// 是否全局代理已启用（避免每次请求都解析字符串）。
  static bool _proxyEnabled = false;
  static String? _effectiveProxy;

  /// 从本地持久化恢复全局代理（用户在网络工具页配置后写入本地）。
  /// 应用启动时调用一次。
  static Future<void> restoreProxy() async {
    try {
      final v = await LocalStore.readJson('global_proxy');
      if (v is String) {
        proxy = v.isEmpty ? null : v;
        _applyProxy();
      }
    } catch (_) {
      // 恢复失败保留直连
    }
  }

  /// 设置并持久化全局代理；传入空串/仅空白则清空代理恢复直连。
  static Future<void> setProxy(String? p) async {
    proxy = (p == null || p.trim().isEmpty) ? null : p.trim();
    _applyProxy();
    await LocalStore.writeJson('global_proxy', proxy ?? '');
  }

  /// WebDAV 等自定义协议层读取：当前是否启用了全局代理。
  static bool get proxyEnabled => _proxyEnabled;

  /// WebDAV 等自定义协议层读取：findProxy 用的 PAC 指令；未启用代理返回 null。
  static String? get proxyDirective => _effectiveProxy;

  static void _applyProxy() {
    _effectiveProxy = _proxyDirective(proxy);
    _proxyEnabled = _effectiveProxy != null;
  }

  /// 从本地持久化恢复用户自选的优选 IP（覆盖内置默认）。
  /// 应用启动时调用一次；工具页「优选 IP」扫描应用后会写入本地。
  static Future<void> restorePreferredHostIps() async {
    try {
      final j = await LocalStore.readJson('preferred_ips');
      if (j is Map) {
        j.forEach((k, v) {
          if (v is List && k is String) {
            preferredHostIps[k] = v.whereType<String>().toList();
          }
        });
      }
    } catch (_) {
      // 恢复失败则保留内置默认
    }
  }

  /// 将当前优选 IP 配置持久化到本地，重启后由 [restorePreferredHostIps] 恢复。
  static Future<void> savePreferredHostIps() async {
    try {
      await LocalStore.writeJson('preferred_ips', preferredHostIps);
    } catch (_) {
      // 写失败忽略，不影响内存配置
    }
  }

  /// 当前域名已尝试到的候选 IP 下标，失败时轮询切换。
  static final Map<String, int> _ipIndex = {};

  /// GET 请求，返回响应体字符串（UTF-8）。
  /// 瞬态失败（超时/连接重置/5xx/429）自动重试 1 次（指数退避 600ms），
  /// 解决部分源站（如 xbiquge）间歇性超时/连接被重置导致的假性失败。
  /// 4xx 与确定性失败不重试，避免拖长错误反馈。
  /// [proxy] 为单源代理覆盖：null=走全局代理/直连；''=强制直连；其余=强制走该代理。
  static Future<String> get(String urlStr,
      {Map<String, String>? headers, Duration? timeout, String? proxy}) async {
    if (proxy == null) {
      try {
        return await _getOnce(urlStr, headers, timeout, proxy: null);
      } catch (e) {
        if (!_retryable(e)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return _getOnce(urlStr, headers, timeout, proxy: null);
      }
    }
    // 单源代理：先走代理，网络层失败自动回退直连（代理节点故障不拖死整源）
    return _getWithFallback(urlStr, headers, timeout, proxy);
  }

  /// 判断异常是否值得重试：网络层瞬态错误或服务器端错误。
  static bool _retryable(Object e) {
    if (e is HttpStatusException) {
      return e.statusCode >= 500 || e.statusCode == 429;
    }
    return e is SocketException ||
        e is TimeoutException ||
        e is HandshakeException;
  }

  static Future<String> _getOnce(String urlStr, Map<String, String>? headers,
      Duration? timeout, {String? proxy}) async {
    final t = timeout ?? _timeout;
    // 限流：等待令牌与并发槽位（降低对源站压力，避免被封）
    final host = Uri.parse(urlStr).host;
    await RateLimiter.acquire(host);
    final client = _client(host, proxy: proxy);
    try {
      final req = await _request(
          client, 'GET', Uri.parse(urlStr), headers, timeout: t);
      final res = await req.close().timeout(t);
      final bytes = await _readBytes(res, t);
      _onDone(res, urlStr);
      return utf8.decode(bytes);
    } finally {
      RateLimiter.release(host, jitter: true);
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
    if (_cronetUsable == false || _proxyEnabled) {
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
  /// [proxy] 为单源代理覆盖：非 null（含空串强制直连）时跳过 Cronet 走 dart:io——
  /// Cronet 默认引擎不读代理配置，走它等于绕过代理，故代理场景必须走 [getBytes]。
  static Future<List<int>> getBytesCronet(String urlStr,
      {Map<String, String>? headers, Duration? timeout, String? proxy}) async {
    if (proxy != null || _cronetUsable == false || _proxyEnabled) {
      return getBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout);
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
      return getBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout);
    } catch (_) {
      _cronetUsable = false;
      return getBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout);
    }
  }

  /// Cronet 是否已确认可用；null=未探测，false=已确认不可用（跳过 Cronet）。
  static bool? _cronetUsable;

  /// 真正走一次 Cronet 的完整请求（探测 + 响应），整体受 [probe] 限时。
  /// 成功返回 String 或 `List<int>`（按 [asBytes]），失败抛异常由调用方回退 dart:io。
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
  /// [proxy] 为单源代理覆盖：非 null 时强制走 dart:io（Cronet 不读代理配置）。
  static Future<List<int>> getBytesAuto(String urlStr,
      {Map<String, String>? headers, Duration? timeout, String? proxy}) async {
    final host = Uri.parse(urlStr).host;
    if (proxy != null || preferredHostIps.containsKey(host)) {
      return getBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout);
    }
    return getBytesCronet(urlStr, headers: headers, timeout: timeout, proxy: proxy);
  }

  /// GET 请求，返回原始响应字节。
  /// [proxy] 为单源代理覆盖：null=走全局代理/直连；''=强制直连；其余=强制走该代理。
  static Future<List<int>> getBytes(String urlStr,
      {Map<String, String>? headers, String? proxy, Duration? timeout}) async {
    if (proxy == null) {
      return _getBytesOnce(urlStr, headers, proxy: null, timeout: timeout);
    }
    return _getBytesWithFallback(urlStr, headers, timeout, proxy);
  }

  static Future<List<int>> _getBytesOnce(String urlStr,
      Map<String, String>? headers, {String? proxy, Duration? timeout}) async {
    final t = timeout ?? _timeout;
    final client = _client(Uri.parse(urlStr).host, proxy: proxy);
    try {
      final req = await _request(
          client, 'GET', Uri.parse(urlStr), headers, timeout: t);
      final res = await req.close().timeout(t);
      final bytes = await _readBytes(res, t);
      _onDone(res, urlStr);
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  /// 读取响应字节，自动处理 gzip/deflate 压缩。
  static Future<List<int>> _readBytes(HttpClientResponse res, Duration t) async {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // 读取错误体用于抛出（带状态码，供重试逻辑判断可重试性）
      final errBytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(t);
      throw HttpStatusException(
          res.statusCode, utf8.decode(errBytes, allowMalformed: true));
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
  /// [proxy] 为单源代理覆盖：null=走全局代理/直连；''=强制直连；其余=强制走该代理。
  static Future<String> post(String urlStr,
      {Map<String, String>? headers, String? body, String? proxy}) async {
    if (proxy == null) {
      return _postOnce(urlStr, headers, body, proxy: null);
    }
    try {
      return await _postOnce(urlStr, headers, body, proxy: proxy);
    } catch (e) {
      // 单源代理连接失败自动回退直连；强制直连（proxy=''）无需再回退
      if (proxy.isEmpty || !_retryable(e)) rethrow;
      return _postOnce(urlStr, headers, body, proxy: '');
    }
  }

  static Future<String> _postOnce(String urlStr,
      Map<String, String>? headers, String? body,
      {String? proxy, Duration? timeout}) async {
    final t = timeout ?? _timeout;
    final client = _client(Uri.parse(urlStr).host, proxy: proxy);
    try {
      final req = await _request(
          client, 'POST', Uri.parse(urlStr), headers, timeout: t);
      if (body != null) {
        // 显式 UTF-8：http 包默认按 platformEncoding 编码，中文 JSON body
        // 会被错误编码（如弹幕匹配的"番名 第N集"）导致服务端拒绝
        req.write(utf8.encode(body));
      }
      final res = await req.close().timeout(t);
      final bytes = await _readBytes(res, t);
      _onDone(res, urlStr);
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }

  static Future<HttpClientRequest> _request(
      HttpClient client, String method, Uri uri,
      Map<String, String>? headers,
      {Duration? timeout}) async {
    final req = await (method == 'POST'
            ? client.postUrl(uri)
            : client.getUrl(uri))
        .timeout(timeout ?? _timeout);
    req.headers.set('User-Agent', defaultUA);
    req.headers.set('Accept', '*/*');
    final h = <String, String>{...?headers};
    if (method == 'POST' &&
        (h['Content-Type'] ?? '').isNotEmpty &&
        !h['Content-Type']!.toLowerCase().contains('charset')) {
      // POST 与 JSON body 配套时补 UTF-8 声明，否则服务端按默认编码解析乱码
      h['Content-Type'] = '${h['Content-Type']}; charset=utf-8';
    }
    h.forEach((k, v) => req.headers.set(k, v));
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
