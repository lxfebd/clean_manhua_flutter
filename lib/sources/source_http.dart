import 'dart:typed_data';

import '../net/circuit_breaker.dart';
import '../net/http_client.dart';
import 'source_config.dart';
import 'source_result.dart';

/// 带「配置 + 熔断」的源 HTTP 助手（对齐 Ani 的声明式配置 + Mangayomi 的源调用流）。
///
/// - host 从 [SourceConfigStore] 读取（用户/远程可覆盖，免发版换域名）；
/// - 请求自动包一层 [withCircuit] 熔断：源连续失败进入冷却，不再反复无效请求拖垮整页；
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
    return _unwrap(await withCircuit(engineId, () async {
      final host = await pickHost(engineId, fallbackHosts);
      return Net.get('$host$path', headers: headers);
    }));
  }

  /// POST：host 由配置决定，path 拼接在 host 之后。
  static Future<String> post(
    String engineId,
    String path, {
    List<String> fallbackHosts = const [],
    Map<String, String>? headers,
    String? body,
  }) async {
    return _unwrap(await withCircuit(engineId, () async {
      final host = await pickHost(engineId, fallbackHosts);
      return Net.post('$host$path', headers: headers, body: body);
    }));
  }

  /// GET 完整 URL（已拼好 host + 查询串的场景）。
  static Future<String> getUrl(
    String engineId,
    String url, {
    Map<String, String>? headers,
  }) async {
    return _unwrap(
        await withCircuit(engineId, () => Net.get(url, headers: headers)));
  }

  /// POST 完整 URL。
  static Future<String> postUrl(
    String engineId,
    String url, {
    Map<String, String>? headers,
    String? body,
  }) async {
    return _unwrap(await withCircuit(
        engineId, () => Net.post(url, headers: headers, body: body)));
  }

  /// GET 字节（图片等），带熔断。
  static Future<Uint8List> getBytes(
    String engineId,
    String url, {
    Map<String, String>? headers,
  }) async {
    return _unwrap(await withCircuit(engineId, () async {
      final b = await Net.getBytes(url, headers: headers);
      return Uint8List.fromList(b);
    }));
  }

  static T _unwrap<T>(SourceResult<T> r) {
    if (r is SourceOk<T>) return r.data;
    if (r is SourceErr<T>) throw Exception(r.error.toString());
    throw Exception('数据为空');
  }
}
