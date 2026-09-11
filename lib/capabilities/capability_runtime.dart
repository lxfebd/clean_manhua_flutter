import 'dart:async' show FutureOr;
import 'dart:isolate' show Isolate;

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
/// 阶段说明：M1 落地纯 Dart 能力（无 FFI），run 用 Isolate.run 隔离——演示
/// 能力跑在独立 isolate，主线程不被长任务卡死。M2 桌面 FFI 加载时才接入
/// DynamicLibrary.open 和 probe 的原生探测分支。
class CapabilityRuntime {
  CapabilityRuntime._();

  static final CapabilityRuntime instance = CapabilityRuntime._();

  /// 能力启用中状态。
  bool isEnabled(String id) =>
      CapabilityPluginManager.instance.isEnabledSync(id);

  /// 申请能力句柄：校验启用 + 构件已加载 + 权重已就绪。
  /// 任一不满足返回带原因的失败（不抛异常，调用方据此给用户明确提示）。
  ///
  /// M1：纯 Dart 能力无构件/权重，仅校验启用；M2+ 扩展 probe 结果。
  Future<CapabilityResult> acquire(String id) async {
    if (!isEnabled(id)) {
      return CapabilityFailure(id, '能力未启用，请在能力中心打开');
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
      return CapabilityFailure(id, '执行失败: $e');
    }
  }

  /// 加载前置防御：全部通过才允许后续加载。
  /// M1 纯 Dart 能力恒返回 ok；M2+ 实现 ABI 校验 / 权重 SHA256 / 算力探测。
  Future<CapabilityResult> probe(String id) async {
    return CapabilityOk(id);
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