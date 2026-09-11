import 'dart:typed_data';

/// 漫画上色受控平台的实现载体。
///
/// io 平台（colorizer_io.dart）用 tflite_flutter 的 IsolateInterpreter 做
/// 真推理；web 平台无 TFLite FFI，跑 colorizer_stub.dart 空实现（永远
/// 返回「不可用」）。条件导出在 colorizer.dart 用 `show` 指定当前平台
/// 的 `ColorizerBackend`，调用方只依赖这一个类型。
///
/// 模型契约为 DDColor（256×256，Apache-2.0）：
/// - 输入：1×256×256×3 float32 NHWC，通道 0 为 L/100 归一化灰度（L∈[0,1]），
///   通道 1、2 为 0（ab 占位）；
/// - 输出：1×2×256×256 float32 CHW，ab 通道已是 Lab 原尺度（约 -128..127），
///   不需再缩放。此协议经 Python 探针实测确认（其他输入方案如
///   ImageNet mean/std、gray×3 均产生近零 ab 的灰度输出假象）。
/// 灰度→Lab 合成、Lab→RGB、双线性回原尺寸等全部由 ColorizerManager 完成，
/// backend 只做「像素张量 → 模型张量 → 结果张量」的最薄桥接。
abstract class ColorizerBackend {
  /// 是否可用（io 上模型文件存在且引擎初始化成功；web 永远 false）。
  bool get isAvailable;

  /// 加载模型文件（同步初始化主引擎/读取形状；失败抛异常，由调用方降级）。
  /// [modelPath] 为本地模型文件绝对路径。
  void load(String modelPath);

  /// 等待异步引擎就绪（Isolate 装载等）。io 后端实现；web 桩为空操作。
  Future<void> loadAsync() async {}

  /// 推理：输入为模型输入张量（1×256×256×3 float32，已归一化），
  /// 返回模型输出张量（1×2×256×256 float32，ab 通道）。
  /// 未加载时调用抛 StateError。
  ///
  /// io 后端用 IsolateInterpreter，推理在独立 isolate 异步执行，必须 await。
  Future<Float32List> inferAsync(Float32List inputTensor);

  /// 释放引擎资源（模型卸载）。
  void dispose();
}
