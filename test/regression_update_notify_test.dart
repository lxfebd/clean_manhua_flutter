import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/update_notifier.dart';

/// 书架更新推送回归：开关持久化、24h 冷却去重、通知触发路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 打桩（同 regression_settings_download_test 模式）。
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_notify').path;
        }
        return null;
      },
    );
    // 原生通知通道打桩：记录调用，不断言原生侧。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xingmanxia/update_notification'),
      (call) async => null,
    );
  });

  setUp(() async {
    await LocalStore.init();
    await UpdateNotifier.setEnabled(false);
    await LocalStore.writeJson('update_notify_last', <String, dynamic>{});
  });

  test('开关默认关闭，setEnabled 持久化', () async {
    expect(await UpdateNotifier.enabled(), isFalse);
    await UpdateNotifier.setEnabled(true);
    expect(await UpdateNotifier.enabled(), isTrue);
  });

  test('24h 冷却：同作品提醒后 withinCooldown 为 true', () async {
    final now = DateTime(2026, 9, 9, 12);
    await UpdateNotifier.markNotified('作品A', now);
    expect(await UpdateNotifier.withinCooldown('作品A', now), isTrue);
    // 23 小时后仍在冷却内
    expect(
        await UpdateNotifier.withinCooldown(
            '作品A', now.add(const Duration(hours: 23))),
        isTrue);
    // 25 小时后过期
    expect(
        await UpdateNotifier.withinCooldown(
            '作品A', now.add(const Duration(hours: 25))),
        isFalse);
    // 未记录过的作品不在冷却内
    expect(await UpdateNotifier.withinCooldown('作品B', now), isFalse);
  });

  test('冷却期外的新作品可通知，冷却内作品被过滤', () async {
    final now = DateTime(2026, 9, 9, 12);
    await UpdateNotifier.markNotified('作品A', now);
    final names = ['作品A', '作品C'];
    // 直接测冷却过滤逻辑（notifyShelfUpdate 走原生通道，开启开关后调用不抛错）
    await UpdateNotifier.setEnabled(true);
    var invoked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xingmanxia/update_notification'),
      (call) async {
        if (call.method == 'showShelfUpdate') {
          invoked++;
          final args = call.arguments as Map;
          expect(args['names'], ['作品C']); // 作品A 冷却内被过滤
        }
        return null;
      },
    );
    await UpdateNotifier.instance.notifyShelfUpdate(names);
    expect(invoked, 1);
  });

  test('开关关闭时不发通知', () async {
    await UpdateNotifier.setEnabled(false);
    var invoked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xingmanxia/update_notification'),
      (call) async {
        if (call.method == 'showShelfUpdate') invoked++;
        return null;
      },
    );
    await UpdateNotifier.instance.notifyShelfUpdate(['作品X']);
    expect(invoked, 0);
  });
}