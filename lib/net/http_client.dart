import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cronet_conditional.dart';
import 'local_store.dart';
import 'net_conn.dart';
import 'platform_http.dart';

/// 连接/读取原语与两个 HTTP 异常已下沉到 [net_conn.dart]（P0-2：解除
/// `platform_http_io.dart → http_client.dart` 的循环 import——平台层此前
/// 反向 import 编排层只为借 [Net.readLimited]/[Net.clientForRequest]）。
/// 这里转出，`show HttpStatusException` 之类的既有 import 无需改动。
export 'net_conn.dart' show HttpStatusException, ResponseTooLargeException;

/// 限流通道：数据接口与静态资源分开计费。
///
/// 数据接口（API/页面/RPC）保持礼貌的 3 req/s、并发 ≤5（爬虫礼仪）；
/// 静态资源（封面图/文件下载）常与接口同域，共用一个 3/s 小桶会出问题：
/// 一屏 24 张封面瞬间耗光 burst(5)，剩下 19 张按 3/s 排队 6s+ 才开拉、并发
/// 只有 5，还把同域的首页数据接口一起饿死（列表一直转圈）；队列积压到
/// 上限直接抛错，封面静默变灰（"加载失败"）。静态资源按浏览器级并发
/// （Chrome 同域 6 连接）单独放行：6 req/s、并发 6。两通道按
/// (channel, host) 独立计费，互不抢令牌。
enum RateChannel { api, asset }

/// 每域名令牌桶限流：控制对源站的请求频率与并发，避免对源站造成过大压力，
/// 降低 IP 被封风险（爬虫礼仪）。API 默认每域名 3 req/s、并发 ≤5；
/// 静态资源走 [RateChannel.asset] 见该枚举注释。
class RateLimiter {
  RateLimiter._();

  static final RateLimiter instance = RateLimiter._();

  /// 通道参数：(速率 req/s, 桶容量突发上限, 并发上限, 排队上限)。
  static ({double rate, double burst, int concurrent, int queue}) paramsOf(
          RateChannel channel) =>
      channel == RateChannel.api
          ? (rate: 3.0, burst: 5.0, concurrent: 5, queue: 40)
          : (rate: 6.0, burst: 12.0, concurrent: 6, queue: 60);

  /// 单请求在限流队列中的最长等待时间：超时抛出，让调用方走超时/降级
  /// 路径（原本无限排队会把超时请求拖到永不出网，UI 直接转圈）。
  static const Duration _acquireTimeout = Duration(seconds: 30);

  /// 测试环境下跳过限流：widget 测试无真实网络流量（HttpClient 恒返回 400），
  /// 且 fake-async 不允许测试结束时仍有挂起计时器。单元测试需用
  /// [debugForceEnabled] 强制开启以验证限流语义。
  /// Web 无 dart:io 环境变量概念，直接按非测试处理。
  static bool get _enabled =>
      debugForceEnabled || !_isTestEnvironment();

  static bool _isTestEnvironment() {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  /// 测试辅助：强制开启限流（配合单元测试）。
  @visibleForTesting
  static bool debugForceEnabled = false;

  static final Map<String, _Bucket> _buckets = {};
  static final Map<String, int> _inflight = {};
  static final Map<String, int> _waiting = {};

  /// 请求开始前调用：等待令牌 + 并发槽位（限流排队，不丢请求）。
  /// 排队有上限与超时：队列塞满（慢域被卡死）或等待过久直接抛错，
  /// 调用方按网络异常处理（走降级/超时路径）。
  /// [channel] 决定用哪套参数与哪个桶（默认 API 通道）。
  static Future<void> acquire(String host,
      {RateChannel channel = RateChannel.api}) async {
    if (!_enabled) return;
    final key = _key(channel, host);
    final params = paramsOf(channel);
    final bucket = _bucketFor(key, channel);
    final deadline =
        DateTime.now().add(_acquireTimeout);
    while (true) {
      bucket.refill();
      final waiting = _waiting[key] ?? 0;
      if (waiting >= params.queue) {
        throw StateError('RateLimiter 队列超限: $key');
      }
      final inflight = _inflight[key] ?? 0;
      if (inflight < params.concurrent && bucket.tokens >= 1.0) {
        bucket.tokens -= 1.0;
        _inflight[key] = inflight + 1;
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('RateLimiter 等待超时: $key', _acquireTimeout);
      }
      // 队列等待；并发满或令牌不足时让出事件循环
      _waiting[key] = waiting + 1;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      _waiting[key] = DateTime.now().isAfter(deadline)
          ? 0
          : ((_waiting[key] ?? 1) - 1).clamp(0, params.queue);
    }
  }

  /// 请求完成后调用：释放并发槽位（[channel] 须与 acquire 时一致）。
  static void release(String host, {RateChannel channel = RateChannel.api}) {
    if (!_enabled) return;
    final key = _key(channel, host);
    final inflight = _inflight[key] ?? 0;
    _inflight[key] = inflight > 0 ? inflight - 1 : 0;
  }

  /// 桶键：(通道, 域名) 隔离——同一域名的 API 与图片互不抢令牌。
  static String _key(RateChannel channel, String host) =>
      '${channel.name}|$host';

  static _Bucket _bucketFor(String key, RateChannel channel) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = _buckets[key];
    if (b != null) {
      return b;
    }
    final p = paramsOf(channel);
    final nb = _Bucket(now, rate: p.rate, burst: p.burst);
    _buckets[key] = nb;
    return nb;
  }

