import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../net/circuit_breaker.dart';
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
/// - 失败时抛 [Exception]（携带结构化错误信息），兼容现有源 try/catch 与 UI 错误态。
class SourceHttp {
  /// 读取某源的第一个可用 host（无配置/为空时回退 [fallback]）。
  static Future<String> pickHost(String engineId, List<String> fallback) async {
    final hosts = await SourceConfigStore.hostsFor(engineId, fallback);
    return hosts.isNotEmpty
        ? hosts.first
        : (fallback.isNotEmpty ? fallback.first : '');
  }

  /// GET：host 由配置决定，path 拼接在 host 之后。
  static Future<String> get(
    String engineId,
    String path, {
    List<String> fallbackHosts = const [],
    Map<String, String>? headers,
  }) async {
    return _unwrap(await withCircuit(engineId, () => withTransientRetry(() async {
      final host = await pickHost(engineId, fallbackHosts);
      return Net.get('$host$path', headers: headers);
    })));
  }

  /// POST：host 由配置决定，path 拼接在 host 之后。
  static Future<String> post(
    String engineId,
    String path, {
    List<String> fallbackHosts = const [],
    Map<String, String>? headers,
    String? body,
  }) async {
    return _unwrap(await withCircuit(engineId, () => withTransientRetry(() async {
      final host = await pickHost(engineId, fallbackHosts);
      return Net.post('$host$path', headers: headers, body: body);
    })));
  }

  /// GET 完整 URL（已拼好 host + 查询串的场景）。
  static Future<String> getUrl(
    String engineId,
    String url, {
    Map<String, String>? headers,
  }) async {
    return _unwrap(
        await withCircuit(engineId, () => withTransientRetry(() => Net.get(url, headers: headers))));
  }

  /// POST 完整 URL。
  static Future<String> postUrl(
    String engineId,
    String url, {
    Map<String, String>? headers,
    String? body,
  }) async {
    return _unwrap(await withCircuit(
        engineId, () => withTransientRetry(() => Net.post(url, headers: headers, body: body))));
  }

  /// GET 字节（图片等），带熔断。
  static Future<Uint8List> getBytes(
    String engineId,
    String url, {
    Map<String, String>? headers,
  }) async {
    return _unwrap(await withCircuit(engineId, () => withTransientRetry(() async {
      final b = await Net.getBytes(url, headers: headers);
      return Uint8List.fromList(b);
    })));
  }

  static T _unwrap<T>(SourceResult<T> r) {
    if (r is SourceOk<T>) return r.data;
    if (r is SourceErr<T>) throw Exception(r.error.toString());
    throw Exception('数据为空');
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
