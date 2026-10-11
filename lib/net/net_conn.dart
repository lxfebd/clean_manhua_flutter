import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 带状态码的 HTTP 异常：让重试逻辑能区分 5xx/429（可重试）与 4xx（不可重试）。
class HttpStatusException implements Exception {
  final int statusCode;
  final String body;
  HttpStatusException(this.statusCode, this.body);
  @override
  String toString() => 'HTTP $statusCode: $body';
}

/// 响应体超过字节上限（[NetConn.maxTextBytes]/[NetConn.maxDownloadBytes] 或调用方覆盖值）。
/// 属确定性失败，不再重试：源头是超大/异常响应，重拉只会再次超限。
class ResponseTooLargeException implements Exception {
  final int limitBytes;
  ResponseTooLargeException(this.limitBytes);
  @override
  String toString() => '响应体超过上限（$limitBytes 字节），已拒绝读取';
}

/// 连接与读取原语库：HTTP「线上」层（[PlatformHttp] 的 io/web 实现）直接依赖这里，
/// 而不是反向 import 编排层 [Net]（P0-2 审计项：平台层向编排层反向借实现形成循环 import）。
///
/// 本库**零应用层依赖**（只 import `dart:io`/`dart:async`），因此可以安全地被
/// 平台层与编排层同时依赖，不产生新环。持久化（读 LocalStore）留在调用方 `Net`。
///
/// 这里只放**与编排无关**的东西：常量、dart:io 连接构造（代理 / 优选 IP /
/// 信任自签）、响应体分块读取上限、优选 IP 轮换下标。
/// 重试 / Cronet 回退 / 限流等编排逻辑仍留在 `http_client.dart` 的 `Net`。
///
/// `Net` 对以下成员保留同名转发，外部调用点无需改动。
class NetConn {
  NetConn._();

  /// 默认请求超时。
  static const Duration timeout = Duration(seconds: 15);

  /// 单个候选 IP 的连接超时（用于优选 IP 轮询/自愈）。
  /// 比总超时更短，避免全部 IP 不可达时长时间挂起。
  static const Duration ipTryTimeout = Duration(seconds: 6);

  /// 文本类请求响应体字节上限。
  /// 与 [html_parser.kDefaultMaxHtmlBytes]（8MB）对齐：parse 前的网络层就收口，
  /// 恶意/异常超大的页面在拉满内存前被拦截。
  static const int maxTextBytes = 8 * 1024 * 1024;

