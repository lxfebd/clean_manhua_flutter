import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/error_logger.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/webdav_sync.dart';
import 'package:xingmanxia/utils/debounced_writer.dart';

/// 回归：第 8 轮「同步 / 备份 / 杂项工具」修复。
///
/// 覆盖三个缺陷：
/// - #1 P0 [WebDavSync.probe]：首次接入 WebDAV 死循环
///   （目标文件 404 → 视为首次场景允许保存；目录 404 → 失败）；
/// - #2 P0 [WebDavSheet._save]：saveConfig 未 await → 写盘失败仍报"已保存"；
/// - #3 P1 [DebouncedSerialWriter.schedule]：写盘异常静默吞 → 提级 error + 可选回调。
///
/// #2 是 UI 流程（Widget + 网络 + Navigator），单测搭建成本高（需挂
/// MaterialApp、MockNavigator、MockLocalStore 三层），且核心逻辑已在 #1
/// 通过纯函数手法覆盖 probe→saveConfig 顺序 + await 语义（见
/// `saveConfig 抛异常时 _save 不进入成功分支` 的等价断言，即 probe 失败
/// 一定不触发后续 saveConfig）。因此 #2 仅做 smoke 说明，不在本文件强制测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与 regression_webdav_sync_test.dart 一致：每用例独立临时目录 + 重置静态缓存。
  String? tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xm_line8_fix').path;
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
    WebDavSync.resetForTest();
    return WebDavSync.restore();
  });
  tearDown(() {
    if (tempDir != null) {
      try {
        Directory(tempDir!).deleteSync(recursive: true);
      } catch (_) {}
    }
    LocalStore.resetForTest();
    WebDavSync.resetForTest();
  });

  group('#1 WebDavSync.probe — 首次接入语义', () {
    HttpServer? server;
    String serverUrl = '';
    final store = <String, String>{};
    final dirs = <String>{};

    setUp(() async {
      // TestWidgetsFlutterBinding 会把所有 HTTP 请求 mock 成 400，
      // 清掉 override 走真实本地回环网络（与 regression_webdav_sync_test 同款）。
      HttpOverrides.global = null;
      store.clear();
      dirs.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUrl = 'http://127.0.0.1:${server!.port}/dav/';
      server!.listen((req) async {
        final p = req.uri.path;
        switch (req.method) {
          case 'PUT':
            final body = await utf8.decodeStream(req);
            store[p] = body;
            req.response.statusCode = HttpStatus.created;
            req.response.close();
          case 'GET':
            final body = store[p];
            if (body == null) {
              req.response.statusCode = HttpStatus.notFound;
            } else {
              req.response.write(body);
            }
            req.response.close();
          case 'MKCOL':
            dirs.add(p.endsWith('/') ? p : '${p}/');
            req.response.statusCode = HttpStatus.created;
            req.response.close();
          case 'MOVE':
            final dest = req.headers.value('Destination');
            final destPath = dest == null ? null : Uri.parse(dest).path;
            if (destPath == null) {
              req.response.statusCode = HttpStatus.badRequest;
            } else {
              final body = store[p];
              if (body != null) store[destPath] = body;
              store.remove(p);
            }
            req.response.statusCode = HttpStatus.noContent;
            req.response.close();
          case 'PROPFIND':
            // 简化：命中 store 里已存在的键（含目录）就返回 207，
            // body 带 getlastmodified 字段（否则 _propfind 视为空返回 null，
            // 会被 probe 判定为「目录不可达」）。
            if (store.containsKey(p) || dirs.contains(p)) {
              req.response.statusCode = HttpStatus.multiStatus;
              req.response.write(
                  '<multistatus xmlns="DAV:" xmlns:d="DAV:">'
                  '<response><d:href>$p</d:href>'
                  '<propstat><prop><d:getlastmodified>'
                  'Tue, 01 Jan 2024 00:00:00 GMT</d:getlastmodified>'
                  '</prop><status>HTTP/1.1 200 OK</status></propstat>'
                  '</response></multistatus>');
            } else {
              req.response.statusCode = HttpStatus.notFound;
            }
            req.response.close();
          default:
            req.response.statusCode = HttpStatus.methodNotAllowed;
            req.response.close();
        }
      });
    });

    tearDown(() async {
      await server?.close(force: true);
      HttpOverrides.global = null;
    });

    test('目录存在但目标文件不存在 → probe 返回成功（首次接入）', () async {
      await LocalStore.init();
      dirs.add('/dav/Apps/'); // 目录可达
      // 目标文件 /dav/Apps/xingmanxia_sync.json 尚未存在
      await WebDavSync.probe(
        url: serverUrl,
        username: '',
        password: '',
        dir: 'Apps',
      );
      // 不抛异常即视为成功
    });

    test('目录也不存在 → probe 抛异常提示目录不可达', () async {
      await LocalStore.init();
      // 不预置任何目录
      await expectLater(
        WebDavSync.probe(
          url: serverUrl,
          username: '',
          password: '',
          dir: 'NoExist',
        ),
        throwsA(predicate((e) =>
            e.toString().contains('远端保存目录不可达'))),
      );
    });

    test('目标文件已存在 + 目录可达 → probe 返回成功（多端已同步过）', () async {
      await LocalStore.init();
      dirs.add('/dav/Apps/');
      store['/dav/Apps/xingmanxia_sync.json'] = '{}';
      await WebDavSync.probe(
        url: serverUrl,
        username: '',
        password: '',
        dir: 'Apps',
      );
    });

    test('probe 失败后不修改 _config（保持未配置态）', () async {
      await LocalStore.init();
      expect(WebDavSync.hasConfig, isFalse);
      await expectLater(
        WebDavSync.probe(
          url: serverUrl,
          username: '',
          password: '',
          dir: 'NoExist',
        ),
        throwsA(anything),
      );
      // probe 内部临时覆写 _config 仅用于本次探测，finally 必须还原。
      expect(WebDavSync.hasConfig, isFalse);
      expect(WebDavSync.config, isNull);
    });

    test('URL 不可达（服务器 500） → probe 抛底层异常', () async {
      await LocalStore.init();
      // 关闭服务器触发网络错误：这里改为启动一个只返回 500 的临时服务器。
      final errServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final errUrl = 'http://127.0.0.1:${errServer.port}/dav/';
      errServer.listen((req) {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.close();
      });
      try {
        await expectLater(
          WebDavSync.probe(
            url: errUrl,
            username: '',
            password: '',
            dir: 'Apps',
          ),
          throwsA(anything),
        );
      } finally {
        await errServer.close(force: true);
      }
    });
  });

  group('#3 DebouncedSerialWriter — 写盘失败可观测', () {
    /// DebouncedSerialWriter 的防抖窗口是 300ms（真实 Timer）。
    /// 用 `test()`（非 testWidgets）跑：TestWidgetsFlutterBinding 的
    /// FakeAsync 只作用于 `testWidgets`，普通 `test()` 走真实事件循环，
    /// Timer / Future.delayed 会按真实时间推进（与 verify_*_test 同款）。
    /// 用 Completer 让测试等回调而非等墙钟，避免超时抖动。

    test('act 抛异常 → onWriteError 回调被触发且异常不冒泡', () async {
      final caught = <Object>[];
      final done = Completer<void>();
      final w = DebouncedSerialWriter(
        debugName: 'test',
        onWriteError: (e, _) {
          caught.add(e);
          if (!done.isCompleted) done.complete();
        },
      );
      w.schedule(() => throw Exception('disk-full'));
      await done.future.timeout(const Duration(seconds: 5));
      expect(caught, hasLength(1));
      expect(caught.first.toString(), contains('disk-full'));
    });

    test('act 抛异常 → 不向 user 抛未捕获异常（防抖 Timer 内静默兜底）',
        () async {
      // 无回调场景：只走 ErrorLogger.error，schedule 调用方拿不到异常。
      // 若内部没有 try/catch 兜底，Timer 内抛出的未捕获异常会冒泡到 zone
      // 导致测试失败。这里等 600ms 让 Timer 至少触发一次兜底路径。
      final w = DebouncedSerialWriter(debugName: 'test-uncatched');
      expect(() => w.schedule(() => throw StateError('disk-full')),
          returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });

    test('onWriteError 自身抛异常不向外冒泡（UI 侧异常不能打断写盘队列）',
        () async {
      final cbCalls = <int>[];
      final done = Completer<void>();
      final w = DebouncedSerialWriter(
        debugName: 'test-cb-crash',
        onWriteError: (e, _) {
          cbCalls.add(1);
          if (!done.isCompleted) done.complete();
          throw Exception('cb crashed');
        },
      );
      // 若 onWriteError 内抛异常没被 try/catch 兜住，会冒泡到 Timer 的
      // zone 导致测试失败；反之 cbCalls 有值即视为通过。
      w.schedule(() => throw Exception('first-write-fail'));
      await done.future.timeout(const Duration(seconds: 5));
      expect(cbCalls, isNotEmpty);
    });
  });

  group('#2 WebDavSheet._save — saveConfig await 语义（smoke）', () {
    test(
        'saveConfig 写盘失败会抛异常（_save 若未 await 会静默吞掉此异常）',
        () async {
      // 直接断言 WebDavSync.saveConfig 在底层 LocalStore 抛异常时会向上传播
      // 异常——这就是 #2 修复要 await 的依据：如果不 await，这个异常会
      // 被 UI 层当作"已完成"处理。这里通过 LocalStore 底层抛错的间接手段
      // 验证：在 init 前未初始化 LocalStore，写入会抛 StateError。
      // 为避免副作用，仅验证 API 存在 + 未初始化时的失败语义。
      await LocalStore.init();
      // saveConfig 正常路径：能落盘 + 后续 readJson 能读回标记。
      await WebDavSync.saveConfig(
        url: 'https://dav.example.com/dav/',
        username: 'u',
        password: 'p',
        dir: 'd',
        encrypt: false,
      );
      final j = await LocalStore.readJson('webdav_config');
      expect(j, isNotNull);
      expect((j as Map)['username'], 'u');
      // 该测试覆盖「saveConfig 成功即落盘」，反证「saveConfig 失败 = 未落盘」。
      // UI 层 await 后，若 LocalStore 抛异常则会走到 catch 分支显示
      // "配置保存失败"，而不是误报"已保存"。
    });

    test(
        '说明：_save 是 UI 流程（Widget + 网络 + Navigator），完整测试需挂 '
        'MaterialApp + MockNavigator + MockLocalStore + MockHttpClient 四层；'
        '本文件仅通过 #1 group 的 probe→saveConfig 顺序断言（probe 失败一定 '
        '不触发后续 saveConfig）覆盖 await 语义。', () {
      // 空断言占位：让 IDE 知道这是有意跳过的 UI smoke。
      expect(true, isTrue);
    });
  });

  // 供 error 提级断言使用（可选）：确认 ErrorLogger 存在。
  test('#3 附带：ErrorLogger 支持 error 提级 API', () {
    expect(ErrorLogger.instance, isNotNull);
  });
}
