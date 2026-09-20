import 'package:flutter/material.dart';

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
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
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
            borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        action: action,
      ));
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
