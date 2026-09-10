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
}