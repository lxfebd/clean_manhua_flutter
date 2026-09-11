import 'dart:io';
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import '../net/error_logger.dart';
import 'colorizer_backend.dart';

/// io 平台（Android/iOS/桌面）上色后端工厂：真 TFLite IsolateInterpreter。
ColorizerBackend createColorizerBackend() => TfliteColorizerBackend();

/// io 平台（Android/iOS/桌面）漫画上色后端：TFLite IsolateInterpreter。
///
/// 模型文件由用户放入应用文档目录（不内置、不上传），[load] 时用
/// `IsolateInterpreter.create(address)` 在隔离线程装载，[infer] 走独立
/// Isolate 调用（与 image_super_res 同构，不卡 UI）。
///
/// 模型契约为 DDColor（256×256，Apache-2.0）：
/// - 输入：1×3×256×256 float32，Lab 空间（L/50-1，ab=0）；
/// - 输出：1×2×256×256 float32，ab 通道（约 ±2，×110 还原 Lab）。
///
/// 兼容两种输入布局（转换工具决定）：
/// - CHW `[1,3,256,256]`：原样喂入；
/// - NHWC `[1,256,256,3]`：喂入前转置为 HWC。
/// 输出统一转成**交错布局**（a,b,a,b…）返回，与 [ColorizerManager] 后处理一致。
/// 灰度→Lab 合成与反归一化在 ColorizerManager（纯 Dart，可单测）。
class TfliteColorizerBackend implements ColorizerBackend {
  static const int _side = 256;
  static const int _outLen = 1 * 2 * _side * _side;
  static const int _inLen = 1 * 3 * _side * _side;

  IsolateInterpreter? _interp;
  Interpreter? _syncInterp;
  int? _pending;
  bool _nhwc = false;

  @override
  bool get isAvailable => _interp != null;

  @override
  void load(String modelPath) {
    final f = File(modelPath);
    final syncInterp = Interpreter.fromFile(f);
    // 校验模型规格：必须 256×256 输入 → 1×2×256×256 输出（DDColor）。
    final inShape = syncInterp.getInputTensor(0).shape;
    syncInterp.getOutputTensor(0).shape;
    if (inShape.length != 4 || inShape[0] != 1) {
      syncInterp.close();
      throw StateError('模型规格不符：需要 1×3×256×256（DDColor），'
          '实际 ${inShape.join('×')}');
    }
    if (inShape[1] == 3 && inShape[2] == _side && inShape[3] == _side) {
      _nhwc = false; // CHW
    } else if (inShape[1] == _side &&
        inShape[2] == _side &&
        inShape[3] == 3) {
      _nhwc = true; // NHWC
    } else {
      syncInterp.close();
      throw StateError('模型规格不符：需要 1×3×256×256 或 1×256×256×3（DDColor），'
          '实际 ${inShape.join('×')}');
    }
    // Isolate 装载是异步的：async load 由 manager 等待（ensureLoaded），
    // 这里先保存同步 Interpreter，真正 ready 后 _interp 才非空。
    _syncInterp = syncInterp;
    _pending = syncInterp.address;
    ErrorLogger.instance.info('Colorizer model loaded inShape=${inShape.join('x')} '
        'input.type=${syncInterp.getInputTensor(0).type} '
        'outBytes=${syncInterp.getOutputTensor(0).numBytes()}');
  }

  /// 等待异步 Isolate 装载完成（manager 在 ensureLoaded 后调用以确认就绪）。
  @override
  Future<void> loadAsync() async {
    final addr = _pending;
    if (addr == null) return;
    _pending = null;
    final ii = await IsolateInterpreter.create(address: addr);
    _interp = ii;
  }

