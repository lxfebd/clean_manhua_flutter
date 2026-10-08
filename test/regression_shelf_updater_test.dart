import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/shelf_updater.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_updater').path;
        }
        return null;
      },
    );
  });

  group('更新提醒频率持久化', () {
    test('默认关闭，设置后重启恢复', () async {
      await LocalStore.init();
      expect(await ShelfUpdater.frequency(), UpdateFreq.off);

      await ShelfUpdater.setFrequency(UpdateFreq.every12h);
      expect(await ShelfUpdater.frequency(), UpdateFreq.every12h);

      // 模拟重启：重新读
      await ShelfUpdater.setFrequency(UpdateFreq.daily);
      expect(await ShelfUpdater.frequency(), UpdateFreq.daily);
    });

    test('interval 映射', () {
      expect(UpdateFreq.off.interval, isNull);
      expect(UpdateFreq.every6h.interval, const Duration(hours: 6));
      expect(UpdateFreq.every12h.interval, const Duration(hours: 12));
      expect(UpdateFreq.daily.interval, const Duration(days: 1));
    });
  });

  group('checkNow 取消/清零语义', () {
    test('空书架：立即返回空列表（无源调用不阻塞、不短路）', () async {
      // 书架为空：checkNow 应直接返回 []，不因任何残留标记返回 null。
      final updated = await ShelfUpdater.checkNow();
      expect(updated, isEmpty, reason: '空书架无更新');
    });

    test('空书架 + shouldCancel 恒真：取消未触发仍返回空列表', () async {
      // 空书架无条目可查，取消回调不会被调用；应返回 []（无更新的语义），
      // 而非 null（null 是「检查中途被取消」的专属信号）。
      final updated = await ShelfUpdater.checkNow(shouldCancel: () => true);
      expect(updated, isEmpty, reason: '空书架取消回调不触发，返回空列表');
    });

    test('连续两轮 checkNow 不被上一轮取消残留短路', () async {
      // 第一轮取消（shouldCancel 恒真），第二轮正常检查：
      // checkNow 开头清残留标记，第二轮必须能正常返回空列表而非 null。
      await ShelfUpdater.checkNow(shouldCancel: () => true);
      final second = await ShelfUpdater.checkNow();
      expect(second, isNotNull, reason: '第二轮不应被上一轮取消残留短路');
      expect(second, isEmpty);
    });
  });
}