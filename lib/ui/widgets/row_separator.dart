import 'package:flutter/material.dart';

import '../style_scope.dart';
import '../style_tokens.dart';
import '../tokens.dart';

/// 分组内行分隔线（风格轴）。
///
/// **极简 = 调用点原值**（`tier` / `indent` 由调用点传入，逐字节等同改造前）：
/// 设置页手写分隔线是通栏 `T.fill(0.06)`，[SettingsRow] 是 inset 64 +
/// `T.hairline(0.08)` —— 两处原值不同，所以原值必须由调用点给出，不能由
/// 组件统一。
///
/// 非极简走风格轴：
/// - 苹果：iOS inset grouped，hairline 更淡，从文本列起（默认 46 = icon 列 34 + 间距 12）；
/// - 小米：HyperOS 通栏 hairline（不缩进）。
class RowSeparator extends StatelessWidget {
  const RowSeparator({super.key, this.tier = TextTier.fill, this.indent = 0});

  /// 极简下生效的分隔线档位（= 该调用点改造前的档位）。
  final TextTier tier;

  /// 极简下生效的左缩进（= 该调用点改造前的缩进）。
  final double indent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    final brightness = Theme.of(context).brightness;
    final color =
        style == UIStyle.minimalist
            ? T.color(scheme.onSurface, tier, brightness: brightness)
            : StyleTokens.rowSeparatorColor(context);
    final left = StyleTokens.separatorIndent(context, indent);
    final line = Container(
      height: 0.5,
      decoration: BoxDecoration(color: color),
    );
    if (left == 0) return line;
    return Padding(padding: EdgeInsets.only(left: left), child: line);
  }
}
