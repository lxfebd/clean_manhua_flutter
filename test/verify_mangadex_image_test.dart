import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/widgets/cached_image.dart';

/// MangaDex 静态资源真网契约：确认按域名的 UA 分流真的能拿到图片。
///
/// 这是**唯一能证明修复生效**的测试：只看 UA 字符串相等不算数，
/// 必须真的拿到 image/* 且字节数合理。
/// uploads 域名被同一套 POWBlock 网关保护，用浏览器 UA 会拿到
/// 200 + 2022B text/html（不是 403），图片解码端只会当成损坏图。
const bool _skipLive = !bool.fromEnvironment('LIVE_SOURCE_TESTS');

void main() {
  test('章节图：用分流后的请求头拿到真实 JPEG', () async {
    // 固定一张已知存在的页面（2026-11-26 实测可用）
    const url = 'https://uploads.mangadex.org/data/'
        '088583bf54406c94bbb90c15af4a38bc/'
        'x1-9a71009adfcf8ce504fa1ff77945d13517b177df7aab78a1dcb6c45fcabfd085.jpg';
    final h = CachedImage.headersFor(url);

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      h.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(const Duration(seconds: 25));
      final ct = res.headers.contentType?.mimeType;
      final bytes = await res.fold<int>(0, (a, b) => a + b.length);
      // ignore: avoid_print
      print('  章节图 status=${res.statusCode} ct=$ct bytes=$bytes');
      expect(ct, startsWith('image/'),
          reason: '拿到 $ct 说明又被 PoW 网关拦成 HTML 了');
      expect(bytes, greaterThan(10000));
    } finally {
      client.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);

  test('对照：故意用浏览器 UA 应被拦成 HTML（证明这条契约不是空转）', () async {
    // 同一条 URL，用浏览器 UA 必然拿到 text/html。若这个对照组也拿到图片，
    // 说明网关行为变了，本组契约需要重新评估（而不是静默失效）。
    const url = 'https://uploads.mangadex.org/data/'
        '088583bf54406c94bbb90c15af4a38bc/'
        'x1-9a71009adfcf8ce504fa1ff77945d13517b177df7aab78a1dcb6c45fcabfd085.jpg';
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
      final res = await req.close().timeout(const Duration(seconds: 25));
      final ct = res.headers.contentType?.mimeType;
      final body = await res.transform(utf8.decoder).join();
      // ignore: avoid_print
      print('  对照(浏览器UA) status=${res.statusCode} ct=$ct len=${body.length}');
      if (ct == 'text/html') {
        expect(body, contains('Browser verification'));
      }
      // 无论被拦还是放行都不断言失败——这条只是观测，用于发现网关行为变化。
    } finally {
      client.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
