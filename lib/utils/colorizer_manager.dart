import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'colorizer.dart';
import 'colorizer_backend.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';

/// 漫画上色管理：负责模型文件的检测/加载/卸载、互斥锁保护、超时降级。
///
/// 模型文件不内置（体积大 + 授权不明），由用户放到应用文档目录
/// `colorizer/model.tflite`（或通过 UI 从文件选择器导入）。
/// - 缺模型 / web 平台 / 加载失败 → [isAvailable] false，UI 禁用入口；
/// - [colorize] 全程互斥锁 + 超时（照 image_super_res 模板），
///   失败（超时/模型坏/推理异常）时降级返回原图并记日志，不抛到 UI。
/// - 默认关闭；仅 io 平台 + 存在模型 + RAM≥4GB 时入口可用
///   （低端机隐藏，用户评审要求）。
class ColorizerManager {
  ColorizerManager._();
  static final ColorizerManager instance = ColorizerManager._();

  static const _modelDir = 'colorizer';
  static const _modelFile = 'model.tflite';

  /// 推理互斥锁：同刻只跑一个推理（模型非线程安全 + 控内存峰值）。
  Completer<void>? _mutex;
  ColorizerBackend? _backend;
  bool _available = false;
  String? _modelPath;
  bool _enableChecked = false;
  bool _enable = false;

  /// 推理最坏耗时（compute 超时）。
  static const Duration _computeTimeout = Duration(minutes: 2);
  /// 锁等待超时：必须 > [_computeTimeout]（照超分模板防锁对象覆盖错配）。
  static const Duration _acquireTimeout = Duration(minutes: 2, seconds: 30);

  /// 是否可用（模型已加载且引擎就绪）。
  bool get isAvailable => _available;

  /// 当前已加载模型路径（用于 UI 显示）。
  String? get modelPath => _modelPath;

  /// 测试钩子：注入 fake 后端走真实 DDColor 前后处理管线。
  @visibleForTesting
  set backendForTest(ColorizerBackend b) {
    _backend = b;
    _available = true;
    _enableChecked = true;
  }

  /// 是否启用（设置项；默认关）。
  bool get enabled => _enable;
  Future<void> setEnabled(bool on) async {
    _enable = on;
    await LocalStore.writeJson('colorizer_enabled', on);
  }

  /// 启动时恢复开关状态（main 调用一次）。
  Future<void> restore() async {
    try {
      final j = await LocalStore.readJson('colorizer_enabled');
      _enable = j is bool ? j : false;
    } catch (_) {
      _enable = false;
    }
  }

  /// 探测模型文件是否存在（懒调用；存在则 load，失败降级为不可用）。
  /// 同时恢复开关状态（UI 可能先于设置页触发，如阅读器 initState）。
  Future<void> ensureLoaded() async {
    if (_enableChecked) return;
    _enableChecked = true;
    await restore();
    if (kIsWeb) {
      // web 条件导出即 stub：createColorizerBackend 返回永远不可用的空实现。
      _backend ??= createColorizerBackend();
      _available = false;
      return;
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_modelDir/$_modelFile');
      if (!f.existsSync()) {
        _available = false;
        return;
      }
      _backend ??= createColorizerBackend();
      _backend!.load(f.path);
      await _backend!.loadAsync();
      _modelPath = f.path;
      _available = _backend!.isAvailable;
    } catch (e) {
      ErrorLogger.instance.warn('Colorizer 模型加载失败: $e');
      _available = false;
    }
  }

