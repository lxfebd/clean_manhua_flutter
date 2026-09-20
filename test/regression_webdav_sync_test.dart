import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/webdav_sync.dart';

/// 旧版 v1 密钥派生：裸 SHA-256（无迭代、无盐）。
Uint8List _legacyKey() {
  final digest = SHA256Digest();
  final input = utf8.encode('v1-old-pass');
  final out = Uint8List(32);
  digest.update(input, 0, input.length);
  digest.doFinal(out, 0);
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 每个用例独立临时目录 + 重置静态缓存：隔离用例间状态。
  String? tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xm_webdav').path;
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
    // 无既有配置，恢复出空状态
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

  group('WebDAV 同步文件加解密', () {
    test('AES-GCM 加解密往返一致（含中文）', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: 'https://example.invalid/dav/',
        username: '',
        password: 'test-口令-123',
        dir: '',
        encrypt: true,
      );
      final json = const JsonEncoder.withIndent('  ')
          .convert({'name': '星漫匣', 'items': [1, 2, 3]});
      final enc = WebDavSync.testEncrypt(json);
      // 新格式写 v2 魔数（PBKDF2 派生）；旧 v1 魔数仍可解密历史文件。
      expect(
          enc.startsWith(WebDavSync.magic) ||
              enc.startsWith(WebDavSync.magicV2),
          isTrue);
      expect(WebDavSync.testDecrypt(enc), json);
    });

    test('明文模式原样返回', () {
      const plain = '{"version":1}';
      expect(WebDavSync.testDecrypt(plain), plain);
    });

    test('加密数据被篡改会抛异常（GCM 认证）', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: 'https://example.invalid/dav/',
        username: '',
        password: 'secret',
        dir: '',
        encrypt: true,
      );
      final enc = WebDavSync.testEncrypt('{"a":1}');
      final tampered = enc.substring(0, enc.length - 2) +
          (enc.endsWith('AA') ? 'BB' : 'AA');
      expect(() => WebDavSync.testDecrypt(tampered), throwsA(anything));
    });

    test('旧 v1 格式（裸 SHA-256 派生）仍可解密', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: 'https://example.invalid/dav/',
        username: '',
        password: 'v1-old-pass',
        dir: '',
        encrypt: true,
      );
      // 手工构造 v1 密文（AES-256-GCM，SHA-256 派生密钥，XMX-SYNC-1 魔数）
      final pt = utf8.encode('{"legacy":true}');
      final key = _legacyKey();
      final iv = Uint8List.fromList(
          List<int>.generate(12, (_) => Random(42).nextInt(256)));
      final gcm = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
      final out = Uint8List(gcm.getOutputSize(pt.length));
      var off = gcm.processBytes(pt, 0, pt.length, out, 0);
      off += gcm.doFinal(out, off);
      final v1Body = '${WebDavSync.magic}\n${base64Encode(iv)}\n'
          '${base64Encode(Uint8List.sublistView(out, 0, off))}';
      expect(WebDavSync.testDecrypt(v1Body), '{"legacy":true}');
    });
  });

  group('WebDAV 路径拼接', () {
    test('目录归一化 + 文件名拼接', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: 'https://dav.example.com/dav/',
        username: '',
        password: '',
        dir: '/Apps/星漫匣/',
        encrypt: false,
      );
      // 私有 _fileUri 不可直接读，这里验证 saveConfig 持久化往返
      final j = await LocalStore.readJson('webdav_config');
      expect(j['dir'], '/Apps/星漫匣/');
      // 首次保存且无已存密码 → 标记为空
      expect(j['password'], '');
      expect(j['encrypt'], isFalse);
      // 已有已存密码时留空保存 → 保留标记（不覆盖已存密码）
      await WebDavSync.saveConfig(
        url: 'https://dav.example.com/dav/',
        username: '',
        password: 'existing',
        dir: '/Apps/星漫匣/',
        encrypt: false,
      );
      await WebDavSync.saveConfig(
        url: 'https://dav.example.com/dav/',
        username: '',
        password: '',
        dir: '/Apps/星漫匣/',
        encrypt: false,
      );
      final j2 = await LocalStore.readJson('webdav_config');
      expect(j2['password'], 'saved'); // 留空保存不覆盖已存密码标记
    });

    test('密码明文不落盘，仅有 hasPassword 标记', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: 'https://dav.example.com/dav/',
        username: 'user',
        password: 'p@ssw0rd',
        dir: '',
        encrypt: true,
      );
      final j = await LocalStore.readJson('webdav_config');
      expect(j['password'], isNot('p@ssw0rd'));
      expect(j['password'], 'saved');
      expect(j['username'], 'user');
    });
  });

  group('WebDAV 本地服务器集成', () {
    HttpServer? server;
    String serverUrl = '';
    final store = <String, String>{};

    setUp(() async {
      // TestWidgetsFlutterBinding 会把所有 HTTP 请求 mock 成 400，
      // 清掉 mock override 走真实本地回环网络。
      HttpOverrides.global = null;
      store.clear();
       server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUrl = 'http://127.0.0.1:${server!.port}/dav/';
      server!.listen((req) async {
        // 简化 WebDAV：GET/PUT 同路径，等价于一个文本 KV 文件服务器。
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
            req.response.statusCode = HttpStatus.created;
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

    test('push 后 pull 恢复一致（明文）', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: serverUrl,
        username: '',
        password: '',
        dir: 'Apps/星漫匣',
        encrypt: false,
      );
      // 本地先写入一条设置
      await LocalStore.writeJson('settings', {'theme': 'dark'});
      await WebDavSync.push();
      // 清掉本地，再从远端拉回
      await LocalStore.writeJson('settings', {});
      final ok = await WebDavSync.pull();
      expect(ok, isTrue);
      final j = await LocalStore.readJson('settings');
      expect(j['theme'], 'dark');
    });

    test('push 后 pull 恢复一致（加密）', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: serverUrl,
        username: '',
        password: '同步口令',
        dir: 'Apps/星漫匣',
        encrypt: true,
      );
      await LocalStore.writeJson('history', {'c1': 5});
      await WebDavSync.push();
      await LocalStore.writeJson('history', {});
      final ok = await WebDavSync.pull();
      expect(ok, isTrue);
      final j = await LocalStore.readJson('history');
      expect(j['c1'], 5);
    });

    test('远端无文件时 pull 报错提示', () async {
      await LocalStore.init();
      await WebDavSync.saveConfig(
        url: serverUrl,
        username: '',
        password: '',
        dir: '',
        encrypt: false,
      );
      await expectLater(
        WebDavSync.pull(),
        throwsA(predicate((e) => e.toString().contains('远端还没有同步文件'))),
      );
    });
  });
}
