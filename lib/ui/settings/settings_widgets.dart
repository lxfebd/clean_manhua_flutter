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
    final r = StyleTokens.cardRadiusOr(context, 14);
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
