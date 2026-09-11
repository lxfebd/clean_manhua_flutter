import 'dart:typed_data';

import 'colorizer_backend.dart';

/// web 平台上色后端工厂：无 TFLite FFI，永远不可用。
ColorizerBackend createColorizerBackend() => WebColorizerBackend();

/// web 平台漫画上色后端：无 TFLite FFI，永远不可用。
/// 功能入口由调用方（ColorizerManager / UI）在 isAvailable==false 时禁用。
class WebColorizerBackend implements ColorizerBackend {
  @override
  bool get isAvailable => false;

  @override
  void load(String modelPath) {
    throw StateError('web 端不支持本地上色模型');
  }

  @override
  Future<void> loadAsync() async {}

  @override
  Future<Float32List> inferAsync(Float32List inputTensor) {
    throw StateError('web 端不支持本地上色模型');
  }

  @override
  void dispose() {}
}