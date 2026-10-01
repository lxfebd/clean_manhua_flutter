import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/capabilities/capability_artifact_store.dart';
import 'package:xingmanxia/capabilities/capability_plugin.dart';
import 'package:xingmanxia/net/http_client.dart';

/// Net.getBytesWithProgress 单元测试：分块下载 + 进度回调 + 超上限。
///
/// 用本机 HttpServer 分块发送响应体（真实 TCP 分块，非整包 mock），验证：
/// - 进度回调单调递增，最终 received == 响应体字节数、total == content-length；
/// - 返回字节与发送内容一致；
/// - maxBytes 超上限抛 ResponseTooLargeException。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 绕过 flutter_test 的全局 HttpClient mock（恒返 400）：恢复真实 HttpClient，
  // 本地 HttpServer 提供真实分块响应。测试完还原（防止影响其它文件/进程）。
  setUpAll(() {
    HttpOverrides.global = null;
  });

  late HttpServer server;
  late String url;

  /// 起一个分块发送的本地服务：先写 [chunks]，每块间隔 [gap]，响应头带
  /// content-length = 总字节数（客户端进度 total 即由此而来）。
  Future<void> startServer(List<List<int>> chunks,
      {Duration gap = const Duration(milliseconds: 20)}) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    server.listen((req) async {
      req.response.contentLength = total;
      for (final c in chunks) {
        req.response.add(c);
        await req.response.flush();
        await Future<void>.delayed(gap);
      }
      await req.response.close();
    });
    url = 'http://127.0.0.1:${server.port}/test.bin';
  }

  tearDown(() async {
    await server.close(force: true);
  });

  test('分块下载：进度回调单调递增到 100%，返回字节一致', () async {
    final chunks = <List<int>>[
      [1, 2, 3],
      [4, 5],
      [6, 7, 8, 9],
      [10],
    ];
    final expected = chunks.expand((c) => c).toList();
    await startServer(chunks, gap: const Duration(milliseconds: 10));

    final events = <(int, int?)>[];
    final bytes = await Net.getBytesWithProgress(
      url,
      maxBytes: 1024,
      timeout: const Duration(seconds: 5),
      onProgress: (r, t) => events.add((r, t)),
    );

    expect(bytes, expected);
    // 进度事件 ≥1 条，最后一条 received == 总量、total == content-length。
    expect(events, isNotEmpty);
    final last = events.last;
    expect(last.$1, expected.length);
    expect(last.$2, expected.length);
    // 单调递增（received 只增不减）。
    for (var i = 1; i < events.length; i++) {
      expect(events[i].$1, greaterThan(events[i - 1].$1));
    }
  });

  test('超过 maxBytes：抛 ResponseTooLargeException，不返回半截', () async {
    final chunks = <List<int>>[
      List.filled(64, 1),
      List.filled(64, 2),
    ];
    await startServer(chunks, gap: Duration.zero);

    await expectLater(
      Net.getBytesWithProgress(
        url,
        maxBytes: 100, // 小于 128 总字节 → 中途超限
        timeout: const Duration(seconds: 5),
      ),
      throwsA(isA<ResponseTooLargeException>()),
    );
  });

  test('downloadWeight 透传 onProgress：进度回调递增到 100%', () async {
    final chunks = <List<int>>[
      [1, 2, 3],
      [4, 5, 6, 7],
    ];
    final expected = chunks.expand((c) => c).toList();
    await startServer(chunks, gap: const Duration(milliseconds: 10));

    final tmp = await Directory.systemTemp.createTemp('xm_weight_progress');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    CapabilityArtifactStore.instance.testOverrideDir = tmp;
    addTearDown(() => CapabilityArtifactStore.instance.testOverrideDir = null);

    final events = <(int, int?)>[];
    final target = 'ddcolor_test.tflite';
    final file = await CapabilityArtifactStore.instance.downloadWeight(
      'test.weight',
      CapabilityWeight(
          name: target, url: url, sizeBytes: expected.length, sha256: ''),
      onProgress: (r, t) => events.add((r, t)),
    );

    expect(file, isNotNull);
    expect(await file!.readAsBytes(), expected);
    expect(events, isNotEmpty);
    expect(events.last.$1, expected.length);
    expect(events.last.$2, expected.length);
    // 落盘路径 = <tmp>/.model_cache/test.weight/ddcolor_test.tflite
    expect(file.path, contains('.model_cache'));
  });
}
