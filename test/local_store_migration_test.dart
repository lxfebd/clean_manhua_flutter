import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_migration');
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
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('LocalStore schema 迁移框架', () {
    test('init 后 schema_version 写入当前版本', () async {
      await LocalStore.init();
      final v = await LocalStore.readJson('schema_version');
      expect(v, LocalStore.schemaVersion);
    });

    test('重复 init 幂等：版本不倒退不重复写', () async {
      await LocalStore.init();
      final f = File('${tmp.path}/data/schema_version.json');
      final before = await f.readAsString();
      await LocalStore.init();
      expect(await f.readAsString(), before);
      final v = await LocalStore.readJson('schema_version');
      expect(v, LocalStore.schemaVersion);
    });

    test('旧版本文件升级：schema_version 从缺省推进到当前版', () async {
      // 清掉版本文件模拟老安装
      final f = File('${tmp.path}/data/schema_version.json');
      if (f.existsSync()) f.deleteSync();
      await LocalStore.init();
      expect(await LocalStore.readJson('schema_version'),
          LocalStore.schemaVersion);
    });
  });
}