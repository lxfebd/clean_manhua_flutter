import 'dart:io';
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import 'colorizer_backend.dart';

/// io 平台（Android/iOS/桌面）上色后端工厂：真 TFLite IsolateInterpreter。
ColorizerBackend createColorizerBackend() => TfliteColorizerBackend();

/// io 平台（Android/iOS/桌面）漫画上色后端：TFLite IsolateInterpreter。
///
/// 模型文件由用户放入应用文档目录（不内置、不上传），[load] 时用
/// `IsolateInterpreter.create(address)` 在隔离线程装载，[infer] 走独立
/// Isolate 调用（与 image_super_res 同构，不卡 UI）。
///
/// 模型约定（写进导入引导文案）：
/// - 输入：1xHxWx3，float32，值域 [0,1]（灰度平铺 3 通道）；
/// - 输出：1xHxWx3，float32，值域 [0,1]（RGB）；
/// 这类输入来自 AnimeGAN-keras / DDColor 的 TFLite 导出，符合常见上色模型。
class TfliteColorizerBackend implements ColorizerBackend {
  IsolateInterpreter? _interp;
  Interpreter? _syncInterp;
  List<int>? _inputShape;
  List<int>? _outputShape;

  @override
  bool get isAvailable => _interp != null;

  /// 输入通道数（模型首个维后是 HxWxC）。
  int get _inChannels => (_inputShape != null && _inputShape!.length >= 4)
      ? _inputShape![3]
      : 3;

  @override
  void load(String modelPath) {
    final f = File(modelPath);
    final syncInterp = Interpreter.fromFile(f);
    _inputShape = syncInterp.getInputTensor(0).shape;
    _outputShape = syncInterp.getOutputTensor(0).shape;
    // Isolate 装载是异步的：async load 由 manager 等待（ensureLoaded），
    // 这里先保存同步 Interpreter，真正 ready 后 _interp 才非空。
    _syncInterp = syncInterp;
    _pending = syncInterp.address;
  }

  int? _pending;

  /// 等待异步 Isolate 装载完成（manager 在 ensureLoaded 后调用以确认就绪）。
  @override
  Future<void> loadAsync() async {
    final addr = _pending;
    if (addr == null) return;
    _pending = null;
    final ii = await IsolateInterpreter.create(address: addr);
    _interp = ii;
  }

  /// 输入 RGB 像素 (w*h*3) → 输出 RGB 像素 (w*h*3)。
  /// 灰度预处理：取 BT.601 灰度平铺到 3 通道，喂给上色模型。
  @override
  Uint8List infer(Uint8List rgb, int w, int h) {
    final interp = _interp;
    final outShape = _outputShape;
    if (interp == null || outShape == null) {
      throw StateError('上色模型未加载');
    }
    final n = w * h;
    final inF = Float32List(n * _inChannels);
    for (var i = 0; i < n; i++) {
      final p = i * 3;
      final gray = (rgb[p] * 0.299 + rgb[p + 1] * 0.587 + rgb[p + 2] * 0.114) /
          255.0;
      for (var c = 0; c < _inChannels; c++) {
        inF[i * _inChannels + c] = gray;
      }
    }
    final outF = Float32List(_tensorLen(outShape));
    interp.run(inF, {0: outF});
    final bytes = Uint8List.fromList(
      outF.map((d) => (d * 255).clamp(0, 255).toInt()).toList(),
    );
    // 输出可能与输入尺寸不同（模型固定分辨率）：由调用方缩放。
    return bytes;
  }

  int _tensorLen(List<int> shape) {
    var n = 1;
    for (final s in shape.skip(1)) {
      n *= s;
    }
    return n;
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
    _inputShape = null;
    _outputShape = null;
    _pending = null;
  }
}