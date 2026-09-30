import 'package:flutter/material.dart';

import '../style_scope.dart';
import '../style_tokens.dart';
import '../tokens.dart';

/// 分区标题
class SectionLabel extends StatelessWidget {
  final String label;
  const SectionLabel({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = context.uiStyle;
    // 苹果 = iOS grouped section header：无指示条，caption 灰字。
    if (style == UIStyle.apple) {
      return Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: T.color(scheme.onSurface, TextTier.mid,
              brightness: theme.brightness),
        ),
      );
    }
    // 极简 = 改造前原值（指示条 + w700 + onSurface@0.85）。
    final labelColor = style == UIStyle.minimalist
        ? scheme.onSurface.withValues(alpha: 0.85)
        : T.color(scheme.onSurface, TextTier.mid, brightness: theme.brightness);
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: scheme.primary,
            // 小米风格指示条也随卡片走超椭圆（保持风格统一）。
            borderRadius: BorderRadius.circular(style == UIStyle.xiaomi ? 6 : 2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: labelColor,
          ),
        ),
      ],
    );
  }
}

class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const SettingsCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 极简锁改造前原值（圆角 14 + onSurface@0.06 描边），其余风格走 StyleTokens。
    final r = context.uiStyle == UIStyle.minimalist
        ? 14.0
        : StyleTokens.cardRadius(context);
    final border = context.uiStyle == UIStyle.minimalist
        ? Border.all(color: scheme.onSurface.withValues(alpha: 0.06))
        : (() {
            final bs = StyleTokens.cardBorder(context);
            return bs == null
                ? null
                : Border.all(color: bs.color, width: bs.width);
          })();
    final shadows = StyleTokens.cardShadow(context);
    return Container(
      decoration: BoxDecoration(
        color: StyleTokens.groupCardBackground(context),
        borderRadius: BorderRadius.circular(r),
        border: border,
        boxShadow: shadows,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 平台不可用（如 web 上的本地文件功能）时禁用并降饱和提示。
  final bool enabled;
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);
    // 极简锁改造前原值 10，其余风格走控件档。
    final iconRadius = context.uiStyle == UIStyle.minimalist
        ? 10.0
        : StyleTokens.controlRadius(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(iconRadius),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: enabled ? scheme.primary : disabledColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: enabled ? scheme.onSurface : disabledColor,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 11.5,
                            color:
                                enabled
                                    ? scheme.onSurface.withValues(alpha: 0.6)
                                    : disabledColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
                if (trailing == null)
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurface.withValues(alpha: 0.4),
                    size: 22,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
