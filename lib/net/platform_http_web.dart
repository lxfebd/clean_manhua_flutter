import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';

import 'http_client.dart' show HttpStatusException;

/// web 端线上实现：浏览器 fetch（BrowserClient）自动处理 CORS / gzip /
/// 同源 cookie。无代理概念（代理只在 io 端有意义），优选 IP 不适用。
/// 超时通过 [Abortable] 触发 AbortController 真正中断请求。
class PlatformHttp {
  static http.Client _newClient() {
    final c = BrowserClient()..withCredentials = false;
    return c;
  }

  /// 单次 GET：返回字节。非 2xx 抛 [HttpStatusException]。
  static Future<List<int>> get(
    String urlStr,
    Map<String, String>? headers,
    Duration timeout,
    String? proxy,
  ) async {
    final client = _newClient();
    try {
      final req = http.Request('GET', Uri.parse(urlStr));
      _applyHeaders(req, headers);
      final res = await _sendWithTimeout(client, req, timeout);
      return await _readBytes(res, timeout);
    } finally {
      client.close();
    }
  }

  /// 单次 POST：body 为 UTF-8 字符串，返回字节。
  static Future<List<int>> post(
    String urlStr,
    Map<String, String>? headers,
    String? body,
    Duration timeout,
    String? proxy,
  ) async {
    final client = _newClient();
    try {
      final req = http.Request('POST', Uri.parse(urlStr));
      _applyHeaders(req, headers);
      if (body != null) req.bodyBytes = utf8.encode(body);
      final res = await _sendWithTimeout(client, req, timeout);
      return await _readBytes(res, timeout);
    } finally {
      client.close();
    }
  }

  /// web 无代理概念；统一由调用方判断（PlatformHttp.proxyConfigured 恒 false）。
  static bool get proxyConfigured => false;

  static Future<http.StreamedResponse> _sendWithTimeout(
      http.Client client, http.Request req, Duration timeout) async {
    return client.send(req).timeout(timeout);
  }

  static void _applyHeaders(http.Request req, Map<String, String>? headers) {
    req.headers['Accept'] = '*/*';
    // 浏览器禁止覆盖 UA / Accept-Encoding，此处仅注入应用层头。
    headers?.forEach((k, v) {
      final key = k.toLowerCase();
      if (key == 'user-agent' || key == 'accept-encoding' ||
          key == 'content-length' || key == 'host') {
        return;
      }
      req.headers[k] = v;
    });
  }

  /// 读取响应字节。fetch 已自动解压，无需手动 gzip。
  static Future<List<int>> _readBytes(
      http.StreamedResponse res, Duration t) async {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final errBytes = await res.stream.toBytes().timeout(t);
      throw HttpStatusException(
          res.statusCode, utf8.decode(errBytes, allowMalformed: true));
    }
    return res.stream.toBytes().timeout(t);
  }
}