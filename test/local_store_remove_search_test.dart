import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

/// LocalStore.removeSearchHistory 单测：按关键词精确删除单条搜索历史，
/// 其余条目与顺序保留（去重后 10 条上限语义同 addSearchHistory）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_rm_search');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmpDir.path;
        }
        return null;
      },
    );
    LocalStore.resetForTest();
    await LocalStore.init();
  });

  tearDown(() async {
    if (tmpDir.existsSync()) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('删除单条后其余保留且顺序不变', () async {
    await LocalStore.addSearchHistory('海贼王');
    await LocalStore.addSearchHistory('火影忍者');
    await LocalStore.addSearchHistory('死神');
    await LocalStore.removeSearchHistory('火影忍者');
    final h = await LocalStore.searchHistory();
    expect(h, ['死神', '海贼王']);
  });

  test('删除不存在的关键词不影响列表', () async {
    await LocalStore.addSearchHistory('海贼王');
    await LocalStore.removeSearchHistory('不存在');
    expect(await LocalStore.searchHistory(), ['海贼王']);
  });

  test('删除重复关键词只删一次（去重后列表内唯一）', () async {
    await LocalStore.addSearchHistory('海贼王');
    await LocalStore.removeSearchHistory('海贼王');
    expect(await LocalStore.searchHistory(), isEmpty);
  });

  test('空/空白关键词不触发写入', () async {
    await LocalStore.addSearchHistory('海贼王');
    await LocalStore.removeSearchHistory('');
    await LocalStore.removeSearchHistory('   ');
    expect(await LocalStore.searchHistory(), ['海贼王']);
  });

  test('删除全部后列表为空（等价清空）', () async {
    await LocalStore.addSearchHistory('A');
    await LocalStore.addSearchHistory('B');
    await LocalStore.removeSearchHistory('A');
    await LocalStore.removeSearchHistory('B');
    expect(await LocalStore.searchHistory(), isEmpty);
  });
}
