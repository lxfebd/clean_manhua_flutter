import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/utils/colorizer_manager.dart';

/// 漫画上色管理器状态机单测。
///
/// 覆盖（不含真实模型/真推理，VM 测试不触发 tflite FFI）：
/// - 默认关闭；无模型文件 → isAvailable false、ensureLoaded 不加载；
/// - importModel 源文件不存在 → 返回 false、保持不可用；
/// - colorize 在模型未加载时返回 null（不抛、不崩溃，调用方降级原图）；
/// - 加载失败降级（路径存在但 load 抛异常 → isAvailable false）。
///
/// 打桩 path_provider：模型/存储均落到临时目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
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

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('xm_colorizer');
    await LocalStore.init();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('默认状态', () {
    test('未加载前不可用、未启用、模型路径为空', () {
      final m = ColorizerManager.instance;
      expect(m.isAvailable, isFalse);
      expect(m.enabled, isFalse); // 默认关
      expect(m.modelPath, isNull);
    });

    test('restore 无存储记录 → 保持关闭', () async {
      final m = ColorizerManager.instance;
      await m.restore();
      expect(m.enabled, isFalse);
    });
  });

  group('无模型文件', () {
    test('ensureLoaded 缺模型 → 不可用且不加载（不触发 tflite）', () async {
      final m = ColorizerManager.instance;
      await m.ensureLoaded();
      expect(m.isAvailable, isFalse);
      expect(m.modelPath, isNull);
    });

    test('colorize 未加载 → 返回 null（调用方降级原图）', () async {
      final m = ColorizerManager.instance;
      await m.ensureLoaded();
      final out = await m.colorize(Uint8List(12), 2, 2);
      expect(out, isNull);
    });
  });

  group('importModel 失败路径', () {
    test('源文件不存在 → 返回 false、保持不可用', () async {
      final m = ColorizerManager.instance;
      final ok = await m.importModel('${tmp.path}/no_such_model.tflite');
      expect(ok, isFalse);
      expect(m.isAvailable, isFalse);
    });
  });

  group('加载失败降级', () {
    test('模型文件存在但 load 抛异常 → catch 降级为不可用', () async {
      // 放一个非法的"模型"文件（非 tflite），使 Interpreter.fromFile 抛异常。
      final dir = Directory('${tmp.path}/colorizer')..createSync(recursive: true);
      File('${dir.path}/model.tflite').writeAsStringSync('not a tflite file');
      final m = ColorizerManager.instance;
      await m.ensureLoaded();
      expect(m.isAvailable, isFalse);
      expect(m.modelPath, isNull);
    });
  });

  group('低端机探测', () {
    test('isLowEndDevice 在 VM 下不崩溃、返回 bool', () async {
      final low = await ColorizerManager.isLowEndDevice();
      expect(low, isA<bool>());
    });
  });
}