import 'package:flutter/material.dart';

import '../tokens.dart';

/// 空态类型。
enum StateViewKind {
  /// 加载中（无操作按钮，转圈 + 文案）
  loading,

  /// 空数据（必须有重试/去添加按钮）
  empty,

  /// 错误（必须有重试按钮）
  error,

  /// 离线（必须有重试按钮）
  offline,
}

/// 统一的状态视图（加载/空/错误/离线）。
///
/// 四页审查发现各页空态完全各行其是（有的纯文字"暂无数据"、
/// 有的只有图标、错误态无处重选）。阶段 2 起列表/详情页的空、错、
/// 离线态一律用本组件，并且 **除 loading 外必须提供 [onRetry]**，
/// 让用户永远有出路。
class StateView extends StatelessWidget {
  const StateView({
    super.key,
    required this.kind,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
    this.icon,
  }) : assert(
          kind == StateViewKind.loading || onRetry != null,
          'StateView: $kind 状态必须提供 onRetry（空/错/离线态要给用户出路）',
        );

  final StateViewKind kind;
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  /// 覆盖默认图标。
  final IconData? icon;

  static IconData _iconFor(StateViewKind kind) => switch (kind) {
        StateViewKind.loading => Icons.hourglass_top_rounded,
        StateViewKind.empty => Icons.inbox_rounded,
        StateViewKind.error => Icons.error_outline_rounded,
        StateViewKind.offline => Icons.wifi_off_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final low = T.color(
        scheme.onSurface, TextTier.low,
        brightness: dark ? Brightness.dark : Brightness.light);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(S.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == StateViewKind.loading)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              Icon(icon ?? _iconFor(kind), size: 40, color: low),
            const SizedBox(height: S.x12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: low),
            ),
            if (kind != StateViewKind.loading) ...[
              const SizedBox(height: S.x16),
              SizedBox(
                height: 36,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(retryLabel),
                  style: TextButton.styleFrom(
                    backgroundColor: T.color(scheme.onSurface, TextTier.fill,
                        brightness: dark
                            ? Brightness.dark
                            : Brightness.light),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(R.control),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