  /// 测试辅助：清空限流状态。
  @visibleForTesting
  static void reset() {
    _buckets.clear();
    _inflight.clear();
    _waiting.clear();
  }

  /// 测试辅助：当前某域名某通道的并发数（默认 API 通道）。
  @visibleForTesting
  static int debugInflight(String host,
          {RateChannel channel = RateChannel.api}) =>
      _inflight[_key(channel, host)] ?? 0;
}

class _Bucket {
  double tokens;
  int lastRefillMs;
  final double rate;
  final double burst;

  _Bucket(this.lastRefillMs, {required this.rate, required this.burst})
      : tokens = burst;

  /// 按经过时间补充令牌（速率随通道而定）。
  void refill() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - lastRefillMs;
    if (elapsed <= 0) return;
    lastRefillMs = now;
    tokens = min(burst, tokens + elapsed * rate / 1000);
  }
}

/// 零第三方依赖 HTTP 客户端（基于 dart:io HttpClient）。
/// 注意：类名用 Net，避免与 dart:io 的 HttpClient 冲突。
class Net {
  /// 连接/读取原语（超时 / 上限 / 连接构造 / 优选 IP / 代理 / 自签信任）已下沉
  /// [NetConn]（P0-2：平台层不再反向依赖编排层）。此处全部转口，既有 36 处
  /// 外部调用点零改动。
  static const Duration _timeout = NetConn.timeout;

  /// 文本类请求（[get]/[getCronet]/[post]）响应体字节上限。
  static const int maxTextBytes = NetConn.maxTextBytes;

  /// 字节类下载（[downloadBytes]/[getBytesCronet]/[getBytesAuto]/[getBytesMirrors]）
  /// 的响应体上限。
  static const int maxDownloadBytes = NetConn.maxDownloadBytes;

  /// 单个候选 IP 的连接超时（连接构造已下沉 [NetConn.clientForRequest]）。

  /// 测试辅助：统计真实出网尝试次数（验证重试层数收敛为 1，P0-2 回归守护）。
  @visibleForTesting
  static bool debugCountIoGet = false;

  /// 已发生的真实 IO GET 次数（仅 [debugCountIoGet] 为 true 时累计）。
  @visibleForTesting
  static int debugIoGetAttempts = 0;

  static const String defaultUA = NetConn.defaultUA;

  /// 需要强制走特定 IP 的域名 -> 候选 IP 列表（Cloudflare 优选 IP 加速）。
  static Map<String, List<String>> get preferredHostIps =>
      NetConn.preferredHostIps;

  /// 全局代理（`http://host:port` / `https://host:port`；dart:io 不支持
  /// socks，socks5/socks4 前缀会被明确拒绝为直连）。
  ///
  /// 只读：写代理统一走 [setProxy]（含持久化 + [NetConn.applyProxy]），
  /// 直接赋 setter 会漏 applyProxy 导致配置不生效（历史死代码，已删）。
  static String? get proxy => NetConn.proxy;

  /// 单次请求是否走代理：proxy=null 走全局代理/直连；proxy='' 强制直连；
  /// proxy=具体串 强制走该代理（单源代理覆盖全局）。

  /// 是否信任自签证书（默认 false）。转口 [NetConn.trustSelfSigned]。
  static bool get trustSelfSigned => NetConn.trustSelfSigned;
  static set trustSelfSigned(bool v) => NetConn.trustSelfSigned = v;

