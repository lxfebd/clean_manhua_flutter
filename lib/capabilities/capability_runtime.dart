import 'dart:async' show FutureOr;
import 'dart:io';
import 'dart:isolate' show Isolate;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../net/error_logger.dart';
import 'capability_artifact_store.dart';
import 'capability_plugin_manager.dart';

/// 能力运行时：全项目唯一允许出现 DynamicLibrary.open / Isolate 隔离调用的地方。
///
/// 设计 §12 稳定性边界的落地：
/// - **Native 崩溃无法隔离**（ncnn/Vulkan 一个 SIGSEGV 就是整个进程掉，Dart
///   try/catch 抓不住），只能前置防御——本类集中所有防御逻辑，业务代码绝不
///   直接碰 FFI。
/// - **版本钉死**：加载前必须 artifact/weights 带精确版本 + SHA256，绝不自动
///   滚动 latest。
/// - **加载失败给明确原因**（「当前机型无 Vulkan 支持」「权重校验失败已重新
///   下载」），不静默降级——静默是当年上色「糊了+没上色」被骂的根因。
///
/// 阶段：
/// - M1 落地纯 Dart 能力（无 FFI），run 用 Isolate.run 隔离——演示能力跑在
///   独立 isolate，主线程不被长任务卡死。
/// - M2 桌面 FFI：probe 实现真实三步（ABI 校验 → artifact 落盘 + SHA256 复验
///   → 算力标记）；run 支持在独立 isolate 内 DynamicLibrary.open 真实 .dll 并
///   调用导出函数（新 isolate 不共享主 isolate 的 FFI 句柄，须在 isolate 内
///   重新加载——加载失败有明确原因，不静默降级）。
class CapabilityRuntime {
  CapabilityRuntime._();

  static final CapabilityRuntime instance = CapabilityRuntime._();

  /// 能力启用中状态。
  bool isEnabled(String id) =>
      CapabilityPluginManager.instance.isEnabledSync(id);

  /// 申请能力句柄：校验启用 + 构件已加载 + 权重已就绪。
  /// 任一不满足返回带原因的失败（不抛异常，调用方据此给用户明确提示）。
  ///
  /// M1：纯 Dart 能力无构件/权重，仅校验启用。
  /// M2+：带 artifact 的能力额外校验 artifact 已落盘（probe 已通过）。
  Future<CapabilityResult> acquire(String id) async {
    if (!isEnabled(id)) {
      return CapabilityFailure(id, '能力未启用，请在能力中心打开');
    }
    final plugin = CapabilityPluginManager.instance.byId(id);
    if (plugin != null && plugin.artifact != null) {
      final pr = await probe(id);
      if (pr is CapabilityFailure) return pr;
    }
    return CapabilityOk(id);
  }

  /// 隔离调用：任务跑在独立 Isolate，超时/异常包装成 [CapabilityResult]。
  /// 连续失败计数由调用方（能力中心/设置页）驱动禁用，本类不隐式改状态，
  /// 保持单一事实源在 Manager。
  Future<CapabilityResult> run(
    String id,
    FutureOr<dynamic> Function() task,
  ) async {
    try {
      final result = await Isolate.run(task);
      return CapabilityOk(id, data: result);
    } catch (e) {
      ErrorLogger.instance.warn('[capability] run($id) failed: $e');
      return CapabilityFailure(id, '执行失败，请重试');
    }
  }