  /// 字节类下载的响应体上限。图片/超分单张远小于此；最大场景——能力权重(225MB)
  /// ——也放行。需要更大体量或更紧约束的调用点用 `maxBytes` 显式覆盖。
  static const int maxDownloadBytes = 256 * 1024 * 1024;

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
    // lain.bgm.tv（Bangumi 图片 CDN，Cloudflare 托管）：部分网络下系统 DNS
    // 被污染解析到 Facebook 段 IP 导致封面加载超时；直连真实 Cloudflare 节点
    // IP + SNI（host=lain.bgm.tv）绕过 DNS 污染。真实 IP 由 doh.pub 解析所得。
    'lain.bgm.tv': [
      '104.26.8.23',
      '104.26.9.23',
      '172.67.73.67',
    ],
  };

  /// 全局代理（`http://host:port` / `https://host:port`；dart:io 不支持
  /// socks，socks5/socks4 前缀会被明确拒绝为直连）。
  /// 空串/null 表示直连。仅对 dart:io 路径生效；配置代理后 Cronet 路径自动跳过
  /// （Cronet 默认引擎不读代理配置，避免 Android 上代理被绕过）。
  static String? proxy;

  /// 是否全局代理已启用（避免每次请求都解析字符串）。
  static bool _proxyEnabled = false;
  static String? _effectiveProxy;

  /// 是否信任自签证书（默认 false）。开启后 [clientForRequest] 与优选 IP 直连
  /// 的 `onBadCertificate` 放行，用于兼容自签 HTTPS 的源/家庭 NAS/自建服务器。
  /// 由设置页「信任自签证书」开关控制，[restoreTrustSelfSigned] 启动时恢复。
  static bool trustSelfSigned = false;

  /// 当前域名已尝试到的候选 IP 下标，失败时轮询切换。
  static final Map<String, int> _ipIndex = {};

  /// 当前是否启用了全局代理。
  static bool get proxyEnabled => _proxyEnabled;

  /// findProxy 用的 PAC 指令；未启用代理返回 null。
  static String? get proxyDirective => _effectiveProxy;

  /// 将代理解析为 dart:io findProxy 返回的 PAC 风格指令；null 表示直连。
  /// 仅支持 host:port（不带 scheme）时按 http 代理处理。
  ///
  /// **不支持 socks**：dart:io HttpClient 的 findProxy 只认 `PROXY` 与
  /// `DIRECT` 两个前缀（http_impl._ProxyConfiguration），没有 socks 客户端。
  /// socks5/socks5h/socks4 配置在此明确拒绝（返回 null 直连）——曾经产出
  /// `SOCKS5 host:port` 非法指令会让 dart:io 抛 `Invalid proxy configuration`，
  /// 所有代理请求直接炸；拒绝并保持直连是诚实且可预期的行为（纯 socks
  /// 端口用户会得到直连而非错误，UI 文案已说明改用 http://）。
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
      case 'socks4':
        return null; // dart:io 不支持 socks，明确拒绝（直连）
      default:
        return 'PROXY $rest';
    }
  }

  static void applyProxy() {
    _effectiveProxy = _proxyDirective(proxy);
    _proxyEnabled = _effectiveProxy != null;
  }

  /// 解析单次请求应使用的代理 PAC 指令（@visibleForTesting 抽出，便于离线
  /// 断言优先级语义）：单源代理（[proxy] 非 null 且非空）> 全局代理
  /// （[_effectiveProxy]）；空串表示显式直连（压过全局代理）。返回 null 直连。
  ///
  /// 注意解析只在**原始字符串**上做一次：[_effectiveProxy] 由 [applyProxy]
  /// 预先经 [_proxyDirective] 解析为最终 PAC 指令（如 `PROXY host:port`），
  /// 回退全局路径直接使用，不得二次解析（否则 `PROXY host:port` 会被
  /// 当成裸地址再裹一层 `PROXY`，全局代理从未正确生效）。
  @visibleForTesting
  static String? resolveProxyDirective(String? proxy) {
    if (proxy == null) return _effectiveProxy;
    // 单源代理为空串 = 显式直连，压过全局代理
    if (proxy.trim().isEmpty) return null;
    // 单源代理是用户原始配置（含 scheme），需解析为 PAC 指令
    return _proxyDirective(proxy);
  }

  /// 构造 HttpClient；若该 host 配置了优选 IP，则通过 connectionFactory 强制直连。
  /// 优选 IP 全部失败时，自动回退到系统 DNS 解析，避免整源因写死 IP 失效而挂死。
  /// 代理启用时优先走代理（findProxy 自动处理 CONNECT 隧道），
  /// 与 connectionFactory 互斥——代理模式下不设 connectionFactory。
  /// 供 platform_http_io.dart 复用同一套连接策略（代理/优选 IP）。
  static HttpClient clientForRequest(String host, {String? proxy}) {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false;
    // 默认校验证书（防 MITM）；仅用户显式开启「信任自签」才放行
    if (trustSelfSigned) {
      client.badCertificateCallback = (cert, h, port) => true;
    }
    // 单源代理（proxy != null 且非空）> 全局代理（_effectiveProxy）；空串表示直连
    final directive = resolveProxyDirective(proxy);
    if (directive != null) {
      client.findProxy = (url) => directive;
      return client;
    }
    final ips = preferredHostIps[host];
    if (ips != null && ips.isNotEmpty) {
      // 逻辑见 connectionTask（@visibleForTesting 抽出以便离线断言 socket
      // 生命周期）：逐个候选 IP 尝试，失败销毁 socket，全失败回退系统 DNS。
      client.connectionFactory = (url, proxyHost, proxyPort) =>
          connectionTask(url, host, proxyHost, proxyPort);
    }
    return client;
  }

  /// 供 platform_http_io 在收到 5xx/429 后轮换候选 IP：返回下一个应尝试的下标。
  static int rotateIpIndex(String host) {
    final ips = preferredHostIps[host];
    if (ips == null || ips.isEmpty) return 0;
    final cur = _ipIndex[host] ?? 0;
    final next = (cur + 1) % ips.length;
    _ipIndex[host] = next;
    return next;
  }

  /// 优选 IP 直连任务（从 connectionFactory 闭包抽出，便于离线驱动失败分支
  /// 断言 socket 生命周期）。默认使用真实 dart:io 连接；测试通过
  /// [connectFn]/[secureFn] 注入 fake 记录 destroy 调用。
  /// 语义与旧闭包完全一致：逐个候选 IP 尝试 TLS 握手，失败销毁该 socket 并
  /// 换下一个；全部失败回退系统 DNS（[resolveAndConnectDirect]）。
  @visibleForTesting
  static Future<ConnectionTask<Socket>> connectionTask(
    Uri url,
    String host,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final ips = preferredHostIps[host];
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    if (ips == null || ips.isEmpty) {
      return resolveAndConnectDirect(url, host, port);
    }
    // 依次尝试每个候选 IP
    for (int attempt = 0; attempt < ips.length; attempt++) {
      final idx = ((_ipIndex[host] ?? 0) + attempt) % ips.length;
      final ip = ips[idx];
      Socket? opened;
      try {
        opened = await connectFn(ip, port, ipTryTimeout);
        final secure = await secureFn(opened, url.host,
            trustSelfSigned ? (_) => true : null);
        return ConnectionTask.fromSocket<Socket>(Future.value(secure), () {});
      } catch (_) {
        // TLS 握手失败时 raw socket 仍归本方所有：不关就是泄漏
        // （每请求最多泄漏 ips.length 个 socket，移动端 fd 有限）。
        opened?.destroy();
        // 该 IP 不可用，尝试下一个
      }
    }
    // 全部优选 IP 失败 → 回退系统 DNS
    return resolveAndConnectDirect(url, host, port);
  }

  /// 系统 DNS 直连任务（优选 IP 全失败的回退路径）。
  @visibleForTesting
  static Future<ConnectionTask<Socket>> resolveAndConnectDirect(
    Uri url,
    String host,
    int port,
  ) async {
    final addr = (await InternetAddress.lookup(url.host)).first;
    final socket = await connectFn(addr.address, port, ipTryTimeout);
    try {
      final secure = await secureFn(socket, url.host,
          trustSelfSigned ? (_) => true : null);
      return ConnectionTask.fromSocket<Socket>(Future.value(secure), () {});
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// socket 创建注入点（仅测试）：默认即真实 [Socket.connect]。
  @visibleForTesting
  static Future<Socket> Function(String host, int port, Duration timeout)
      connectFn = _defaultConnect;

  /// TLS 握手注入点（仅测试）：默认即真实 [SecureSocket.secure]。
  @visibleForTesting
  static Future<Socket> Function(
    Socket raw,
    String host,
    bool Function(X509Certificate)? onBadCertificate,
  ) secureFn = _defaultSecure;

  /// 恢复注入点为默认实现（测试 tearDown 用，避免跨用例状态污染）。
  @visibleForTesting
  static void resetConnectionOverrides() {
    connectFn = _defaultConnect;
    secureFn = _defaultSecure;
  }

  static Future<Socket> _defaultConnect(
          String host, int port, Duration timeout) =>
      Socket.connect(host, port, timeout: timeout);

  static Future<Socket> _defaultSecure(
    Socket raw,
    String host,
    bool Function(X509Certificate)? onBadCertificate,
  ) =>
      SecureSocket.secure(raw,
          host: host, onBadCertificate: onBadCertificate);

  /// 分块读取响应流，达到 [limit] 立即抛 [ResponseTooLargeException] 并
  /// 停止消费（不拉满内存）；[t] 为**整体读取超时**（与旧
  /// `stream.toBytes().timeout(t)` 语义一致——不用 `stream.timeout`：
  /// Stream 级间隙超时在 FakeAsync 测试环境里不触发，会让请求悬挂、
  /// 骨架屏动画永动导致 pumpAndSettle 超时）。任何出口（完成/超限/超时/
  /// 上游错误）都会**取消上游订阅**：若超时只放弃 Future 结果而订阅还活着
  /// （悬挂/慢速响应），幽灵订阅会继续把后续数据读进内存直至响应体结束
  /// ——正是 socket 泄漏测试防的那类。供 platform_http_io/web
  /// 复用的同一份实现，保证三条线上路径的上限语义一致。
  static Future<List<int>> readLimited(
      Stream<List<int>> stream, int limit, Duration t) {
    final chunks = <int>[];
    var total = 0;
    final done = Completer<List<int>>();
    late final StreamSubscription<List<int>> sub;
    sub = stream.listen(
      (chunk) {
        total += chunk.length;
        if (total > limit) {
          // 超限即终止：先取消订阅再报错，后续块不再消费。
          sub.cancel();
          if (!done.isCompleted) {
            done.completeError(ResponseTooLargeException(limit));
          }
          return;
        }
        chunks.addAll(chunk); // 收齐所有块后由 onDone 完成
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(chunks);
      },
    );
    return done.future.timeout(t).whenComplete(sub.cancel);
  }
}
