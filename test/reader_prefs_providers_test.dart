import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/reader_prefs_providers.dart';

/// novel/comic 阅读偏好 provider 单元测试：默认值、resume 懒载持久化、
/// update 写回、update 相等短路（同值不写盘）。
///
/// LocalStore 经 path_provider mock 指向独立临时目录；每测试 resetForTest
/// 清静态目录缓存（_dir 首次 init 后缓存，跨测试复用会指向已删 tmpDir），
/// 与 reader_providers_test 同模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_reader_prefs');
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

  group('novelReaderPrefsProvider', () {
    test('默认值：六项与 LocalStore 缺省一致（未持久化）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prefs = container.read(novelReaderPrefsProvider);
      expect(prefs.fontSize, 17);
      expect(prefs.lineHeight, 180);
      expect(prefs.theme, 0);
      expect(prefs.paragraphGap, 18);
      expect(prefs.firstIndent, isTrue);
      expect(prefs.colorTemp, 0);
    });

    test('resume：读取持久化偏好并更新状态', () async {
      await LocalStore.setNovelReadSettings(
        fontSize: 22,
        lineHeight: 200,
        theme: 2,
        paragraphGap: 30,
        firstIndent: false,
        colorTemp: 40,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prefs =
          await container.read(novelReaderPrefsProvider.notifier).resume();
      expect(prefs.fontSize, 22);
      expect(prefs.lineHeight, 200);
      expect(prefs.theme, 2);
      expect(prefs.paragraphGap, 30);
      expect(prefs.firstIndent, isFalse);
      expect(prefs.colorTemp, 40);
      expect(container.read(novelReaderPrefsProvider).fontSize, 22);
    });

    test('resume 幂等：已 resume 后不再重复读盘覆盖新值', () async {
      await LocalStore.setNovelReadSettings(fontSize: 20);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(novelReaderPrefsProvider.notifier);
      await notifier.update(fontSize: 16);
      // 第二次 resume 不得用持久化旧值覆盖当前状态。
      await notifier.resume();
      expect(container.read(novelReaderPrefsProvider).fontSize, 16);
    });

    test('update：单项更新状态并写回持久化（其余项保持）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(novelReaderPrefsProvider.notifier)
          .update(fontSize: 20, colorTemp: 50);
      expect(container.read(novelReaderPrefsProvider).fontSize, 20);
      expect(container.read(novelReaderPrefsProvider).colorTemp, 50);
      expect(container.read(novelReaderPrefsProvider).lineHeight, 180,
          reason: '未更新的字段保持默认值');
      expect(await LocalStore.novelFontSize(), 20);
      expect(await LocalStore.novelColorTemp(), 50);
    });

    test('update 相等短路：同值不写盘', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(novelReaderPrefsProvider.notifier)
          .update(fontSize: 17);
      // 仍为默认 17；且持久化保持未设置（缺省=17，未写入）。
      expect(container.read(novelReaderPrefsProvider).fontSize, 17);
      expect(await LocalStore.novelFontSize(), 17);
      expect(
        await LocalStore.novelLineHeight(),
        180,
        reason: '同值 update 不应触发任何写盘（整表未生成）',
      );
    });
  });

  group('comicReaderPrefsProvider', () {
    test('默认值：四项与 LocalStore 缺省一致（未持久化）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prefs = container.read(comicReaderPrefsProvider);
      expect(prefs.rtl, isFalse);
      expect(prefs.resLevel, 0);
      expect(prefs.autoPage, 0);
      expect(prefs.trimBorder, isFalse);
    });

    test('resume：读取持久化偏好并更新状态', () async {
      await LocalStore.setRtlReader(true);
      await LocalStore.setResLevel(2);
      await LocalStore.setTrimBorder(true);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prefs =
          await container.read(comicReaderPrefsProvider.notifier).resume();
      expect(prefs.rtl, isTrue);
      expect(prefs.resLevel, 2);
      expect(prefs.trimBorder, isTrue);
      expect(container.read(comicReaderPrefsProvider).rtl, isTrue);
    });

    test('resume 幂等：已 resume 后不再重复读盘覆盖新值', () async {
      await LocalStore.setResLevel(2);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(comicReaderPrefsProvider.notifier);
      await notifier.update(resLevel: 1);
      await notifier.resume();
      expect(container.read(comicReaderPrefsProvider).resLevel, 1);
    });

    test('update：单项更新状态并写回持久化（其余项保持）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(comicReaderPrefsProvider.notifier)
          .update(rtl: true, autoPage: 5);
      expect(container.read(comicReaderPrefsProvider).rtl, isTrue);
      expect(container.read(comicReaderPrefsProvider).autoPage, 5);
      expect(container.read(comicReaderPrefsProvider).resLevel, 0,
          reason: '未更新的字段保持默认值');
      expect(await LocalStore.rtlReader(), isTrue);
      expect(await LocalStore.autoPageTurn(), 5);
    });

    test('update 相等短路：同值不写盘', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(comicReaderPrefsProvider.notifier)
          .update(trimBorder: false);
      // 仍为默认 false；且持久化保持未设置（缺省=false，未写入）。
      expect(container.read(comicReaderPrefsProvider).trimBorder, isFalse);
      expect(await LocalStore.trimBorder(), isFalse);
      expect(await LocalStore.resLevel(), 0,
          reason: '同值 update 不应触发任何写盘（settings 表未生成）');
    });
  });
}