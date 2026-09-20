import 'dart:ffi';
import 'dart:isolate' show Isolate;

/// io 平台（桌面/Android）原生演示构件加载：在独立 Isolate 内
/// `DynamicLibrary.open` + 调用导出函数。新 isolate 不共享主 isolate 的
/// FFI 句柄，须在 isolate 内重新加载——加载/调用失败抛出 [DemoNativeLoadError]，
/// 由调用方包装成明确失败原因（不静默降级）。
Future<Map<String, dynamic>> demoNativeSum(
  String libPath,
  int a,
  int b,
) {
  return Isolate.run(() {
    try {
      final lib = DynamicLibrary.open(libPath);
      final sum = lib.lookupFunction<Int64 Function(Int64, Int64),
          int Function(int, int)>('demo_sum');
      final ver = lib.lookupFunction<Int64 Function(), int Function()>(
          'demo_version');
      return <String, dynamic>{
        'sum': sum(a, b),
        'version': ver(),
      };
    } catch (_) {
      // 固定文案进 UI；原始错误由调用方 CapabilityFailure 包装层记日志。
      throw DemoNativeLoadError('原生库加载失败，请重新安装后重试');
    }
  });
}

/// 原生库加载/调用失败（区别于普通执行异常，携带用户可读原因）。
class DemoNativeLoadError implements Exception {
  final String message;
  DemoNativeLoadError(this.message);
  @override
  String toString() => message;
}
