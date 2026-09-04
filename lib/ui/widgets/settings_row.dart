import 'package:flutter/material.dart';

import '../tokens.dart';

/// 设置/功能列表行（合并"我的"页 `_Row` 与设置页 `_SettingTile`）。
///
/// 两页原本各有一套行组件（图标底块 34/32、字号 14/15、间距 14/12 各写
/// 各的）。阶段 2 起入口行一律本组件：图标底块 + 标题 + 可选副标题 +
/// trailing（开关/箭头/文字），整行 ≥44 高，自带可选分隔线。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconColor,
    this.showDivider = false,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 行尾控件；null 时自动显示 chevron（仅当 [onTap] 非空）。
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 图标着色（如"退出登录"用 error 色）；null 跟随文字弱化档。
  final Color? iconColor;

  /// 行顶细分隔线（列表卡片内行间用）。
  final bool showDivider;

  /// 危险操作：文字/图标转 error 色。
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    final accent = danger ? scheme.error : iconColor;
    final labelColor = danger
        ? scheme.error
        : T.color(scheme.onSurface, TextTier.high, brightness: brightness);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Column(
          children: [
            if (showDivider)
              Container(
                height: 0.5,
                margin: const EdgeInsets.only(left: 64),
                color: T.color(scheme.onSurface, TextTier.hairline,
                    brightness: brightness),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: S.x16, vertical: S.x12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: T.color(scheme.onSurface, TextTier.fill,
                          brightness: brightness),
                      borderRadius: BorderRadius.circular(R.control),
                    ),
                    child: Icon(
                      icon,
                      size: 18,
                      color: accent ??
                          T.color(scheme.onSurface, TextTier.mid,
                              brightness: brightness),
                    ),
                  ),
                  const SizedBox(width: S.x12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            overflow: TextOverflow.ellipsis,
                            style:
                                text.bodyMedium?.copyWith(color: labelColor)),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: T.color(scheme.onSurface, TextTier.low,
                                  brightness: brightness),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null)
                    trailing!
                  else if (onTap != null)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: T.color(scheme.onSurface, TextTier.disabled,
                          brightness: brightness),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