  /// 从用户选择的文件导入模型（复制到应用文档目录）。
  Future<bool> importModel(String sourcePath) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final d = Directory('${dir.path}/$_modelDir');
      if (!d.existsSync()) d.createSync(recursive: true);
      final target = File('${d.path}/$_modelFile');
      File(sourcePath).copySync(target.path);
      _enableChecked = false;
      await ensureLoaded();
      return _available;
    } catch (e) {
      ErrorLogger.instance.warn('Colorizer 模型导入失败: $e');
      _available = false;
      return false;
    }
  }

  /// 卸载模型（释放内存）。
  Future<void> unload() async {
    _backend?.dispose();
    _backend = null;
    _available = false;
    _modelPath = null;
    _enableChecked = false;
  }

  /// 对单张图执行上色：入参为解码后的 RGB 像素（长度 w*h*3，无 alpha）。
  /// 返回同尺寸 RGB 像素（长度 w*h*3）。失败/超时/未加载 → 返回 null
  /// （调用方降级原图）。
  /// 注意：输入必须是 RGB（3 字节/像素），RGBA 需先由调用方剥离 alpha。
  ///
  /// 内部按 DDColor（256×256，Apache-2.0）契约执行：
  /// 1) RGB 像素 → Lab 空间的 L 通道（BT.601 灰度为近似亮度）；
  /// 2) 双线性缩放到 256×256，张量 [1,3,256,256]（L/50-1，ab=0）；
  /// 3) 推理得 ab [1,2,256,256]（约 ±2）；
  /// 4) ab×110 还原 Lab，与 L 合成 → Lab→RGB；
  /// 5) 缩回原尺寸返回。
  Future<Uint8List?> colorize(Uint8List rgb, int w, int h) async {
    if (!_available || _backend == null) return null;
    // 互斥锁：同刻只跑一个推理。锁等待恢复后必须**重新检查**锁对象——
    // 等待期间别人可能已拿到锁并换了新锁，若直接覆盖会造成两个推理并发
    // （tflite_flutter 0.12.1 的 runForMultipleInputs 对并发请求静默 skip，
    // 输出残留全 0 → 永久灰度页）。因此用「等待→复查→再等」循环代替一次性等待。
    while (true) {
      final m = _mutex;
      if (m == null || m.isCompleted) {
        // 无锁或锁已释放：尝试抢锁。Dart 单线程下检查+赋值同步原子，
        // 只有真正抢到才跳出循环（_mutex 仍是 null 才设为自己）。
        if (_mutex == null) {
          final mine = _mutex = Completer<void>();
          try {
            return await _timedInfer(rgb, w, h);
          } finally {
            mine.complete();
            if (identical(_mutex, mine)) _mutex = null;
          }
        }
        // 竞态窗口：刚被并发者抢走，回到循环头重新检查。
        continue;
      }
      // 有人在跑：等它释放，然后回到循环头复查（不直接覆盖锁）。
      var timedOut = false;
      await m.future.timeout(_acquireTimeout, onTimeout: () {
        timedOut = true;
      });
      if (timedOut) {
        ErrorLogger.instance.warn('Colorizer 等待推理锁超时，跳过本次');
        return null;
      }
    }
  }

  Future<Uint8List?> _timedInfer(Uint8List rgb, int w, int h) async {
    // skip（IsolateInterpreter 并发污染：state=loading 时 runForMultipleInputs
    // 静默 return，输出 tensor 保持全 0/残留，耗时 <100ms）不是模型失败，
    // 是上一帧推理还没结束时又调了一次——等待重试即可，不能降级原图。
    // 降级会置 _colorized=true 让该页永久灰。
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final sw = Stopwatch()..start();
        final out = await _inferDdcolor(rgb, w, h)
            .timeout(_computeTimeout, onTimeout: () {
          ErrorLogger.instance.warn('Colorizer 推理超时，降级原图');
          throw TimeoutException('Colorizer 推理超时');
        });
        ErrorLogger.instance
            .info('Colorizer 推理完成 ${w}x$h 耗时 ${sw.elapsedMilliseconds}ms');
        return out;
      } catch (e) {
        // 超时/模型错误：真失败，返回 null 降级。
        if (e is TimeoutException || !_isSkipError(e)) {
          ErrorLogger.instance.warn('Colorizer 推理失败: $e');
          return null;
        }
        ErrorLogger.instance.warn('Colorizer 推理 skip 第${attempt + 1}次，'
            '等待重试: $e');
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
    return null;
  }

  /// 判断异常是否为 IsolateInterpreter skip（<100ms 快速返回，输出残留）。
  static bool _isSkipError(Object e) {
    final s = e.toString();
    return s.contains('IsolateInterpreter skip');
  }

  /// DDColor 全链路（纯 Dart，可单测）。内部固定 256×256 推理。
  /// 三段式：前处理（灰度+缩放）→ 推理（IsolateInterpreter）→ 后处理
  /// （Lab→RGB+放大），前/后处理各包一层 [Isolate.run]，不占主 isolate。
  Future<Uint8List> _inferDdcolor(Uint8List rgb, int w, int h) async {
    const side = 256;
    final n = w * h;
    if (rgb.length != n * 3) {
      throw StateError('RGB 像素长度不符: ${rgb.length} != $n*3');
    }
    // 1)+2) 灰度（BT.601 亮度）→ 双线性缩放到 side×side，按 DDColor 契约组输入：
    // 通道0 = L 归一化到 [0,1]（L=100*gray），通道1、2 = 0（ab 输入无意义，预测目标）。
    // 放 Isolate.run：主 isolate 只传数组、收结果。
    // 契约已用 Python 探针在真 tflite 模型上实测锁定（见 .model_cache/probe2.py）：
    // 五种输入方案只有 gray[0,1]+ab0 输出健康 ab（a[-23,49] b[-43,69]，彩色）,
    // 其余（gray×3、L/50-1、imagenet mean/std）全部近零 → 灰度图。之前
    // 「三通道不同 mean/std」结论来自 gPU 路径的残留输出假象，已证伪。
    final inF = await Isolate.run(() {
      final grayMap = Float32List(n);
      for (var i = 0; i < n; i++) {
        final p = i * 3;
        grayMap[i] =
            (rgb[p] * 0.299 + rgb[p + 1] * 0.587 + rgb[p + 2] * 0.114) / 255.0;
      }
      final inF = Float32List(1 * 3 * side * side);
      final s = side.toDouble();
      final wD = w.toDouble();
      final hD = h.toDouble();
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final gx = (x + 0.5) * wD / s - 0.5;
          final gy = (y + 0.5) * hD / s - 0.5;
          final x0 = gx.clamp(0, w - 1).toInt();
          final y0 = gy.clamp(0, h - 1).toInt();
          final x1 = (x0 + 1).clamp(0, w - 1);
          final y1 = (y0 + 1).clamp(0, h - 1);
          final fx = gx - x0;
          final fy = gy - y0;
          final v00 = grayMap[y0 * w + x0];
          final v10 = grayMap[y0 * w + x1];
          final v01 = grayMap[y1 * w + x0];
          final v11 = grayMap[y1 * w + x1];
          final gray = v00 * (1 - fx) * (1 - fy) +
              v10 * fx * (1 - fy) +
              v01 * (1 - fx) * fy +
              v11 * fx * fy;
          final idx = (y * side + x) * 3;
          inF[idx] = gray; // L∈[0,1]（DDColor 契约：L/100）
          inF[idx + 1] = 0.0; // a 输入 = 0
          inF[idx + 2] = 0.0; // b 输入 = 0
        }
      }
      return inF;
    });
    // 3) 推理：ab [1,2,side,side]（IsolateInterpreter 已隔离）。
    final ab = await _backend!.inferAsync(inF);
    if (ab.length != 1 * 2 * side * side) {
      throw StateError('ab 张量长度不符: ${ab.length}');
    }
    // 统计 ab 分布（调试）：全部接近 0 → 输入或模型契约不对，输出会是灰度。
    var aMin = 1e9, aMax = -1e9, bMin = 1e9, bMax = -1e9, aSum = 0.0, bSum = 0.0;
    for (var i = 0; i < side * side; i++) {
      final a = ab[i * 2], b = ab[i * 2 + 1];
      if (a < aMin) aMin = a;
      if (a > aMax) aMax = a;
      if (b < bMin) bMin = b;
      if (b > bMax) bMax = b;
      aSum += a;
      bSum += b;
    }
    final nn = (side * side).toDouble();
    ErrorLogger.instance.info(
        'Colorizer ab 分布 a[$aMin,$aMax]均值${(aSum / nn).toStringAsFixed(3)} '
        'b[$bMin,$bMax]均值${(bSum / nn).toStringAsFixed(3)}');
    // 4)+5) Lab→RGB（ab 已为 Lab 原尺度 -128..127）→ 双线性采样回原尺寸。
    // 放 Isolate.run：主 isolate 只收结果。
    final out = await Isolate.run(() {
      // 先构建 side×side 的 Lab→RGB 查找表，避免重复计算。
      final rgbTab = Uint8List(side * side * 3);
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final abi = (y * side + x) * 2;
          final a = ab[abi];
          final b = ab[abi + 1];
          final nx = (x * w / side).clamp(0, w - 1).toInt();
          final ny = (y * h / side).clamp(0, h - 1).toInt();
          final l = grayMap2(ny * w + nx, rgb, w) * 100.0; // 原图最近灰度 0-100
          // Lab→RGB（CIE 标准，D65）：L 0-100，a/b -128..127。
          final fy = (l + 16.0) / 116.0;
          final fx2 = fy + a / 500.0;
          final fz = fy - b / 200.0;
          double lin(double f) {
            final f3 = f * f * f;
            return f3 > 0.008856 ? f3 : (f - 16.0 / 116.0) / 7.787;
          }

          final xr = lin(fx2) * 0.95047;
          final yr = lin(fy);
          final zr = lin(fz) * 1.08883;
          var rr = xr * 3.2406 + yr * -1.5372 + zr * -0.4986;
          var gg = xr * -0.9689 + yr * 1.8758 + zr * 0.0415;
          var bb = xr * 0.0557 + yr * -0.2040 + zr * 1.0570;
          rr = (rr > 0.0031308
              ? 1.055 * math.pow(rr, 1 / 2.4).toDouble() - 0.055
              : 12.92 * rr) *
              255;
          gg = (gg > 0.0031308
              ? 1.055 * math.pow(gg, 1 / 2.4).toDouble() - 0.055
              : 12.92 * gg) *
              255;
          bb = (bb > 0.0031308
              ? 1.055 * math.pow(bb, 1 / 2.4).toDouble() - 0.055
              : 12.92 * bb) *
              255;
          final ti = (y * side + x) * 3;
          rgbTab[ti] = rr.clamp(0, 255).toInt();
          rgbTab[ti + 1] = gg.clamp(0, 255).toInt();
          rgbTab[ti + 2] = bb.clamp(0, 255).toInt();
        }
      }
      // 双线性采样回原尺寸。
      final out = Uint8List(n * 3);
      final s = side.toDouble();
      final wD = w.toDouble();
      final hD = h.toDouble();
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final gx = (x + 0.5) * s / wD - 0.5;
          final gy = (y + 0.5) * s / hD - 0.5;
          final x0 = gx.clamp(0, side - 1).toInt();
          final y0 = gy.clamp(0, side - 1).toInt();
          final x1 = (x0 + 1).clamp(0, side - 1);
          final y1 = (y0 + 1).clamp(0, side - 1);
          final fx = gx - x0;
          final fy = gy - y0;
          for (var c = 0; c < 3; c++) {
            final v00 = rgbTab[(y0 * side + x0) * 3 + c];
            final v10 = rgbTab[(y0 * side + x1) * 3 + c];
            final v01 = rgbTab[(y1 * side + x0) * 3 + c];
            final v11 = rgbTab[(y1 * side + x1) * 3 + c];
            final v = v00 * (1 - fx) * (1 - fy) +
                v10 * fx * (1 - fy) +
                v01 * (1 - fx) * fy +
                v11 * fx * fy;
            out[(y * w + x) * 3 + c] = v.clamp(0, 255).toInt();
          }
        }
      }
      return out;
    });
    return out;
  }

  /// 取原图像素灰度（0-100 Lab L 域），供 Lab→RGB 合成用。
  static double grayMap2(int idx, Uint8List rgb, int w) {
    final p = idx * 3;
    return (rgb[p] * 0.299 + rgb[p + 1] * 0.587 + rgb[p + 2] * 0.114) / 255.0;
  }

  /// 低端机（RAM < 4GB）隐藏入口（用户评审要求）。
  static Future<bool> isLowEndDevice() async {
    try {
      final sys = await _totalRamBytes();
      return sys != null && sys < 4 * 1024 * 1024 * 1024;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> _totalRamBytes() async {
    // io 平台：读取 /proc/meminfo（Android/Linux）或 sysctl（macOS/Windows）。
    if (kIsWeb) return null;
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final f = File('/proc/meminfo');
        if (f.existsSync()) {
          for (final line in f.readAsLinesSync()) {
            if (line.startsWith('MemTotal:')) {
              final kb = int.tryParse(
                  line.replaceAll(RegExp(r'[^0-9]'), ''));
              if (kb != null) return kb * 1024;
            }
          }
        }
      } else if (Platform.isMacOS) {
        final r = await Process.run('sysctl', ['hw.memsize']);
        if (r.exitCode == 0) {
          return int.tryParse(r.stdout.toString().trim().split(' ').last);
        }
      }
    } catch (_) {}
    return null;
  }
}