import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/utils/colorizer_backend.dart';
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

  group('DDColor 全链路（fake backend）', () {
    test('灰度进 → 彩色出：长度正确、输出带色差', () async {
      // 构造一个 fake backend：输入 1×3×256×256 → 输出固定 ab 模式。
      final m = ColorizerManager.instance;
      _installFakeBackend(m);
      // 纯灰渐变 64×64 RGB。
      final w = 64, h = 64;
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        final v = (i * 255 ~/ (w * h)).clamp(0, 255);
        rgb[i * 3] = v;
        rgb[i * 3 + 1] = v;
        rgb[i * 3 + 2] = v;
      }
      final out = await m.colorize(rgb, w, h);
      expect(out, isNotNull);
      expect(out!.length, w * h * 3);
      // fake ab=+1.0 → 应有明显红蓝差（a 通道驱动）。
      var maxDiff = 0;
      for (var i = 0; i < w * h; i++) {
        final p = i * 3;
        final d = (out[p] - out[p + 2]).abs();
        if (d > maxDiff) maxDiff = d;
      }
      expect(maxDiff, greaterThan(0), reason: 'ab≠0 时输出应带颜色');
    });

    test('大图自动走分块推理：每块一次推理、输出同尺寸、带色差', () async {
      final m = ColorizerManager.instance;
      final fake = _FakeDdcolorBackend();
      m.backendForTest = fake;
      // 300×300 纯灰图（>256 → 分块：stride 240，tilesX=2、tilesY=2 共 4 块）。
      final w = 300, h = 300;
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        final v = (i * 255 ~/ (w * h)).clamp(0, 255);
        final p = i * 3;
        rgb[p] = v;
        rgb[p + 1] = v;
        rgb[p + 2] = v;
      }
      final out = await m.colorize(rgb, w, h);
      expect(out, isNotNull);
      expect(out!.length, w * h * 3);
      // 分块 = 每块一次 inferAsync（单遍缩放只会是 1 次）。
      expect(fake.calls, greaterThan(1), reason: '大图应走分块推理而非单遍缩放');
      // 输出整体带色差（fake ab=+1/-1 驱动）。
      var maxDiff = 0;
      for (var i = 0; i < w * h; i++) {
        final p = i * 3;
        final d = (out[p] - out[p + 2]).abs();
        if (d > maxDiff) maxDiff = d;
      }
      expect(maxDiff, greaterThan(0), reason: 'ab≠0 时输出应带颜色');
    });

    test('分块拼接区颜色连续（余弦羽化无接缝跳变）', () async {
      final m = ColorizerManager.instance;
      final fake = _FakeDdcolorBackend();
      m.backendForTest = fake;
      final w = 300, h = 300;
      final rgb = Uint8List(w * h * 3);
      // 恒定灰度 → fake ab 恒定 → 全图理论同色；接缝处若有未归一化/黑边
      // 会出跳变。断言接缝左右/上下相邻像素色差小（≤ 阈值防脆弱）。
      for (var i = 0; i < w * h; i++) {
        final p = i * 3;
        rgb[p] = 128;
        rgb[p + 1] = 128;
        rgb[p + 2] = 128;
      }
      final out = (await m.colorize(rgb, w, h))!;
      // 接缝列 x=240（两块重叠区中心）+ 行方向采样，对比相邻像素。
      var maxJump = 0;
      for (var y = 10; y < h - 10; y++) {
        final p0 = (y * w + 240) * 3;
        final pL = (y * w + 239) * 3;
        final pR = (y * w + 241) * 3;
        final jl = (out[p0] - out[pL]).abs();
        final jr = (out[p0] - out[pR]).abs();
        if (jl > maxJump) maxJump = jl;
        if (jr > maxJump) maxJump = jr;
      }
      // 恒定 ab + 恒定灰度 → 理论最大跳变 0；容差 6（round/clamp 噪声）。
      expect(maxJump, lessThanOrEqualTo(6),
          reason: '重叠区羽化后接缝不应出现明显跳变，实测 maxJump=$maxJump');
    });

    test('输入长度不符 → 返回 null 不抛', () async {
      final m = ColorizerManager.instance;
      _installFakeBackend(m);
      final out = await m.colorize(Uint8List(5), 2, 2); // 长度错
      expect(out, isNull);
    });

    test('colorizeJpeg 整图字节进：解码/重编码不占主 isolate，输出可解码且带色差', () async {
      final m = ColorizerManager.instance;
      _installFakeBackend(m);
      // 生成一张 64×64 纯灰 PNG（灰度图：R=G=B）。
      final w = 64, h = 64;
      final im = img.Image(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = (x + y) * 255 ~/ (w + h - 2);
          im.setPixelRgb(x, y, v, v, v);
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(im));
      final out = await m.colorizeJpeg(bytes);
      expect(out, isNotNull);
      // 输出应是可解码 JPEG，尺寸不变。
      final dec = img.decodeImage(out!);
      expect(dec, isNotNull);
      expect(dec!.width, w);
      expect(dec.height, h);
      // fake ab=+1.0 → 应有明显红蓝差。
      var maxDiff = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = dec.getPixel(x, y);
          final d = (p.r.toInt() - p.b.toInt()).abs();
          if (d > maxDiff) maxDiff = d;
        }
      }
      expect(maxDiff, greaterThan(0), reason: 'ab≠0 时输出应带颜色');
    });

    test('colorizeJpeg 大图自动走分块（多块推理、尺寸不变）', () async {
      final m = ColorizerManager.instance;
      final fake = _FakeDdcolorBackend();
      m.backendForTest = fake;
      // 300×300 纯灰 PNG（>256 → 分块 4 次推理）。
      final w = 300, h = 300;
      final im = img.Image(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = (x + y) * 255 ~/ (w + h - 2);
          im.setPixelRgb(x, y, v, v, v);
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(im));
      final out = await m.colorizeJpeg(bytes);
      expect(out, isNotNull);
      expect(fake.calls, greaterThan(1), reason: '大图应走分块推理');
      final dec = img.decodeImage(out!);
      expect(dec, isNotNull);
      expect(dec!.width, w);
      expect(dec.height, h);
    });

    test('colorizeJpeg 未加载 → 返回 null（不抛、不触发推理）', () async {
      final m = ColorizerManager.instance;
      await m.ensureLoaded(); // 无模型 → isAvailable false
      final out = await m.colorizeJpeg(Uint8List.fromList([0, 1, 2]));
      expect(out, isNull);
    });
  });
}

/// 给 manager 装上返回固定 ab 的 fake backend（走真实 DDColor 前后处理）。
void _installFakeBackend(ColorizerManager m) {
  // 反射注入不可取；改为给 manager 提供可替换的后端工厂钩子。
  // 见 colorizer_manager.dart 顶部 `@visibleForTesting set backendForTest`。
  m.backendForTest = _FakeDdcolorBackend();
}

class _FakeDdcolorBackend implements ColorizerBackend {
  /// 推理调用次数（区分分块多遍与单遍缩放）。
  int calls = 0;

  @override
  bool get isAvailable => true;

  @override
  void load(String modelPath) {}

  @override
  Future<void> loadAsync() async {}

  @override
  Future<Float32List> inferAsync(Float32List inputTensor) async {
    calls++;
    // 返回固定 ab：a=+1, b=-1（256×256 平铺）。
    final out = Float32List(1 * 2 * 256 * 256);
    for (var i = 0; i < 256 * 256; i++) {
      out[i * 2] = 1.0;
      out[i * 2 + 1] = -1.0;
    }
    return out;
  }

  @override
  void dispose() {}
}