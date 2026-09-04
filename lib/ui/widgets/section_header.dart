import 'package:flutter/material.dart';

import '../tokens.dart';

/// 区块标题行（统一 44 高）。
///
/// 四页审查中"继续观看/热门推荐/书架分区"等标题风格各异
/// （字号 15/16/17、有无副标题、有无"更多"随机出现）。
/// 阶段 2 起所有列表区块一律使用本组件：
/// 左侧 [TypeScale.section] 标题，右侧可选 [action]（"更多"文字按钮
/// 或图标），高度固定 [height]，与 [TapTargetMin] 同为 44 网格对齐。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.symmetric(horizontal: S.x16),
  });

  final String title;

  /// 标题旁的小字说明（可为空）。
  final String? subtitle;

  /// 右侧操作：传 Widget（如 Text('更多')）；配合 [onAction] 自动套水波。
  final Widget? action;
  final VoidCallback? onAction;

  final EdgeInsetsGeometry padding;

  /// 标题行统一高度，与 44dp 命中区网格一致。
  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: height,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(width: S.x8),
                    Flexible(
                      child: Text(
                        subtitle!,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: dark
                                  ? Brightness.dark
                                  : Brightness.light),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (action != null)
              onAction == null
                  ? action!
                  : InkWell(
                      borderRadius: BorderRadius.circular(R.control),
                      onTap: onAction,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: S.x8, vertical: S.x4),
                        child: DefaultTextStyle(
                          style: text.bodySmall!.copyWith(
                            color: T.color(scheme.onSurface, TextTier.mid,
                                brightness: dark
                                    ? Brightness.dark
                                    : Brightness.light),
                          ),
                          child: action!,
                        ),
                      ),
                    ),
          ],
        ),
      ),
    );
  }
}
