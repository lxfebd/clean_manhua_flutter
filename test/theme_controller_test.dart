import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/style_scope.dart';
import 'package:xingmanxia/ui/theme_controller.dart';

/// Riverpod 渐进批次 C：主题/风格全局状态（ThemeController）回归。
///
/// 迁移前：YingManHeAppState 四字段 + setState；迁移后：StateNotifier +
/// themeControllerProvider。本测试守卫：
/// 1. 默认值 = 浅色/种子色0/跟随平台/未装载（首帧不闪深色语义）；
/// 2. load() 从 LocalStore 恢复并置 loaded=true；
/// 3. 三个 setter 同步改内存（UI 立即重建），持久化由调用方负责；
/// 4. effectiveStyle 跟随平台解析。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var tempDir = '';

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xm_theme_ctl').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getApplicationSupportDirectory' ? tempDir : null,
    );
    LocalStore.resetForTest();
  });

  tearDown(() {
    LocalStore.resetForTest();
    try {
      if (tempDir.isNotEmpty && Directory(tempDir).existsSync()) {
        Directory(tempDir).deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('ThemeController 默认值', () {
    test('未装载：浅色 / 种子色0 / 跟随平台 / loaded=false（首帧不闪深色）', () {
      final c = makeContainer();
      final s = c.read(themeControllerProvider);
      expect(s.themeMode, ThemeMode.light);
      expect(s.themeId, 0);
      expect(s.uiStyleOverride, isNull);
      expect(s.loaded, isFalse);
      // 跟随平台：测试环境 defaultTargetPlatform 是 android → 小米风格
      expect(s.effectiveStyle, UIStyle.forPlatform(defaultTargetPlatform));
    });
  });

  group('ThemeController.load 持久化恢复', () {
    test('恢复深色/种子色/固定风格，loaded=true', () async {
      await LocalStore.init();
      await LocalStore.setDarkMode(true);
      await LocalStore.setThemeId(2);
      await LocalStore.setUiStyle('apple');
      final c = makeContainer();
      await c.read(themeControllerProvider.notifier).load();
      final s = c.read(themeControllerProvider);
      expect(s.themeMode, ThemeMode.dark);
      expect(s.themeId, 2);
      expect(s.uiStyleOverride, UIStyle.apple);
      expect(s.loaded, isTrue);
    });

    test('默认值（无持久化）：保持浅色，loaded=true', () async {
      await LocalStore.init();
      final c = makeContainer();
      await c.read(themeControllerProvider.notifier).load();
      final s = c.read(themeControllerProvider);
      expect(s.themeMode, ThemeMode.light);
      expect(s.themeId, 0);
      expect(s.uiStyleOverride, isNull);
      expect(s.loaded, isTrue);
    });
  });

  group('ThemeController setter', () {
    test('setDark 同步改 themeMode，loaded 保持', () {
      final c = makeContainer();
      c.read(themeControllerProvider.notifier).setDark(true);
      expect(c.read(themeControllerProvider).themeMode, ThemeMode.dark);
      c.read(themeControllerProvider.notifier).setDark(false);
      expect(c.read(themeControllerProvider).themeMode, ThemeMode.light);
    });

    test('setThemeId 同步改 seed 色', () {
      final c = makeContainer();
      c.read(themeControllerProvider.notifier).setThemeId(3);
      expect(c.read(themeControllerProvider).themeId, 3);
    });

    test('setUiStyle 固定风格 / null 恢复跟随平台', () {
      final c = makeContainer();
      c.read(themeControllerProvider.notifier).setUiStyle(UIStyle.minimalist);
      expect(c.read(themeControllerProvider).uiStyleOverride, UIStyle.minimalist);
      c.read(themeControllerProvider.notifier).setUiStyle(null);
      expect(c.read(themeControllerProvider).uiStyleOverride, isNull);
      expect(
        c.read(themeControllerProvider).effectiveStyle,
        UIStyle.forPlatform(defaultTargetPlatform),
      );
    });
  });

  group('widget 接线（ProviderScope 内 watch 重建）', () {
    testWidgets('ProviderContainer 下切换深色 → watch 侧收到新状态',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      late ThemeState seen;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: Consumer(builder: (context, ref, _) {
          seen = ref.watch(themeControllerProvider);
          return const SizedBox();
        }),
      ));
      c.read(themeControllerProvider.notifier).setDark(true);
      await tester.pump();
      expect(seen.themeMode, ThemeMode.dark);
    });
  });
}