  /// 输入张量（1×3×256×256 float32）→ 输出张量
  /// （交错 ab：a,b,a,b…，256×256 平铺，与 [ColorizerManager] 后处理一致）。
  ///
  /// 关键点（踩坑记录）：
  /// - [IsolateInterpreter.run] 是 async：推理在独立 isolate 执行，必须 await。
  /// - 输入必须传 [ByteBuffer]：`Float32List` 会触发 `getInputShapeIfDifferent`
  ///   → `resizeInputTensor` 把输入永久压成 rank-1 → TRANSPOSE prepare 失败，
  ///   推理不执行。
  /// - 输出不能依赖 `copyTo()`：tflite_flutter 的 `copyTo(ByteBuffer)` 分支
  ///   写了但读回全 0（框架 bug）。改用 `Interpreter.fromAddress(address)`
  ///   拿输出 tensor 直读底层 `Tensor.data`（非零，实测可靠）。
  @override
  Future<Float32List> inferAsync(Float32List inputTensor) async {
    final interp = _interp;
    if (interp == null) {
      throw StateError('上色模型未加载');
    }
    final sw = Stopwatch()..start();
    if (_nhwc) {
      // 输入是交错 [c0,c1,c2]×N（三通道各自归一化灰度）；模型要 NHWC [1,256,256,3]：
      // 交错 → HWC 逐像素 3 通道平移，保持通道差异（逐通道 mean/std 不同）。
      final inF = Float32List(_inLen);
      var i = 0;
      for (var p = 0; p < _side * _side; p++) {
        final pi = p * 3;
        inF[i++] = inputTensor[pi];
        inF[i++] = inputTensor[pi + 1];
        inF[i++] = inputTensor[pi + 2];
      }
      // 占位输出（不用 copyTo 结果，直读底层 tensor）。
      await interp.run(inF.buffer, {0: Float32List(_outLen).buffer});
      final chw = _readRawOutput();
      final ms = sw.elapsedMilliseconds;
      // tflite_flutter 0.12.1 的 runForMultipleInputs 在 state=loading 时
      // 直接 return（skip），输出 tensor 保持全 0/残留。耗时 <100ms 必是
      // skip（真推理 256×256 DDColor ≥1s），抛异常让调用方等待重试。
      if (ms < 100) {
        throw StateError('IsolateInterpreter skip（并发污染），耗时 ${ms}ms');
      }
      return chw;
    }
    // CHW 输入（模型为 CHW）：把交错 [c0,c1,c2] 拆成 CHW 通道分离（保留通道差异）。
    final inF = Float32List(_inLen);
    final plane = _side * _side;
    for (var p = 0; p < plane; p++) {
      final pi = p * 3;
      inF[p] = inputTensor[pi]; // 通道 0
      inF[plane + p] = inputTensor[pi + 1]; // 通道 1
      inF[2 * plane + p] = inputTensor[pi + 2]; // 通道 2
    }
    await interp.run(inF.buffer, {0: Float32List(_outLen).buffer});
    final chwF = _readRawOutput();
    final ms = sw.elapsedMilliseconds;
    // 同 NHWC：<100ms 必是 IsolateInterpreter skip，等待重试而非降级。
    if (ms < 100) {
      throw StateError('IsolateInterpreter skip（并发污染），耗时 ${ms}ms');
    }
    return chwF;
  }

  /// 从 Isolate 亲线程地址直读输出张量字节（绕过 copyTo bug）。
  /// 必须在本 isolate（IsolateInterpreter 主线程）调用——address 指向
  /// 底层 TfLiteInterpreter，`Tensor.data` 直读其内存，零拷贝。
  /// 返回**交错 ab**（a,b,a,b…，与 [ColorizerManager] 后处理契约一致），
  /// 不是 CHW 原始布局（否则 manager 按 i*2/i*2+1 取数会错位成近零）。
  Float32List _readRawOutput() {
    final addr = _interp?.address ?? _syncInterp?.address;
    if (addr == null) {
      throw StateError('上色模型未加载');
    }
    final raw =
        Interpreter.fromAddress(addr).getOutputTensor(0).data;
    if (raw.length != _outLen * 4) {
      ErrorLogger.instance.warn('Colorizer 输出字节数不符: ${raw.length} '
          '!= ${_outLen * 4}');
      throw StateError('输出字节数不符');
    }
    final bd = raw.buffer.asByteData(0, _outLen * 4);
    // CHW [1,2,256,256]：前 aOff 个是 a 平面，后 aOff 个是 b 平面。
    // 交错成 a,b,a,b… 返回（aOff = width*height）。
    final aOff = _side * _side;
    final out = Float32List(_outLen);
    for (var i = 0; i < aOff; i++) {
      out[i * 2] = bd.getFloat32(i * 4, Endian.little); // a
      out[i * 2 + 1] =
          bd.getFloat32((aOff + i) * 4, Endian.little); // b
    }
    return out;
  }

  @override
  void dispose() {
    final i = _interp;
    if (i != null) {
      i.close();
      _interp = null;
    }
    _syncInterp?.close();
    _syncInterp = null;
    _pending = null;
  }
}