  /// 从本地持久化恢复「信任自签证书」开关。应用启动时调用一次。
  static Future<void> restoreTrustSelfSigned() async {
    try {
      final v = await LocalStore.readJson('trust_self_signed');
      NetConn.trustSelfSigned = v == true;
    } catch (_) {
      // 恢复失败保持默认（不信任）
    }
  }

  /// 设置并持久化「信任自签证书」开关。
  static Future<void> setTrustSelfSigned(bool on) async {
    NetConn.trustSelfSigned = on;
    await LocalStore.writeJson('trust_self_signed', on);
  }

  /// 构造 HttpClient（代理 / 优选 IP / 信任自签）。转口 [NetConn.clientForRequest]。
  static HttpClient clientForRequest(String host, {String? proxy}) =>
      NetConn.clientForRequest(host, proxy: proxy);

  /// 带代理失败回退的 GET：先用代理（若有），连接层异常/超时后自动换直连重试一次。
  /// 避免代理节点故障导致整源不可用。
  static Future<String> _getWithFallback(String urlStr,
      Map<String, String>? headers, Duration? timeout, String? proxy,
      [int? maxBytes]) async {
    if (proxy == null && !NetConn.proxyEnabled) {
      return _getOnce(urlStr, headers, timeout, proxy: null, maxBytes: maxBytes);
    }
    try {
      return await _getOnce(urlStr, headers, timeout, proxy: proxy, maxBytes: maxBytes);
    } catch (e) {
      // 只有网络层失败才回退直连；HTTP 4xx/5xx 是源站响应，不是代理问题
      if (!_retryable(e)) rethrow;
      return _getOnce(urlStr, headers, timeout, proxy: '', maxBytes: maxBytes);
    }
  }

  /// 带代理失败回退的字节 GET。
  static Future<List<int>> _getBytesWithFallback(String urlStr,
      Map<String, String>? headers, Duration? timeout, String? proxy,
      [int? maxBytes]) async {
    if (proxy == null && !NetConn.proxyEnabled) {
      return _getBytesOnce(urlStr, headers, proxy: null, timeout: timeout, maxBytes: maxBytes);
    }
    try {
      return await _getBytesOnce(urlStr, headers, proxy: proxy, timeout: timeout, maxBytes: maxBytes);
    } catch (e) {
      if (!_retryable(e)) rethrow;
      return _getBytesOnce(urlStr, headers, proxy: '', timeout: timeout, maxBytes: maxBytes);
    }
  }

  /// 从本地持久化恢复全局代理（用户在网络工具页配置后写入本地）。
  /// 应用启动时调用一次。持久化仍由此层负责（[NetConn] 保持零应用层依赖）。
  static Future<void> restoreProxy() async {
    try {
      final v = await LocalStore.readJson('global_proxy');
      if (v is String) {
        NetConn.proxy = v.isEmpty ? null : v;
        NetConn.applyProxy();
      }
    } catch (_) {
      // 恢复失败保留直连
    }
  }

  /// 设置并持久化全局代理；传入空串/仅空白则清空代理恢复直连。
  static Future<void> setProxy(String? p) async {
    NetConn.proxy = (p == null || p.trim().isEmpty) ? null : p.trim();
    NetConn.applyProxy();
    await LocalStore.writeJson('global_proxy', NetConn.proxy ?? '');
  }

  /// WebDAV 等自定义协议层读取：当前是否启用了全局代理。
  static bool get proxyEnabled => NetConn.proxyEnabled;

  /// WebDAV 等自定义协议层读取：findProxy 用的 PAC 指令；未启用代理返回 null。
  static String? get proxyDirective => NetConn.proxyDirective;

