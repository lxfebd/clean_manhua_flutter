import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'http_client.dart' show Net, HttpStatusException;

/// io 端线上实现：真实 dart:io HttpClient（含代理 / 优选 IP connectionFactory /
/// gzip 解压），构造逻辑复用 [Net._client]（不重复实现代理与优选 IP）。
/// 语义与旧 `Net._getOnce/_postOnce` 完全一致，编排层（重试/回退）仍在 [Net]。
class PlatformHttp {
  /// 单次 GET：返回字节。非 2xx 抛 [HttpStatusException]。
  static Future<List<int>> get(
    String urlStr,
    Map<String, String>? headers,
    Duration timeout,
    String? proxy,
  ) async {
    final client =
        IOClient(Net.clientForRequest(Uri.parse(urlStr).host, proxy: proxy));
    try {
      final req = http.Request('GET', Uri.parse(urlStr));
      _applyHeaders(req, headers);
      final res = await client.send(req).timeout(timeout);
      return await _readBytes(res, timeout, urlStr);
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
    final client =
        IOClient(Net.clientForRequest(Uri.parse(urlStr).host, proxy: proxy));
    try {
      final req = http.Request('POST', Uri.parse(urlStr));
      _applyHeaders(req, headers);
      if (body != null) req.bodyBytes = utf8.encode(body);
      final res = await client.send(req).timeout(timeout);
      return await _readBytes(res, timeout, urlStr);
    } finally {
      client.close();
    }
  }

  /// 当前是否配置了任何代理（全局或单源）；web 端恒 false，io 端透传。
  static bool get proxyConfigured => Net.proxyEnabled;

  static void _applyHeaders(http.Request req, Map<String, String>? headers) {
    req.headers['User-Agent'] = Net.defaultUA;
    req.headers['Accept'] = '*/*';
    final h = <String, String>{...?headers};
    if (req.method == 'POST' &&
        (h['Content-Type'] ?? '').isNotEmpty &&
        !h['Content-Type']!.toLowerCase().contains('charset')) {
      h['Content-Type'] = '${h['Content-Type']}; charset=utf-8';
    }
    h.forEach((k, v) => req.headers[k] = v);
  }

  /// 读取响应字节，自动处理 gzip/deflate 压缩（与旧 [Net._readBytes] 一致）；
  /// 非 2xx 时顺带做优选 IP 轮换（与旧 [Net._onDone] 一致）。
  static Future<List<int>> _readBytes(
      http.StreamedResponse res, Duration t, String urlStr) async {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // 服务器错误/限流 → 切换下一个候选 IP（避免反复打到故障节点）
      if (res.statusCode >= 500 || res.statusCode == 429) {
        Net.rotateIpIndex(Uri.parse(urlStr).host);
      }
      final errBytes = await res.stream.toBytes().timeout(t);
      throw HttpStatusException(
          res.statusCode, utf8.decode(errBytes, allowMalformed: true));
    }
    final enc = res.headers['content-encoding'] ?? '';
    final bytes = await res.stream.toBytes().timeout(t);
    if (enc.contains('gzip')) {
      return gzip.decode(bytes);
    }
    if (enc.contains('deflate')) {
      return zlib.decode(bytes);
    }
    return bytes;
  }
}