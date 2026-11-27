import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

// 只依赖连接/读取原语库（P0-2：此前反向 import 编排层 http_client.dart 借
// Net.clientForRequest/readLimited，形成 platform_http_io → http_client 的
// 循环 import；原语下沉 NetConn 后，平台层不再依赖编排层）。
import '../utils/compression_guard.dart';
import 'net_conn.dart' show NetConn, HttpStatusException, ResponseTooLargeException;
import 'net_guard.dart';

/// io 端线上实现：真实 dart:io HttpClient（含代理 / 优选 IP connectionFactory /
/// gzip 解压），构造逻辑复用 [NetConn.clientForRequest]（不重复实现代理与优选 IP）。
/// 语义与旧 `Net._getOnce/_postOnce` 完全一致，编排层（重试/回退）仍在 Net。
class PlatformHttp {
  /// 单次 GET：返回字节。非 2xx 抛 [HttpStatusException]。
  /// [maxBytes] 为响应体字节上限（默认由调用方 Net 层确定）。
  static Future<List<int>> get(
    String urlStr,
    Map<String, String>? headers,
    Duration timeout,
    String? proxy,
    int maxBytes,
  ) async {
    final client = IOClient(
        NetConn.clientForRequest(Uri.parse(urlStr).host, proxy: proxy));
    try {
      // P1-04：重定向逐跳校验。
      //
      // dart:io 的 HttpClient 默认自动跟随重定向，跳转目标由**服务端**决定，
      // 所以只校验入口 URL 是拦不住 `Location: http://192.168.1.1/admin`
      // 这类攻击的。这里关掉自动跟随，自己逐跳校验后再跳——每一跳都过护栏。
      final res = await _sendFollowingRedirects(
        client, http.Request('GET', Uri.parse(urlStr)), headers, timeout,
      );
      return await _readBytes(res, timeout, urlStr, maxBytes);
    } finally {
      client.close();
    }
  }

  /// 手动跟随重定向，**每一跳都过 [NetGuard]**。
  ///
  /// 最多 5 跳（与浏览器/curl 的常见上限一致），超出视为异常重定向循环。
  static Future<http.StreamedResponse> _sendFollowingRedirects(
    http.Client client,
    http.Request req,
    Map<String, String>? headers,
    Duration timeout,
  ) async {
    var current = req;
    // http 包自己的 followRedirects 也要关掉，否则 package:http 会绕过
    // 我们的逐跳校验直接跟随（它默认是 true）。
    current.followRedirects = false;
    for (var hop = 0; hop < 5; hop++) {
      _applyHeaders(current, headers);
      final res = await client.send(current).timeout(timeout);
      final code = res.statusCode;
      final isRedirect = code == 301 || code == 302 || code == 303 ||
          code == 307 || code == 308;
      if (!isRedirect) return res;

      final loc = res.headers['location'];
      if (loc == null || loc.isEmpty) return res;
      // 排空当前响应，避免连接泄漏
      await res.stream.drain<void>();
      final next = current.url.resolve(loc);
      // 每一跳都校验（含 DNS 解析）
      final guard = await NetGuard.resolveAndCheck(next.toString());
      if (!guard.allowed) {
        throw NetGuardViolation(guard.violation!.reason, url: next.toString());
      }
      current = http.Request(current.method, next);
    }
    throw NetGuardViolation('重定向次数过多（>5），已停止跟随',
        url: req.url.toString());
  }

  /// 单次 POST：body 为 UTF-8 字符串，返回字节。
  static Future<List<int>> post(
    String urlStr,
    Map<String, String>? headers,
    String? body,
    Duration timeout,
    String? proxy,
    int maxBytes,
  ) async {
    final client = IOClient(
        NetConn.clientForRequest(Uri.parse(urlStr).host, proxy: proxy));
    try {
      final req = http.Request('POST', Uri.parse(urlStr));
      _applyHeaders(req, headers);
      if (body != null) req.bodyBytes = utf8.encode(body);
      final res = await client.send(req).timeout(timeout);
      return await _readBytes(res, timeout, urlStr, maxBytes);
    } finally {
      client.close();
    }
  }

  /// 当前是否配置了任何代理（全局或单源）；web 端恒 false，io 端透传。
  static bool get proxyConfigured => NetConn.proxyEnabled;

  static void _applyHeaders(http.Request req, Map<String, String>? headers) {
    req.headers['User-Agent'] = NetConn.defaultUA;
    req.headers['Accept'] = '*/*';
    final h = <String, String>{...?headers};
    if (req.method == 'POST' &&
        (h['Content-Type'] ?? '').isNotEmpty &&
        !h['Content-Type']!.toLowerCase().contains('charset')) {
      h['Content-Type'] = '${h['Content-Type']}; charset=utf-8';
    }
    h.forEach((k, v) => req.headers[k] = v);
  }

  /// 读取响应字节，自动处理 gzip/deflate 压缩（与旧实现一致）；
  /// 非 2xx 时顺带做优选 IP 轮换。
  /// [maxBytes] 为响应体字节上限：分块累计，超过即抛 [ResponseTooLargeException]。
  static Future<List<int>> _readBytes(
      http.StreamedResponse res, Duration t, String urlStr, int maxBytes) async {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // 服务器错误/限流 → 切换下一个候选 IP（避免反复打到故障节点）
      if (res.statusCode >= 500 || res.statusCode == 429) {
        NetConn.rotateIpIndex(Uri.parse(urlStr).host);
      }
      final errBytes = await NetConn.readLimited(res.stream, maxBytes, t);
      throw HttpStatusException(
          res.statusCode, utf8.decode(errBytes, allowMalformed: true));
    }
    final enc = res.headers['content-encoding'] ?? '';
    final bytes = await NetConn.readLimited(res.stream, maxBytes, t);
    // P1-10：输入有上限不等于输出有上限——102KB 的 gzip 体能炸出 GB 级
    // 字节（gzip 常态膨胀比可达 1000×）。解压改走带闸门的流式解码，
    // 超限立即抛 DecompressionBombException 而不是先完整展开。
    if (enc.contains('gzip')) {
      return await gzipDecodeGuarded(bytes, maxBytes: kMaxDecodedBytesSmall);
    }
    if (enc.contains('deflate')) {
      return await zlibDecodeGuarded(bytes, maxBytes: kMaxDecodedBytesSmall);
    }
    return bytes;
  }
}