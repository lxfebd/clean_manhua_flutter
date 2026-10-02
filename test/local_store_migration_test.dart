import 'dart:convert';
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

    test('v2 迁移：video_progress 的 `::` key 改写为 `/` 分隔（P2-15）', () async {
      // 模拟 v1 安装：先写旧格式进度 + 版本 1，再 init 触发迁移。
      final dir = '${tmp.path}/data';
      Directory(dir).createSync(recursive: true);
      File('$dir/video_progress.json').writeAsStringSync(jsonEncode({
        'src::vid::1-3': 42,
        'src::vid2::2-1': 15,
      }));
      File('$dir/schema_version.json').writeAsStringSync(jsonEncode(1));
      await LocalStore.init();
      final raw = await LocalStore.readJson('video_progress') as Map;
      expect(raw, {'src/vid/1-3': 42, 'src/vid2/2-1': 15});
      expect(raw.keys.any((k) => k.contains('::')), isFalse);
    });

    test('v2 迁移幂等：已是 `/` 分隔时不改写', () async {
      final dir = '${tmp.path}/data';
      Directory(dir).createSync(recursive: true);
      File('$dir/video_progress.json').writeAsStringSync(jsonEncode({
        'src/vid/1-3': 42,
      }));
      File('$dir/schema_version.json').writeAsStringSync(jsonEncode(1));
      await LocalStore.init();
      expect(await LocalStore.readJson('video_progress'),
          {'src/vid/1-3': 42});
    });

    test('restoreBackup 恢复旧备份时同步改写 video_progress key', () async {
      await LocalStore.init();
      await LocalStore.restoreBackup({
        'video_progress': {'a::b::1-1': 30, 'c::d::2-1': 12},
        'video_records': null,
        'history': null,
        'favorites': null,
        'bookmarks': null,
        'downloads': null,
      });
      final raw = await LocalStore.readJson('video_progress') as Map;
      expect(raw, {'a/b/1-1': 30, 'c/d/2-1': 12});
      expect(raw.keys.any((k) => k.contains('::')), isFalse);
    });
  });
}