  /// 从本地持久化恢复用户自选的优选 IP（覆盖内置默认）。
  static Future<void> restorePreferredHostIps() async {
    try {
      final j = await LocalStore.readJson('preferred_ips');
      if (j is Map) {
        j.forEach((k, v) {
          if (v is List && k is String) {
            NetConn.preferredHostIps[k] = v.whereType<String>().toList();
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
      await LocalStore.writeJson('preferred_ips', NetConn.preferredHostIps);
    } catch (_) {
      // 写失败忽略，不影响内存配置
    }
  }

  /// 供 platform_http_io 在收到 5xx/429 后轮换候选 IP：返回下一个应尝试的下标。
  static int rotateIpIndex(String host) => NetConn.rotateIpIndex(host);

  /// [proxy] 为单源代理覆盖：null=走全局代理/直连；''=强制直连；其余=强制走该代理。
  /// [maxBytes] 覆盖响应体上限（默认 [maxTextBytes]）。
  ///
  /// [retry] 是否启用本层「瞬时失败重试一次」。默认 true（直接调用方的既有行为）。
  /// **上层已自建重试时须传 false**（如 [SourceHttp.get] 外层已包
  /// `withTransientRetry`）：两层各自重试会让单个 GET 最坏产生 4 次真实请求
  /// （P0-2 审计项），重试层数收敛为 1。
  static Future<String> get(String urlStr,
      {Map<String, String>? headers,
      Duration? timeout,
      String? proxy,
      int? maxBytes,
      bool retry = true}) async {
    if (proxy == null) {
      try {
        return await _getOnce(urlStr, headers, timeout, proxy: null, maxBytes: maxBytes);
      } catch (e) {
        if (!retry || !_retryable(e)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return _getOnce(urlStr, headers, timeout, proxy: null, maxBytes: maxBytes);
      }
    }
    // 单源代理：先走代理，网络层失败自动回退直连（代理节点故障不拖死整源）
    return _getWithFallback(urlStr, headers, timeout, proxy, maxBytes);
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
      Duration? timeout, {String? proxy, int? maxBytes}) async {
    final t = timeout ?? _timeout;
    final limit = maxBytes ?? maxTextBytes;
    if (debugCountIoGet) debugIoGetAttempts++;
    // 限流：等待令牌与并发槽位（降低对源站压力，避免被封）
    final host = Uri.parse(urlStr).host;
    await RateLimiter.acquire(host);
    try {
      final bytes = await PlatformHttp.get(urlStr, headers, t, proxy, limit);
      // 与 Cronet 路径（allowMalformed: true）保持一致：部分站点返回的
      // 页面含非 UTF-8 字节序列（GBK 残留/编码声明与实际不符），严格解码
      // 会抛 FormatException → 同一次请求在「Cronet 可用/不可用」两条路径
      // 上行为不一致（一边成功一边崩溃）。容错解码替换坏字节，页面照常解析。
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      RateLimiter.release(host);
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
      {Map<String, String>? headers,
      Duration? timeout,
      int? maxBytes,
      bool retry = true}) async {
    if (!_cronetPlatform || _cronetUsable == false || NetConn.proxyEnabled) {
      return get(urlStr, headers: headers, timeout: timeout, maxBytes: maxBytes, retry: retry);
    }
    final t = timeout ?? _timeout;
    final limit = maxBytes ?? maxTextBytes;
    final probe = t < const Duration(seconds: 8)
        ? t
        : const Duration(seconds: 6);
    try {
      final s = await _attemptCronet(
          urlStr, headers, t, probe, limit,
          accept: '*/*', asBytes: false);
      return s as String;
    } catch (_) {
      _cronetUsable = false;
      return get(urlStr, headers: headers, timeout: timeout, maxBytes: maxBytes, retry: retry);
    }
  }

  /// 基于 Cronet 的 GET 请求，返回原始响应字节（Android 上使用 Chromium 网络栈，
  /// 规避对 dart:io HttpClient 指纹的 Cloudflare 质询拦截）。Cronet 自动解压 gzip。
  /// 非 Android 或 Cronet 初始化失败时自动回退到 [getBytes]。
  /// [proxy] 为单源代理覆盖：非 null（含空串强制直连）时跳过 Cronet 走 dart:io——
  /// Cronet 默认引擎不读代理配置，走它等于绕过代理，故代理场景必须走 [getBytes]。
  static Future<List<int>> getBytesCronet(String urlStr,
      {Map<String, String>? headers, Duration? timeout, String? proxy, int? maxBytes}) async {
    if (proxy != null || !_cronetPlatform || _cronetUsable == false || NetConn.proxyEnabled) {
      return downloadBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout, maxBytes: maxBytes);
    }
    final t = timeout ?? _timeout;
    final limit = maxBytes ?? maxDownloadBytes;
    final probe = t < const Duration(seconds: 8)
        ? t
        : const Duration(seconds: 6);
    try {
      final b = await _attemptCronet(
          urlStr, headers, t, probe, limit,
          accept: 'image/webp,image/*,*/*', asBytes: true);
      if (b is List<int>) return b;
      return downloadBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout, maxBytes: maxBytes);
    } catch (_) {
      _cronetUsable = false;
      return downloadBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout, maxBytes: maxBytes);
    }
  }

  /// Cronet 是否已确认可用；null=未探测，false=已确认不可用（跳过 Cronet）。
  static bool? _cronetUsable;

  /// Cronet 只在 Android 存在。非 Android 上 `defaultCronetEngine()` 返回的
  /// client 要到 send() 才炸（JNI 动态库缺失），首帧突发里一屏封面会在
  /// 标志位翻转前各自白跑一次引擎构建。这里直接短路，连尝试都不发起。
  static final bool _cronetPlatform =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 复用的 Cronet 客户端（内含 Chromium 网络栈：网络线程、socket pool、缓存）。
  ///
  /// 必须复用：`defaultCronetEngine()` 构造的 client 带 `_closeEngine=true`，
  /// `close()` 会真的销毁引擎，而引擎一销毁 socket pool 就跟着没了。旧实现
  /// 每个请求 new 一个 + finally close —— 一屏 24 张同域封面 = 24 次完整
  /// TCP+TLS 握手，连接零复用，这是 Android 图片慢的主要来源之一。
  static http.Client? _cronetClient;

  /// 真正走一次 Cronet 的完整请求（探测 + 响应），整体受 [probe] 限时。
  /// 成功返回 String 或 `List<int>`（按 [asBytes]），失败抛异常由调用方回退 dart:io。
  ///
  /// 资源安全：外层 `.timeout(probe)` 触发时，内部 `finally` 仍同步执行
  /// `client.close()`（close 为同步 void，无 Future 可等待），client 一定被
  /// 释放，不会因超时路径泄漏连接。
  static Future<Object> _attemptCronet(
      String urlStr, Map<String, String>? headers, Duration t, Duration probe,
      int limit,
      {required String accept, required bool asBytes}) {
    return Future<Object>(() async {
      final client = _cronetClient ??= CronetHttp.defaultCronetEngine();
      // web 上 Cronet 不可用（stub 返回 null），抛错让调用方回退 dart:io。
      if (client == null) throw UnsupportedError('Cronet 仅支持 Android');
      try {
        final req = http.Request('GET', Uri.parse(urlStr));
        req.headers['User-Agent'] = defaultUA;
        req.headers['Accept'] = accept;
        headers?.forEach((k, v) => req.headers[k] = v);
        final streamed = await client.send(req).timeout(t);
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          final body = await readLimited(streamed.stream, limit, t);
          // 用 HttpStatusException 而非裸 Exception：调用方据此区分
          // 「这个 URL 的问题」与「Cronet 引擎不可用」，一张封面 404 或一次
          // CF 403 不应把 Cronet 全局下线（见 getCronet/getBytesCronet）。
          throw HttpStatusException(
              streamed.statusCode, utf8.decode(body, allowMalformed: true));
        }
        final bytes = await readLimited(streamed.stream, limit, t);
        if (asBytes) return bytes;
        return utf8.decode(bytes, allowMalformed: true);
      } catch (e) {
        // HTTP 状态错误是这次请求的问题，引擎与连接池照常留着复用；
        // 只有引擎本身不可用才丢弃，下一次请求重建干净的。
        if (e is! HttpStatusException) _cronetClient = null;
        rethrow;
      }
      // 注意：不再 client.close()。close() 会销毁 CronetEngine，socket pool
      // 随之消失，同域下一张图又要完整 TCP+TLS 握手。引擎常驻才有连接复用。
    }).timeout(probe);
  }

  /// 分块读取响应流（转口 [NetConn.readLimited]：io/Cronet/web 三条线上路径
  /// 共用同一份上限语义，实现已下沉连接原语库）。
  static Future<List<int>> readLimited(
          Stream<List<int>> stream, int limit, Duration t) =>
      NetConn.readLimited(stream, limit, t);

  /// 智能字节请求：优先 Cronet（类浏览器 TLS/HTTP2 指纹，规避 Cloudflare 质询）；
  /// 仅对配置了优选 IP 直连的 host（如 TvTFun）保留 dart:io 的 connectionFactory 优化。
  /// 供图片缓存等通用图片加载使用。
  /// [proxy] 为单源代理覆盖：非 null 时强制走 dart:io（Cronet 不读代理配置）。
  static Future<List<int>> getBytesAuto(String urlStr,
      {Map<String, String>? headers, Duration? timeout, String? proxy, int? maxBytes}) async {
    final host = Uri.parse(urlStr).host;
    if (proxy != null || preferredHostIps.containsKey(host)) {
      return downloadBytes(urlStr, headers: headers, proxy: proxy, timeout: timeout, maxBytes: maxBytes);
    }
    return getBytesCronet(urlStr, headers: headers, timeout: timeout, proxy: proxy, maxBytes: maxBytes);
  }

  /// GET 请求，返回原始响应字节（下载基元，P2-13 五入口收敛后唯一原语）。
  /// [proxy] 为单源代理覆盖：null=走全局代理/直连；''=强制直连；其余=强制走该代理。
  /// [maxBytes] 覆盖响应体上限（默认 [maxDownloadBytes]）。
  /// [onProgress] 非 null 时走分块读取，边收边报 `(received, total)`（[total]
  /// 来自 content-length，缺失为 null，UI 退化为不定进度）。用途：数百 MB 的
  /// 模型权重下载（能力中心）。仅 io 端有传输中进度，web 端回落无进度路径
  /// （fetch 不暴露进度，语义不变）。与无进度路径同契约：非 2xx 抛
  /// [HttpStatusException]，超上限抛 [ResponseTooLargeException]，限流/代理沿用。
  static Future<List<int>> downloadBytes(
    String urlStr, {
    Map<String, String>? headers,
    String? proxy,
    Duration? timeout,
    int? maxBytes,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (onProgress == null) {
      if (proxy == null) {
        return _getBytesOnce(urlStr, headers, proxy: null, timeout: timeout, maxBytes: maxBytes);
      }
      return _getBytesWithFallback(urlStr, headers, timeout, proxy, maxBytes);
    }
    final t = timeout ?? _timeout;
    final limit = maxBytes ?? maxDownloadBytes;
    if (kIsWeb) {
      return downloadBytes(urlStr,
          headers: headers, proxy: proxy, timeout: t, maxBytes: limit);
    }
    final host = Uri.parse(urlStr).host;
    await RateLimiter.acquire(host, channel: RateChannel.asset);
    try {
      final client = clientForRequest(host, proxy: proxy);
      try {
        final req = await client
            .getUrl(Uri.parse(urlStr))
            .timeout(t);
        req.headers.set(HttpHeaders.userAgentHeader, defaultUA);
        req.headers.set(HttpHeaders.acceptHeader, '*/*');
        headers?.forEach((k, v) => req.headers.set(k, v));
        final res = await req.close().timeout(t);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          if (res.statusCode >= 500 || res.statusCode == 429) {
            rotateIpIndex(host);
          }
          final errBytes = await readLimited(res, limit, t);
          throw HttpStatusException(
              res.statusCode, utf8.decode(errBytes, allowMalformed: true));
        }
        final total = res.contentLength > 0 ? res.contentLength : null;
        final chunks = <int>[];
        var received = 0;
        await for (final chunk in res.timeout(t)) {
          received += chunk.length;
          if (received > limit) throw ResponseTooLargeException(limit);
          chunks.addAll(chunk);
          onProgress(received, total);
        }
        return chunks;
      } finally {
        client.close(force: true);
      }
    } finally {
      RateLimiter.release(host, channel: RateChannel.asset);
    }
  }

  /// 带镜像回退的 GET：按 [urls] 顺序逐个尝试，任一成功即返回其字节；
  /// 全部失败抛最后一个错误。
  ///
  /// 用途：raw.githubusercontent 等域名在某些网络（尤其国内）会被限速/超时，
  /// 但 jsDelivr 等 CDN 镜像可达。每个候选独立走 [_getBytesOnce]
  /// （各自 timeout），互不影响；首 URL 成功即短路，不浪费流量。
  /// 与 [_getBytesOnce] 一致，每个候选都受所在域名令牌桶限流。
  ///
  /// [totalTimeout]：整条镜像链的总预算。给定时，所有候选合计耗时不超过
  /// 该值——每个候选的实际超时取「min(自身 timeout, 剩余预算)」，到点即抛
  /// [TimeoutException]，避免 N 个候选各吃满 timeout 把调用方卡死
  /// （源市场/能力市场 5 个候选 × 12s = 最坏 60s，见 market_index_urls.dart）。
  static Future<List<int>> getBytesMirrors(List<String> urls,
      {Map<String, String>? headers,
      Duration? timeout,
      int? maxBytes,
      Duration? totalTimeout}) async {
    if (urls.isEmpty) throw ArgumentError('urls 不能为空');
    final deadline = totalTimeout == null
        ? null
        : DateTime.now().add(totalTimeout);
    Object? lastErr;
    for (final u in urls) {
      if (deadline != null &&
          DateTime.now().isAfter(deadline)) {
        throw TimeoutException('镜像链总预算 $totalTimeout 已耗尽', totalTimeout);
      }
      try {
        final per = Net.candidateBudget(timeout, deadline);
        return await _getBytesOnce(u, headers,
            proxy: null, timeout: per, maxBytes: maxBytes);
      } catch (e) {
        lastErr = e;
      }
    }
    if (lastErr is Exception) throw lastErr;
    throw StateError('镜像全部失败');
  }

  /// 单个候选的实际超时 = min(自身 timeout, 距总预算 deadline 的剩余时间)。
  /// 无总预算时返回原 timeout（兼容旧调用方）。
  /// 剩余时间为负/零（预算已耗尽）返回 null——由调用方在进入下一候选前抛
  /// TimeoutException 兜住，这里不抛是为了让纯函数可单测。
  @visibleForTesting
  static Duration? candidateBudget(
      Duration? timeout, DateTime? deadline, {DateTime? now}) {
    if (deadline == null) return timeout;
    final n = now ?? DateTime.now();
    final remaining = deadline.difference(n);
    if (remaining.isNegative || remaining == Duration.zero) return null;
    if (timeout == null) return remaining;
    return timeout < remaining ? timeout : remaining;
  }

  static Future<List<int>> _getBytesOnce(String urlStr,
      Map<String, String>? headers, {String? proxy, Duration? timeout, int? maxBytes}) async {
    final t = timeout ?? _timeout;
    final limit = maxBytes ?? maxDownloadBytes;
    // 限流：所有字节下载（图片/文件/无进度路径）统一经此基元，受
    // 静态资源令牌桶与并发槽位约束，避免高频图片加载绕过限流打爆源站。
    // 走 asset 通道（6 req/s、并发 6）：与同域 API 分桶，封面图不再把
    // 数据接口饿死，一屏 24 张封面也不再排队 6s+。
    final host = Uri.parse(urlStr).host;
    await RateLimiter.acquire(host, channel: RateChannel.asset);
    try {
      return await PlatformHttp.get(urlStr, headers, t, proxy, limit);
    } finally {
      RateLimiter.release(host, channel: RateChannel.asset);
    }
  }

  /// POST 请求，body 为表单/JSON 字符串，返回响应体字符串（UTF-8）。
  /// [proxy] 为单源代理覆盖：null=走全局代理/直连；''=强制直连；其余=强制走该代理。
  static Future<String> post(String urlStr,
      {Map<String, String>? headers, String? body, String? proxy, int? maxBytes}) async {
    if (proxy == null) {
      return _postOnce(urlStr, headers, body, proxy: null, maxBytes: maxBytes);
    }
    try {
      return await _postOnce(urlStr, headers, body, proxy: proxy, maxBytes: maxBytes);
    } catch (e) {
      // 单源代理连接失败自动回退直连；强制直连（proxy=''）无需再回退
      if (proxy.isEmpty || !_retryable(e)) rethrow;
      return _postOnce(urlStr, headers, body, proxy: '', maxBytes: maxBytes);
    }
  }

  static Future<String> _postOnce(String urlStr,
      Map<String, String>? headers, String? body,
      {String? proxy, Duration? timeout, int? maxBytes}) async {
    final t = timeout ?? _timeout;
    final limit = maxBytes ?? maxTextBytes;
    // 限流：POST 同样受每域名令牌桶约束
    final host = Uri.parse(urlStr).host;
    await RateLimiter.acquire(host);
    try {
      final bytes = await PlatformHttp.post(urlStr, headers, body, t, proxy, limit);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      RateLimiter.release(host);
    }
  }

  /// 拼接 query 参数（值经 [Uri.encodeQueryComponent] 编码，支持 CJK/特殊字符）。
  static String buildUrl(String base, Map<String, String> params) {
    if (params.isEmpty) return base;
    final uri = Uri.parse(base);
    final merged = Map<String, String>.from(uri.queryParameters);
    params.forEach((k, v) => merged[k] = v);
    return uri.replace(queryParameters: merged).toString();
  }
}