  /// 加载前置防御：全部通过才允许后续加载。
  ///
  /// 三步（M2 桌面实现）：
  /// 1. ABI 校验：当前平台架构必须存在于 artifact.sha256 键集（或纯 Dart 无
  ///    artifact 直接 ok）。桌面统一视作「桌面 ABI 已声明」——真实架构细分
  ///    （x64/arm64）在 M3 Android 按 abi 键精确匹配。
  /// 2. artifact 落盘校验：缺失/损坏（SHA256 不匹配）→ 尝试下载；仍失败给
  ///    明确原因。
  /// 3. 算力标记：M2 桌面 DLL 加载路径先不做 Vulkan 探测，返回 ok（真实算力
  ///    探测随 AI 能力插件（M3/M4）引入）。
  Future<CapabilityResult> probe(String id) async {
    final plugin = CapabilityPluginManager.instance.byId(id);
    if (plugin == null) {
      return CapabilityFailure(id, '能力未注册: $id');
    }
    final artifact = plugin.artifact;
    if (artifact == null) {
      // 纯 Dart 能力无原生依赖，直接 ok。
      return CapabilityOk(id);
    }

    // 1. ABI 校验：桌面必须声明桌面 ABI（任意键即可，x64/arm64 细分 M3 再做）；
    //    Android 需声明当前 ABI 键。
    final abi = _currentAbi();
    String? androidAbi;
    if (abi == 'android') {
      androidAbi = await _androidAbi();
      if (artifact.sha256.isNotEmpty && !artifact.sha256.containsKey(androidAbi)) {
        return CapabilityFailure(
            id, '当前机型（$androidAbi）没有对应构件，无法加载');
      }
    }

    // 2. artifact 就绪校验：缺失/损坏 → 下载；失败给明确原因。
    //    平台分流：Android 构建期 bundle（jniLibsFile / maven / embedded），
    //    运行期系统 loader 直接从 nativeLibraryDir 加载，probe 只校验 ABI 键
    //    （sha256 已声明）即视为就绪；其余平台走 url 直链下载 + SHA256 校验。
    final store = CapabilityArtifactStore.instance;
    final isAndroid = abi == 'android';
    if (isAndroid && (artifact.jniLibsFile != null || artifact.maven != null)) {
      // 构建期 bundle：APK 签名保证完整性，版本钉死靠构建期（gradle 校验
      // jniLibs 产物哈希与元数据一致）；运行期系统 loader 加载。
      return CapabilityOk(id);
    } else if (artifact.url != null) {
      final file = await store.download(id, artifact);
      if (file == null) {
        return CapabilityFailure(
            id, store.lastError ?? '构件不可用（无下载地址）');
      }
    } else if (artifact.embedded) {
      // 构建期预打包：直接认为可用（M3 Android AAR 场景）。
      return CapabilityOk(id);
    } else {
      return CapabilityFailure(id, '构件缺少下载地址（url 为空且未预打包）');
    }

    // 3. 算力标记：M2 先不探测（真实 GPU/Vulkan 探测随 AI 能力 M3/M4 引入）。
    return CapabilityOk(id);
  }

  /// 当前平台 ABI 判定（M2 桌面只区分 desktop/android；M3 Android 精确到
  /// arm64-v8a / armeabi-v7a / x86_64，与 release abiFilters 对齐）。
  static String _currentAbi() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Android 当前 ABI（如 arm64-v8a / armeabi-v7a / x86_64），结果缓存。
  /// 读 DeviceInfoPlugin().androidInfo（需在 async 上下文 await）。
  static String? _abiCache;
  static Future<String> _androidAbi() async {
    if (_abiCache != null) return _abiCache!;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final abis = info.supportedAbis;
      final abi = abis.isEmpty ? 'unknown' : abis.first;
      _abiCache = abi;
      return abi;
    } catch (_) {
      return 'unknown';
    }
  }
}

/// 能力调用结果：单次申请/调用的统一包装。
///
/// 用 sealed 让业务侧 switch 穷尽两种状态，避免把错误当数据静默吞掉。
sealed class CapabilityResult {
  final String id;
  const CapabilityResult(this.id);
}

class CapabilityOk extends CapabilityResult {
  final dynamic data;
  const CapabilityOk(super.id, {this.data});
}

class CapabilityFailure extends CapabilityResult {
  /// 面向用户的失败原因（如「当前机型无 Vulkan 支持」）。
  final String reason;
  const CapabilityFailure(super.id, this.reason);
}
