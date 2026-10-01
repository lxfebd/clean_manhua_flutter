import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/reader_mode_geometry.dart';
import 'package:xingmanxia/ui/reader_providers.dart';

/// readerModeProvider 单元测试：默认值、resume 懒载持久化、setMode 写回。
///
/// LocalStore 经 path_provider mock 指向独立临时目录；每测试
/// resetForTest 清静态目录缓存（_dir 首次 init 后缓存，跨测试复用会指向
/// 已删 tmpDir），与 detail_providers_test 同模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_reader_providers');
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

  group('readerModeProvider', () {
    test('默认值：单页横向（未持久化）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(readerModeProvider), ReaderMode.single);
    });

    test('resume：读取持久化偏好并更新状态', () async {
      await LocalStore.setReaderMode(ReaderMode.double.value);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final mode = await container.read(readerModeProvider.notifier).resume();
      expect(mode, ReaderMode.double);
      expect(container.read(readerModeProvider), ReaderMode.double);
    });

    test('resume 幂等：已 resume 后不再重复读盘覆盖新值', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(readerModeProvider.notifier);
      await notifier.setMode(ReaderMode.vertical);
      // 第二次 resume 不得用持久化旧值覆盖当前状态。
      await notifier.resume();
      expect(container.read(readerModeProvider), ReaderMode.vertical);
    });

    test('setMode：更新状态并写回持久化', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(readerModeProvider.notifier)
          .setMode(ReaderMode.double);
      expect(container.read(readerModeProvider), ReaderMode.double);
      expect(await LocalStore.readerMode(), ReaderMode.double.value);
    });

    test('setMode 相等短路：同值不写盘', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(readerModeProvider.notifier)
          .setMode(ReaderMode.single);
      // 仍为默认单页；且持久化保持未设置（旧 horizontal 映射缺省=0，未写入）。
      expect(container.read(readerModeProvider), ReaderMode.single);
      expect(await LocalStore.readerMode(), 0);
    });
  });
}