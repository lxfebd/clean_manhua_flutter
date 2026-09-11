import 'dart:ffi';
import 'dart:io';

import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'capability_runtime.dart';

/// M2 演示原生能力：FFI 加载真实 .dll（桌面 artifact）走全链路。
///
/// 目的不是功能本身，而是验证能力插件的**原生构件链路**：
/// 下载（或本地已有）→ SHA256 校验 → probe → runNative（Isolate 内
/// DynamicLibrary.open → 调用导出函数）→ 失败给明确原因（不静默降级）。
///
/// 与 [ChapterStatsPlugin] 的区别：这是第一个带 `artifact` 的能力——probe
/// 会真实检查/下载 .dll，runNative 会在独立 Isolate 内加载并调用导出函数。
/// 真实 AI 能力（上色/插帧）走同一通道，仅 artifact 指向不同库。
class DemoNativePlugin extends CapabilityPlugin {
  /// 演示 DLL 的 SHA256（test/assets/demo_native/demo_math.dll 编译产物）。
  /// 变更 DLL 内容时必须同步更新，否则 probe 校验失败（版本钉死）。
  static const String demoSha256 =
      '51c684d4185dbcee4fead6d110741d3dee9fde82717f9e4d8fc1325363011436';

  DemoNativePlugin()
      : super(
          id: 'utility.native',
          name: '原生演示',
          category: 'utility',
          version: '1.0.0',
          author: '星漫匣内置',
          description: 'M2 演示：FFI 加载真实动态库（下载→SHA256→Isolate 调用）',
          builtin: true,
          artifact: CapabilityArtifact(
            url:
                'https://example.com/capabilities/demo_math.dll', // 占位：单测本地注入
            sha256: {
              'windows-x64': demoSha256,
              'linux-x64': demoSha256,
              'macos-x64': demoSha256,
            },
          ),
        );

  /// 在独立 Isolate 内加载 demo_math.dll 并求和。
  ///
  /// 先 probe 确保 artifact 已落盘校验，再 runNative 在 isolate 内
  /// DynamicLibrary.open + 调用导出函数。演示能力返回求和结果 Map。
  static Future<CapabilityResult> sum(int a, int b) async {
    final probe = await CapabilityRuntime.instance.probe('utility.native');
    if (probe is CapabilityFailure) return probe;
    final store = CapabilityArtifactStore.instance;
    final dir = await store.artifactDir('utility.native');
    if (dir == null) {
      return const CapabilityFailure('utility.native', '当前平台不支持本地构件');
    }
    final f = dir.listSync().whereType<File>().firstWhere(
          (e) => e.path.endsWith('.dll') ||
              e.path.endsWith('.so') ||
              e.path.endsWith('.dylib'),
          orElse: () => File('${dir.path}/demo_math.dll'),
        );
    if (!await f.exists()) {
      return const CapabilityFailure('utility.native', '构件未落盘，无法加载');
    }
    return CapabilityRuntime.instance.runNative('utility.native', f.path,
        task: (DynamicLibrary lib) {
      final sum = lib
          .lookupFunction<Int64 Function(Int64, Int64), int Function(int, int)>(
              'demo_sum');
      final ver = lib
          .lookupFunction<Int64 Function(), int Function()>('demo_version');
      return <String, dynamic>{
        'sum': sum(a, b),
        'version': ver(),
      };
    });
  }
}
