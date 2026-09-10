import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // path_provider 打桩：LocalStore 落到临时目录（单元测试无插件通道）。
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_proxy_test').path;
        }
        return null;
      },
    );
    LocalStore.init();
  });

  group('Net 全局代理', () {
    tearDown(() async {
      // 清掉内存态，避免影响其他测试
      await Net.setProxy(null);
    });

    test('socks5://host:port 解析成 SOCKS5 指令', () async {
      await Net.setProxy('socks5://127.0.0.1:1080');
      expect(Net.proxy, 'socks5://127.0.0.1:1080');
      expect(Net.proxyDirective, 'SOCKS5 127.0.0.1:1080');
      await Net.setProxy(null);
      expect(Net.proxy, isNull);
    });

    test('http://host:port 启用后 findProxy 生效', () async {
      await Net.setProxy('http://127.0.0.1:7890');
      expect(Net.proxy, 'http://127.0.0.1:7890');
      expect(Net.proxyDirective, 'PROXY 127.0.0.1:7890');
      // 直接连一个不存在的地址：若代理指令生效，请求会尝试连 127.0.0.1:7890，
      // 而不是走系统 DNS —— 这里只验证启用/停用状态切换不抛错。
      await Net.setProxy(null);
      expect(Net.proxy, isNull);
    });

    test('socks5h/socks4 指令映射', () async {
      await Net.setProxy('socks5h://127.0.0.1:1081');
      expect(Net.proxyDirective, 'SOCKS5 127.0.0.1:1081');
      await Net.setProxy('socks4://127.0.0.1:1082');
      expect(Net.proxyDirective, 'SOCKS4 127.0.0.1:1082');
      await Net.setProxy('https://proxy.example.com:443');
      expect(Net.proxyDirective, 'PROXY proxy.example.com:443');
    });

    test('空白/空串清除代理', () async {
      await Net.setProxy('http://127.0.0.1:7890');
      await Net.setProxy('   ');
      expect(Net.proxy, isNull);
    });

    test('restoreProxy 从空存储恢复为直连', () async {
      await Net.setProxy(null);
      await Net.restoreProxy();
      expect(Net.proxy, isNull);
    });
  });

  group('单源代理（SourceHttp.proxyFor）', () {
    tearDown(() async {
      // 恢复默认配置，避免影响其他测试
      await SourceConfigStore.resetToDefaults();
    });

    test('未配置代理时返回 null（走全局/直连）', () async {
      expect(await SourceHttp.proxyFor('jm'), isNull);
    });

    test('配置代理后返回 trim 后的值', () async {
      final c = await SourceConfigStore.byEngine('jm');
      await SourceConfigStore.save(SourceConfig(
        engineId: c.engineId,
        id: c.id,
        name: c.name,
        hosts: c.hosts,
        imageHosts: c.imageHosts,
        proxy: '  socks5://127.0.0.1:1080  ',
      ));
      expect(await SourceHttp.proxyFor('jm'), 'socks5://127.0.0.1:1080');
    });

    test('空白代理配置视为未配置（返回 null）', () async {
      final c = await SourceConfigStore.byEngine('jm');
      await SourceConfigStore.save(SourceConfig(
        engineId: c.engineId,
        id: c.id,
        name: c.name,
        hosts: c.hosts,
        imageHosts: c.imageHosts,
        proxy: '   ',
      ));
      expect(await SourceHttp.proxyFor('jm'), isNull);
    });

    test('未知源返回 null 而非抛错', () async {
      expect(await SourceHttp.proxyFor('no_such_source'), isNull);
    });
  });
}