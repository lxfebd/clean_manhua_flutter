import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:xingmanxia/net/aes_cbc.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/net_guard.dart';
import 'package:xingmanxia/net/video_download_manager.dart';

/// P2-09 HLS 下载验收。
///
/// 用本地 HTTP 服务器模拟真实 HLS 源，不是只测字符串解析：
/// - key rotation：两个分片用不同密钥/IV，合并结果必须还原原文；
/// - 多码率：画质档位确实会选到不同变体；
/// - SAMPLE-AES：下载前明确拒绝，不产出不可播文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late String base;
  late String tempDir;
  final manager = VideoDownloadManager.instance;
  Future<void> Function(HttpRequest req) handler = (req) async {
    req.response.statusCode = 404;
    await req.response.close();
  };

  Uint8List encrypt(Uint8List plain, Uint8List key, Uint8List iv) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
    final out = Uint8List(plain.length);
    var offset = 0;
    for (var i = 0; i < plain.length ~/ 16; i++) {
      offset += cipher.processBlock(plain, i * 16, out, offset);
    }
    return out;
  }

  Future<void> serve(
      String path, List<int> body, String contentType, HttpResponse r) async {
    r.statusCode = 200;
    r.headers.contentType = ContentType.parse(contentType);
    r.contentLength = body.length;
    r.add(body);
    await r.close();
  }

  setUpAll(() async {
    // flutter_test 默认用 MockHttpOverrides 把所有真实 HTTP 变成 400；
    // 本文件就是要打本地 HLS 服务器，必须恢复真实 HttpClient。
    HttpOverrides.global = null;
    tempDir = Directory.systemTemp.createTempSync('xm_hls').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') return tempDir;
        return null;
      },
    );
    LocalStore.resetForTest();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    NetGuard.allowLoopbackPortForTest(server.port);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) => handler(req));
    await manager.init();
  });

  tearDownAll(() async {
    await server.close(force: true);
    try {
      Directory(tempDir).deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<VideoDownloadTask> runTask(
      String id, String url, {int episode = 1}) async {
    final t = await manager.start(
      sourceId: 'fixture',
      videoId: id,
      title: id,
      season: 1,
      episode: episode,
      url: url,
    );
    for (var i = 0; i < 200; i++) {
      final cur = manager.taskOf(t.key);
      if (cur != null && cur.state != 'downloading') return cur;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw TimeoutException('任务 ${t.key} 长时间未结束');
  }

  test('key rotation：每个分片用自己的密钥/IV 解密', () async {
    final key1 = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final key2 = Uint8List.fromList(List.generate(16, (i) => 200 - i));
    final plain1 = Uint8List.fromList(List.filled(32, 65)); // A
    final plain2 = Uint8List.fromList(List.filled(32, 66)); // B
    final iv1 = AesCbc.segmentIv('01', 0);
    final iv2 = AesCbc.segmentIv('02', 1);
    final enc1 = encrypt(plain1, key1, iv1);
    final enc2 = encrypt(plain2, key2, iv2);

    handler = (req) async {
      final p = req.uri.path;
      if (p == '/rot.m3u8') {
        await serve(
            p,
            '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-KEY:METHOD=AES-128,URI="key1.bin",IV=0x01
#EXTINF:1,
seg1.ts
#EXT-X-KEY:METHOD=AES-128,URI="key2.bin",IV=0x02
#EXTINF:1,
seg2.ts
#EXT-X-ENDLIST
'''
                .codeUnits,
            'application/vnd.apple.mpegurl',
            req.response);
      } else if (p == '/key1.bin') {
        await serve(p, key1, 'application/octet-stream', req.response);
      } else if (p == '/key2.bin') {
        await serve(p, key2, 'application/octet-stream', req.response);
      } else if (p == '/seg1.ts') {
        await serve(p, enc1, 'video/mp2t', req.response);
      } else if (p == '/seg2.ts') {
        await serve(p, enc2, 'video/mp2t', req.response);
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    };

    final t = await runTask('rot', '$base/rot.m3u8');
    expect(t.state, 'done', reason: t.error);
    final bytes = await File(t.localPath!).readAsBytes();
    expect(bytes, equals([...plain1, ...plain2]),
        reason: '旧实现只留最后一个 key，第一片会解错；这里必须两片都还原');
  });

  test('多码率：省流量选最低档，最高画质选最高档', () async {
    handler = (req) async {
      final p = req.uri.path;
      if (p == '/master.m3u8') {
        await serve(
            p,
            '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=300000
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000
high.m3u8
'''
                .codeUnits,
            'application/vnd.apple.mpegurl',
            req.response);
      } else if (p == '/low.m3u8' || p == '/high.m3u8') {
        final name = p == '/low.m3u8' ? 'low.ts' : 'high.ts';
        await serve(
            p,
            '#EXTM3U\n#EXTINF:1,\n$name\n#EXT-X-ENDLIST\n'.codeUnits,
            'application/vnd.apple.mpegurl',
            req.response);
      } else if (p == '/low.ts') {
        await serve(p, List.filled(16, 76), 'video/mp2t', req.response); // L
      } else if (p == '/high.ts') {
        await serve(p, List.filled(16, 72), 'video/mp2t', req.response); // H
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    };

    await manager.setQuality(VideoDownloadQuality.saver);
    final low = await runTask('variant', '$base/master.m3u8', episode: 1);
    expect(low.state, 'done', reason: low.error);
    expect(await File(low.localPath!).readAsBytes(),
        equals(List.filled(16, 76)),
        reason: '省流量档必须选低码率变体，而不是无条件最高码率');

    await manager.setQuality(VideoDownloadQuality.high);
    final high = await runTask('variant', '$base/master.m3u8', episode: 2);
    expect(high.state, 'done', reason: high.error);
    expect(await File(high.localPath!).readAsBytes(),
        equals(List.filled(16, 72)));
  });

  test('SAMPLE-AES 在下载前明确拒绝', () async {
    handler = (req) async {
      await serve(
          req.uri.path,
          '''#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
#EXTINF:1,
seg.ts
#EXT-X-ENDLIST
'''
              .codeUnits,
          'application/vnd.apple.mpegurl',
          req.response);
    };
    final t = await runTask('sampleaes', '$base/sample.m3u8');
    expect(t.state, 'failed');
    expect(t.error, contains('SAMPLE-AES'));
    expect(t.error, contains('停止下载'));
  });
}
