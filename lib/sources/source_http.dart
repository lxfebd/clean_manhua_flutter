import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../net/circuit_breaker.dart';
import '../net/error_logger.dart';
import '../net/http_client.dart';
import 'source_config.dart';
import 'source_result.dart';

/// 带「配置 + 熔断 + 瞬时失败重试」的源 HTTP 助手（对齐 Ani 的声明式配置 + Mangayomi 的源调用流）。
///
/// - host 从 [SourceConfigStore] 读取（用户/远程可覆盖，免发版换域名）；
/// - 请求自动包一层 [withCircuit] 熔断：源连续失败进入冷却，不再反复无效请求拖垮整页；
/// - 网络层瞬时失败（连接被重置/超时/CDN 5xx/429）自动重试一次，再判失败，
///   避免"时通时断"的源（如 xbiquge）偶发超时直接判失败影响整页体验；
///   拿到响应后的解析错误不会重试。
/// - 失败时抛类型化 [SourceError]（[SourceNetwork]/[SourceService]/[SourceParse]…），
///   UI 按具体子类型给出可操作反馈。
class SourceHttp {
  /// 读取某源的第一个可用 host（无配置/为空时回退 [fallback]）。
  static Future<String> pickHost(String engineId, List<String> fallback) async {
    final hosts = await SourceConfigStore.hostsFor(engineId, fallback);
    return hosts.isNotEmpty
        ? hosts.first
        : (fallback.isNotEmpty ? fallback.first : '');
  }

  /// 读取某源的代理配置（单源代理覆盖全局）；未配置返回 null。
  static Future<String?> proxyFor(String engineId) async {
    final c = await SourceConfigStore.byEngine(engineId);
    if (c == null) return null;
    final p = c.proxy?.trim() ?? '';
    return p.isEmpty ? null : p;
  }

  /// 是否值得换下一个 host 重试（P1-07）。纯函数，便于单测。
  ///
  /// 只有「这个 host 侧的问题」才换：连接层/超时（network）、5xx/429
  /// （service 里除 404/401/403 之外的部分）。
  /// 404/401/403 **不换**——那是 path 或凭据的问题，换 host 只是把同样的
  /// 404 再打一遍、还多耗一次源站配额；解析失败也不换（页面拿到了，是
  /// 选择器失效，换域名治不好）。unauthorized/blocked/unknown 一律不换。
  @visibleForTesting
  static bool shouldTryNextHost(Object e) {
    if (e is SourceNetwork) return true;
    if (e is SourceService) {
      // 用结构化 statusCode 判断，不靠 message 字符串匹配（P2-15 审计修复）：
      // HttpStatusException 不是 HttpException，早前所有状态错误都落进
           // unknown，这里的 message 匹配于是形同虚设。
      final code = e.statusCode;
      if (code == null) return false; // 业务错误（未配置规则等）与 host 无关
      if (code == 404 || code == 401 || code == 403) return false;
      // 5xx / 429 / 其它：换下一个 host 有意义。
      return code >= 500 || code == 429;
    }
    return false;
  }

  /// 在「一个总预算」内按 host 列表逐个尝试：只有应该换 host 的失败
  /// （见 [shouldTryNextHost]）才继续下一个，其余立即抛。
  ///
  /// 熔断键细化到 `engineId|host`——旧实现整个源共用一个熔断器，A 域名挂
  /// 会把 B 域名一起冷却掉，而 B 本来是好的。
  static Future<T> _acrossHosts<T>(
    String engineId,
    List<String> hosts,
    Future<T> Function(String host) attempt,
  ) async {
    if (hosts.isEmpty) {
      throw SourceError.network('没有可用的 host 配置');
    }
    Object? last;
    for (var i = 0; i < hosts.length; i++) {
      final host = hosts[i];
      try {
        return await withCircuit(
            '$engineId|$host', () => withTransientRetry(() => attempt(host)));
      } catch (e) {
        last = e;
        final isLast = i >= hosts.length - 1;
        if (isLast || !shouldTryNextHost(e)) rethrow;
        // 换下一个 host：不再退避（第一个 host 已经耗过一次瞬时重试的预算）。
        ErrorLogger.instance.warn(
            'source_http: $engineId host=$host 失败，切换到下一个 host（$e）');
      }
    }
    throw last ?? SourceError.unknown('unreachable');
  }

  /// GET：host 由配置决定，path 拼接在 host 之后。
  ///
  /// 重试层收敛：本层 [withTransientRetry] 已负责瞬时失败重试，
  /// 故 [Net.get] 传 `retry: false`（P0-2：此前两层各自重试 →
  /// 单个 GET 最坏 4 次真实请求）。
  /// P1-07：host 列表逐个尝试（旧的 pickHost 永远只取第一个，配了镜像也白配）。
  static Future<String> get(
    String engineId,
    String path, {
    List<String> fallbackHosts = const [],
    Map<String, String>? headers,
  }) async {
    final hosts = await SourceConfigStore.hostsFor(engineId, fallbackHosts);
    final proxy = await proxyFor(engineId);
    return _acrossHosts(engineId, hosts, (host) {
      return Net.get('$host$path',
          headers: headers, proxy: proxy, retry: false);
    });
  }

  /// POST：host 由配置决定，path 拼接在 host 之后。
  static Future<String> post(
    String engineId,
    String path, {
    List<String> fallbackHosts = const [],
    Map<String, String>? headers,
    String? body,
  }) async {
    final hosts = await SourceConfigStore.hostsFor(engineId, fallbackHosts);
    final proxy = await proxyFor(engineId);
    return _acrossHosts(engineId, hosts, (host) {
      return Net.post('$host$path',
          headers: headers, body: body, proxy: proxy);
    });
  }

  /// GET 完整 URL（已拼好 host + 查询串的场景）。
  ///
  /// 同 [get]：重试由本层承担，[Net.get] 关掉内建重试，避免叠两层。
  static Future<String> getUrl(
    String engineId,
    String url, {
    Map<String, String>? headers,
  }) async {
    return withCircuit(
        engineId,
        () => withTransientRetry(() async => Net.get(url,
            headers: headers,
            proxy: await proxyFor(engineId),
            retry: false)));
  }

  /// POST 完整 URL。
  static Future<String> postUrl(
    String engineId,
    String url, {
    Map<String, String>? headers,
    String? body,
  }) async {
    return withCircuit(engineId,
        () => withTransientRetry(() async => Net.post(url,
            headers: headers, body: body, proxy: await proxyFor(engineId))));
  }

  /// 网络瞬时失败的最大尝试次数（1 次初始 + 1 次重试）。
  static const int maxAttempts = 2;

  /// 瞬时失败自动重试：连接层异常 / 超时 / HTTP 5xx / 429 会退避后重试，
  /// 其余错误（含拿到响应后的解析错误）立即抛出。暴露给测试验证。
  @visibleForTesting
  static Future<T> withTransientRetry<T>(Future<T> Function() fn) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await fn();
      } catch (e) {
        final isLast = attempt >= maxAttempts;
        if (isLast || !_isTransient(e)) rethrow;
        // 短暂退避后重试（300ms 起），给源站抖动一个自愈窗口
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
    throw StateError('unreachable');
  }

  /// 是否为可重试的瞬时错误：连接层异常（[IOException] 含 Socket/Http/Handshake）、
  /// 超时，以及 Net 抛出的 HTTP 5xx / 429 错误。
  static bool _isTransient(Object e) {
    if (e is IOException || e is TimeoutException) return true;
    final s = e.toString();
    return s.contains('HTTP 5') || s.contains('HTTP 429');
  }
}
