import 'dart:typed_data';

/// 漫画上色受控平台的实现载体。
///
/// io 平台（colorizer_io.dart）用 tflite_flutter 的 IsolateInterpreter 做
/// 真推理；web 平台无 TFLite FFI，跑 colorizer_stub.dart 空实现（永远
/// 返回「不可用」）。条件导出在 colorizer.dart 用 `show` 指定当前平台
/// 的 `ColorizerBackend`，调用方只依赖这一个类型。
abstract class ColorizerBackend {
  /// 是否可用（io 上模型文件存在且引擎初始化成功；web 永远 false）。
  bool get isAvailable;

  /// 加载模型文件（同步初始化主引擎/读取形状；失败抛异常，由调用方降级）。
  /// [modelPath] 为本地模型文件绝对路径。
  /// 返回模型输入形状 [h, w]，供调用方预处理缩放。
  void load(String modelPath);

  /// 等待异步引擎就绪（Isolate 装载等）。io 后端实现；web 桩为空操作。
  Future<void> loadAsync() async {}

  /// 推理一张图：输入为宽 w、高 h 的解码后 RGB 像素（3 字节/像素，
  /// 无 alpha），输出 RGB 像素（长度 w*h*3）。互斥与超时由调用方
  /// （ColorizerManager）保证。未加载时调用抛 StateError。
  Uint8List infer(Uint8List rgba, int w, int h);

  /// 释放引擎资源（模型卸载）。
  void dispose();
}