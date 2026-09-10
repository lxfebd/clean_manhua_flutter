import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

/// 阅读模式（纵向/单页/双页）相关回归：
/// readerMode 持久化、老用户 horizontal 布尔迁移。
/// 注：LocalStore 的目录在进程内只解析一次，全部断言放同一 test 保证顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 打桩：LocalStore 落到临时目录（单元测试无插件通道）。
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_reader_mode').path;
        }
        return null;
      },
    );
  });

  setUp(() => LocalStore.init());

  test('readerMode 持久化 + 老用户 horizontal 迁移（顺序敏感）', () async {
    // 全新环境（临时目录刚创建）：默认纵向滚动
    expect(await LocalStore.readerMode(), 0, reason: '新用户默认纵向滚动');

    // 老用户迁移：从未写过 readerMode，只有 horizontal=true → 单页横向
    await LocalStore.setHorizontalReader(true);
    expect(await LocalStore.readerMode(), 1);

    await LocalStore.setHorizontalReader(false);
    expect(await LocalStore.readerMode(), 0);

    // 显式 readerMode 优先于旧布尔
    await LocalStore.setHorizontalReader(false);
    await LocalStore.setReaderMode(2);
    expect(await LocalStore.readerMode(), 2);

    await LocalStore.setReaderMode(1);
    expect(await LocalStore.readerMode(), 1);

    await LocalStore.setReaderMode(0);
    expect(await LocalStore.readerMode(), 0);
  });
}
