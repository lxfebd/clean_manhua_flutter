import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/image_cache.dart';
import 'package:xingmanxia/net/image_deg.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/source_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // path_provider 打桩：LocalStore/磁盘缓存落到临时目录（单元测试无插件通道）。
  late Directory tmp;
  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_imgdeg_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmp.path;
        }
        return null;
      },
    );
    LocalStore.init();
  });

  tearDownAll(() async {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ImageDeg URL 归一化', () {
    test('去掉 @jm: 解扰标记', () {
      expect(
        ImageDeg.normalizeUrl('https://cdn.example/media/photos/123/a.jpg@jm:999'),
        'https://cdn.example/media/photos/123/a.jpg',
      );
    });

    test('无标记 URL 原样返回', () {
      expect(
        ImageDeg.normalizeUrl('https://uploads.mangadex.org/data/ab/xx.png'),
        'https://uploads.mangadex.org/data/ab/xx.png',
      );
    });
  });

  group('ImageDeg 降级链', () {
    test('mangadex 注册省空间后：原画 → data-saver', () {
      SourceManager.init();
      final chain = ImageDeg.chain(
        'https://uploads.mangadex.org/data/ab/cd.png',
        engineId: 'mangadex',
        useSaver: true,
      );
      expect(chain.length, 2);
      expect(chain[0], 'https://uploads.mangadex.org/data/ab/cd.png');
      expect(chain[1],
          'https://uploads.mangadex.org/data-saver/ab/cd.png');
    });

    test('mangadex 未开省空间：链只有原画', () {
      final chain = ImageDeg.chain(
        'https://uploads.mangadex.org/data/ab/cd.png',
        engineId: 'mangadex',
        useSaver: false,
      );
      expect(chain, ['https://uploads.mangadex.org/data/ab/cd.png']);
    });

    test('jm 镜像保留 @jm: 标记', () {
      SourceManager.init();
      final chain = ImageDeg.chain(
        'https://cdn-msp2.jmapiproxy2.cc/media/photos/42/f.jpg@jm:777',
        engineId: 'jm',
      );
      expect(chain.length, greaterThan(1));
      for (final u in chain.skip(1)) {
        expect(u, startsWith('https://'));
        expect(u, contains('/media/photos/42/f.jpg'));
        expect(u, endsWith('@jm:777'));
        expect(u, isNot(equals(chain[0])));
      }
    });

    test('降级状态机：0 失败 original / mangadex 槽 1 失败 saver / 无省空间镜像档 mirror / 全失败 failed', () async {
      var calls = 0;
      final r1 = await ImageDeg.loadWithChain(
        ['https://a/1.png', 'https://a/2.png'],
        loader: (u, i) async {
          calls++;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      expect(r1.status, ImageDegStatus.original);
      expect(r1.failures, 0);
      expect(calls, 1);

      // mangadex 开省空间：链 [原画, data-saver]，第二档成功记 saver
      final r2 = await ImageDeg.loadWithChain(
        ['https://uploads.mangadex.org/data/a/1.png',
         'https://uploads.mangadex.org/data-saver/a/1.png'],
        engineId: 'mangadex',
        useSaver: true,
        loader: (u, i) async {
          if (i == 0) throw Exception('boom');
          return Uint8List.fromList([4, 5, 6]);
        },
      );
      expect(r2.status, ImageDegStatus.saver);
      expect(r2.failures, 1);

      // jm（无省空间）：链 [原画, 镜像]，第二档成功记 mirror
      final r2b = await ImageDeg.loadWithChain(
        ['https://cdn-a.example/media/photos/1/f.jpg@jm:1',
         'https://cdn-b.example/media/photos/1/f.jpg@jm:1'],
        engineId: 'jm',
        loader: (u, i) async {
          if (i == 0) throw Exception('boom');
          return Uint8List.fromList([4, 4, 4]);
        },
      );
      expect(r2b.status, ImageDegStatus.mirror);
      expect(r2b.failures, 1);

      final r3 = await ImageDeg.loadWithChain(
        ['https://a/1.png'],
        loader: (u, i) async => throw Exception('boom'),
      );
      expect(r3.status, ImageDegStatus.failed);
      expect(r3.bytes, isNull);
    });
  });

  group('缓存共享槽（同图多 URL 只占一个缓存位）', () {
    test('同 host 去 @jm: 标记：带标记/不带标记共享缓存槽', () async {
      SourceManager.init();
      final withMarker = 'https://cdn-x.example/media/photos/3/c.jpg@jm:8';
      final noMarker = 'https://cdn-x.example/media/photos/3/c.jpg';
      var calls = 0;
      await ImageCacheManager.loadDegraded(
        withMarker,
        engineId: 'jm',
        loader: (u, i) async => Uint8List.fromList([5, 5, 5]),
      );
      final hit = await ImageCacheManager.loadDegraded(
        noMarker,
        loader: (u, i) async {
          calls++;
          return Uint8List.fromList([2, 2, 2]);
        },
      );
      expect(hit.bytes, [5, 5, 5]);
      expect(calls, 0);
    });

    test('原画失败 → 镜像档成功：结果存原 URL 槽位，二次加载直接命中', () async {
      SourceManager.init();
      final orig = 'https://cdn-msp2.jmapiproxy2.cc/media/photos/1/a.jpg@jm:5';
      var loaderCalls = 0;
      final r = await ImageCacheManager.loadDegraded(
        orig,
        engineId: 'jm',
        loader: (u, i) async {
          loaderCalls++;
          if (i == 0) throw Exception('原画挂了');
          return Uint8List.fromList([9, 9, 9]);
        },
      );
      expect(r.status, ImageDegStatus.mirror);
      expect(r.bytes, [9, 9, 9]);
      expect(loaderCalls, 2);

      // 再次用原 URL 加载：直接命中缓存槽（镜像档字节），不再发请求
      final r2 = await ImageCacheManager.loadDegraded(
        orig,
        engineId: 'jm',
        loader: (u, i) async {
          loaderCalls++;
          return Uint8List.fromList([1, 1, 1]);
        },
      );
      expect(r2.bytes, [9, 9, 9]);
      expect(loaderCalls, 2);
    });

    test('预加载（preloadDegraded）成功写入共享槽', () async {
      SourceManager.init();
      final orig =
          'https://cdn-msp2.jmapiproxy2.cc/media/photos/2/b.jpg@jm:6';
      await ImageCacheManager.preloadDegraded(
        orig,
        engineId: 'jm',
        loader: (u, i) async => Uint8List.fromList([7, 7, 7]),
      );
      final hit = await ImageCacheManager.loadDegraded(
        orig,
        engineId: 'jm',
        loader: (u, i) async => Uint8List.fromList([0, 0, 0]),
      );
      expect(hit.bytes, [7, 7, 7]);
    });
  });
}
