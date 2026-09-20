import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../net/error_logger.dart';
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'capability_runtime.dart';
import 'demo_native_loader.dart';

/// M2 演示原生能力：FFI 加载真实 .dll（桌面 artifact）走全链路。
///
/// 目的不是功能本身，而是验证能力插件的**原生构件链路**：
/// 下载（或本地已有）→ SHA256 校验 → probe → Isolate 内
/// DynamicLibrary.open 调用导出函数 → 失败给明确原因（不静默降级）。
///
/// 与 [ChapterStatsPlugin] 的区别：这是第一个带 `artifact` 的能力——probe
/// 会真实检查/下载 .dll，在独立 Isolate 内加载并调用导出函数（经
/// [demoNativeSum] 条件导入，web 端无 FFI 返回明确失败）。
/// 真实 AI 能力（上色/插帧）走同一通道，仅 artifact 指向不同库。
class DemoNativePlugin extends CapabilityPlugin {
  /// 演示 DLL 的 SHA256（test/assets/demo_native/demo_math.dll 编译产物）。
  /// 变更 DLL 内容时必须同步更新，否则 probe 校验失败（版本钉死）。
  static const String demoSha256 =
      '51c684d4185dbcee4fead6d110741d3dee9fde82717f9e4d8fc1325363011436';

  /// Android 三个 ABI 的 .so SHA256（test/assets/demo_native/build_android_so.bat
  /// 交叉编译产物，构建期 bundle 进 jniLibs）。变更 .so 必须同步更新。
  static const String androidSha256Arm64 =
      '8a6524084aa328ccceea9188ac6c1330dcc96165e234ff10fb76139edc8d7076';
  static const String androidSha256Arm32 =
      '15ed0631996d6bd5f6fa10ffb7c1ca056ee100ed4eaa25053763d03e3ebfd207';
  static const String androidSha256X64 =
      '749339d2fb0b2d80d5044fd9f8af7a98d620f498b53b0c8683377f13783faa41';

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
            jniLibsFile:
                'libdemo_math.so', // Android: 构建期经 jniLibs 进 lib/<abi>/
            sha256: {
              'windows-x64': demoSha256,
              'linux-x64': demoSha256,
              'macos-x64': demoSha256,
              'arm64-v8a': androidSha256Arm64,
              'armeabi-v7a': androidSha256Arm32,
              'x86_64': androidSha256X64,
            },
          ),
        );

  /// 在独立 Isolate 内加载 demo_math.dll/.so 并求和。
  ///
  /// 先 probe 确保 artifact 已就绪（桌面：已落盘校验；Android：构建期 bundle
  /// jniLibs，probe 校验 ABI 键即就绪），再在 isolate 内
  /// DynamicLibrary.open + 调用导出函数（web 端无 FFI，返回明确失败）。
  /// 演示能力返回求和结果 Map。
  static Future<CapabilityResult> sum(int a, int b) async {
    final probe = await CapabilityRuntime.instance.probe('utility.native');
    if (probe is CapabilityFailure) return probe;
    // Android：系统 loader 直接从 nativeLibraryDir 加载 jniLibs 打包的 so
    // （与 media_kit 的 libmpv.so 同机制）；桌面：应用支持目录的 dll/dylib/so。
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final String libPath;
    if (isAndroid) {
      libPath = 'libdemo_math.so';
    } else {
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
      libPath = f.path;
    }
    try {
      final data = await demoNativeSum(libPath, a, b);
      return CapabilityOk('utility.native', data: data);
    } on DemoNativeLoadError catch (e) {
      return CapabilityFailure('utility.native', e.message);
    } catch (e) {
      ErrorLogger.instance.warn('[capability] demo native sum failed: $e');
      return const CapabilityFailure('utility.native', '执行失败，请重试');
    }
  }
}
