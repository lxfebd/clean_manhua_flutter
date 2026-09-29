import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/image_cache.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/mangadex_source.dart';
import 'package:xingmanxia/sources/source_config.dart';

/// 回归：第 1 轮「漫画阅读」修复。
///
/// 覆盖两个 P0 缺陷：
/// - #1 [MangaDexSource.detail]：feed 的 `attributes.chapter` 是 int / null，
///   原 `as String?` 断言直接抛 TypeError，点开任意 MangaDex 章节即崩。
///   现在用 `a['chapter']?.toString() ?? ''` 兼容 int / String / null。
/// - #2 [ImageCacheManager.load]：in-flight 去重的 `_inflight[norm]` 存的是
///   `Future<Uint8List>`，网络失败时若不移除，后续调用会拿到已完成的失败
///   future，重试永远走不通（`whenComplete` 的清理太晚，来不及救并发调用者）。
///   现在失败即刻移除槽位并 rethrow，下一个调用者能重新发起请求。
///
/// 两个都用本地 mock server + 真实回环网络驱动，与
/// regression_xbiquge_paging_test.dart 同款手法（清掉测试默认 HTTP mock 后走
/// 真实连接），避免去 mock `Net.getBytesAuto` 这条不可注入的静态路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 打桩：LocalStore / 磁盘图片缓存落到临时目录（单元测试无插件通道）。
  var tempDir = '';
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xm_line1_comic_fix').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tempDir;
        }
        return null;
      },
    );
    LocalStore.resetForTest();
  });

  tearDownAll(() {
    LocalStore.resetForTest();
    try {
      if (tempDir.isNotEmpty && Directory(tempDir).existsSync()) {
        Directory(tempDir).deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('#1 MangaDex feed chapter 字段类型兼容', () {
    HttpServer? server;
    String base = '';

    setUp(() async {
      // 清掉测试默认 HTTP mock（否则 dart:io 请求会被强制 400），走真实本地回环。
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server!.address.address}:${server!.port}';
      server!.listen((req) {
        final p = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        void respond(Map<String, dynamic> j) {
          req.response.write(jsonEncode(j));
          req.response.close();
        }

        // 用 comicId 区分 feed 返回的 chapter 类型：
        //  - m-int   → attributes.chapter 为 int（老代码 `int as String?`
        //              抛 TypeError 的回归点）
        //  - m-null  → 番外，chapter 缺省（null）
        //  - m-str   → 兜底字符串（老代码也能过的路径，一并锁住）
        final seg = p.replaceAll(RegExp(r'^/manga/'), '');
        final cid = seg.contains('/feed') ? seg.split('/feed').first : seg;

        // /manga/{id}：详情接口，返回单个 manga（title 为 i18n 结构）。
        if (p.startsWith('/manga/') && !p.contains('/feed')) {
          respond({
            'data': {
              'id': cid,
              'attributes': {
                'title': {'zh': '测试漫画'},
                'altTitles': <dynamic>[],
              },
            },
            'relationships': <dynamic>[],
          });
          return;
        }
        // /manga/{id}/feed：章节 feed。
        final dynamic chVal = cid == 'm-null' ? null : cid == 'm-str' ? '0' : 0;
        final chTitle = cid == 'm-null' ? '番外测试' : '测试章';
        respond({
          'data': [
            {
              'id': 'ch-1',
              'attributes': {
                'chapter': chVal,
                'title': chTitle,
                'translatedLanguage': 'zh',
              },
            },
          ],
          'limit': 100,
          'offset': 0,
        });
      });

      // 注入 mock host 覆盖 MangaDex 内置域名。
      await SourceConfigStore.save(SourceConfig(
        engineId: 'mangadex',
        id: 'mangadex',
        name: 'MangaDex',
        tier: SourceTier.fallback,
        hosts: [base],
      ));
      SourceConfigStore.invalidateCache();
    });

    tearDown(() async {
      await server?.close(force: true);
      HttpOverrides.global = null;
      await SourceConfigStore.resetToDefaults();
      SourceConfigStore.invalidateCache();
    });

    test('feed chapter 为 int 时 detail 不抛异常，label 含章节号（回归）', () async {
      // 修复前：`int as String?` 抛 _TypeError，detail 直接失败。
      final src = MangaDexSource();
      final d = await src.detail('m-int');
      expect(d.chapters, hasLength(1));
      expect(d.chapters.first.title, startsWith('第0话'));
      expect(d.chapters.first.title, endsWith('（zh）'));
    });

    test('feed chapter 为 null 时按番外渲染，不抛异常', () async {
      final src = MangaDexSource();
      final d = await src.detail('m-null');
      expect(d.chapters, hasLength(1));
      // 番外走 else 分支：'番外 {title}（{lang}）'.trim()
      expect(d.chapters.first.title, startsWith('番外'));
      expect(d.chapters.first.title, contains('番外测试'));
    });

    test('feed chapter 为字符串时保持原有行为', () async {
      final src = MangaDexSource();
      final d = await src.detail('m-str');
      expect(d.chapters.first.title, startsWith('第0话'));
    });
  });

  group('#2 ImageCacheManager in-flight 失败不污染', () {
    test('load 首次失败后槽位即刻移除：下一次调用重新发起且成功', () async {
      await ImageCacheManager.clear();
      const url = 'https://cdn-line1.example/a/0001.jpg';
      var calls = 0;
      final fut = () async {
        calls++;
        if (calls == 1) {
          throw Exception('boom: 首次网络失败');
        }
        return Uint8List.fromList([1, 2, 3]);
      };

      // 首次调用：抛异常（模拟 CDN 抖动 / 网络断开）。
      Object? firstErr;
      try {
        await ImageCacheManager.load(url, fetch: fut);
      } catch (e) {
        firstErr = e;
      }
      expect(firstErr, isNotNull);
      expect(calls, 1);

      // 关键回归断言：失败槽位已被清掉（whenComplete 清理之前调用即被移除），
      // 否则下一次 load 会拿到已完成的失败 future，网络恢复也拿不到成功结果。
      final ok = await ImageCacheManager.load(url, fetch: fut);
      expect(calls, 2,
          reason: '第二次 load 必须重新发起 fetch，而不是复用失败 future');
      expect(ok, [1, 2, 3]);
    });

    test('loadDegraded 失败槽位清除后，下一次调用能重新发起并成功', () async {
      await ImageCacheManager.clear();
      const url = 'https://cdn-line1.example/media/photos/42/f.jpg@jm:9';
      var calls = 0;
      var first = true;
      final loader = (u, i) async {
        calls++;
        if (first) {
          first = false;
          throw Exception('boom: 降级链全部失败');
        }
        return Uint8List.fromList([7, 7, 7]);
      };

      // 首次 loadDegraded 失败（降级链全挂）。
      Object? firstErr;
      try {
        await ImageCacheManager.loadDegraded(url, engineId: 'jm', loader: loader);
      } catch (e) {
        firstErr = e;
      }
      expect(firstErr, isNotNull);
      expect(calls, 1);

      // 失败槽位清除后：下一次调用能重新发起并拿到成功结果。
      final r2 = await ImageCacheManager.loadDegraded(
        url,
        engineId: 'jm',
        loader: loader,
      );
      expect(calls, 2);
      expect(r2.bytes, [7, 7, 7]);

      // 成功写入内存缓存，第三次调用直接命中（不再触发 loader）。
      final r3 = await ImageCacheManager.loadDegraded(
        url,
        engineId: 'jm',
        loader: loader,
      );
      expect(calls, 2, reason: '成功结果已入缓存，第三次应命中内存槽');
      expect(r3.bytes, [7, 7, 7]);
    });
  });
}
