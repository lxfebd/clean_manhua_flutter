/// web 平台原生演示构件加载：无 FFI，永远不可用。
/// 功能入口由调用方（能力中心自测按钮）在失败原因中展示「web 端不支持」。
Future<Map<String, dynamic>> demoNativeSum(
  String libPath,
  int a,
  int b,
) {
  throw DemoNativeLoadError('web 端不支持原生构件加载');
}

/// 原生库加载/调用失败（区别于普通执行异常，携带用户可读原因）。
class DemoNativeLoadError implements Exception {
  final String message;
  DemoNativeLoadError(this.message);
  @override
  String toString() => message;
}
