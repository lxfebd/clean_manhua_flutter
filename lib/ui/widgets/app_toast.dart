import 'package:flutter/material.dart';

import '../style_scope.dart';
import '../tokens.dart';

/// 全局统一 toast 反馈（替代散落的裸 SnackBar 调用）。
///
/// 职责：
/// - 统一视觉（黑底半透明、白字、居中图标可选）、统一时长档位；
/// - 同屏只保留一条（清掉旧的在显示新 toast，避免排队堆积）；
/// - 提供 [info]/[error] 便捷入口，语义即样式。
///
/// 接入方式：`AppToast.of(context).show(...)` 或 `AppToast.info(context, ...)`。
/// 迁移存量裸 SnackBar 时按内容语义选 info/error 档位。
class AppToast {
  const AppToast._();

  /// 全局 messenger key：挂到 [MaterialApp.scaffoldMessengerKey] 后，
  /// 可在拿不到 context 的静态回调里弹 toast（如书架写盘失败 hook）。
  static GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// 从 context 取当前 ScaffoldMessenger 显示一条 toast。
  /// [duration] 缺省 2s（短提示）；[error] 加错误图标，语义更醒目；
  /// [action] 可选操作（如「查看」）。
  static void show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
    bool error = false,
    SnackBarAction? action,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    // 风格化圆角：极简/苹果走标准控件圆角，小米走超椭圆大圆角。
    final toastRadius = context.uiStyle == UIStyle.xiaomi
        ? R.of(R.control, style: context.uiStyle)
        : R.control;
    messenger
      ..clearSnackBars()
      ..showSnackBar(_build(message,
          duration: duration,
          error: error,
          radius: toastRadius,
          action: action));
  }

  /// 无 context 提示：经 [messengerKey] 弹全局 toast。
  /// 供 store 静态写盘失败回调等拿不到 BuildContext 的链路使用；
  /// messenger 未挂载（启动早期）时静默跳过，不抛错打断写盘队列。
  static void showViaMessenger(
    String message, {
    Duration? duration,
    bool error = false,
  }) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(_build(
        message,
        duration:
            duration ?? (error ? const Duration(seconds: 3) : const Duration(seconds: 2)),
        error: error,
        radius: R.control,
      ));
  }

  static SnackBar _build(
    String message, {
    required Duration duration,
    required bool error,
    required double radius,
    SnackBarAction? action,
  }) {
    return SnackBar(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error) ...[
            const Icon(Icons.error_outline_rounded,
                size: 18, color: Colors.white),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(message,
                style: const TextStyle(color: Colors.white, fontSize: 13.5)),
          ),
        ],
      ),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.black.withValues(alpha: 0.78),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      action: action,
    );
  }

  /// 普通提示（成功/信息）。
  static void info(BuildContext context, String message, {Duration? duration}) =>
      show(context, message, duration: duration ?? const Duration(seconds: 2));

  /// 错误提示（带错误图标）。
  static void error(BuildContext context, String message,
          {Duration? duration}) =>
      show(context, message,
          duration: duration ?? const Duration(seconds: 3), error: true);
}
