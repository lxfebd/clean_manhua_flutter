import 'package:flutter/material.dart';

import '../style_scope.dart';
import '../style_tokens.dart';
import '../tokens.dart';
import 'squircle.dart';

/// 风格感知卡片容器（S2/S3 页面卡片的统一底座）。
///
/// 三套风格下同一语义卡片的差异集中在**形状与表面**：
/// - [UIStyle.minimalist]：圆角 [R.card] + hairline 描边（现有实现，回归为零）；
/// - [UIStyle.xiaomi]：超椭圆大圆角 + 品牌渐变 + 柔和彩色阴影（无描边）；
/// - [UIStyle.apple]：圆角 [R.cardApple] + 细分隔线（inset grouped 观感）。
///
/// 布局/尺寸/内边距与热区保持不变（44dp 门禁由调用方组件遵守）。
class StyleCard extends StatelessWidget {
  const StyleCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius,
    this.gradient,
    this.color,
    this.onTap,
    this.shape,
  });

  final Widget child;

  /// 内边距；null = 不包裹 padding（调用方自控）。
  final EdgeInsetsGeometry? padding;

  final EdgeInsetsGeometry? margin;

  /// 圆角覆盖（默认按风格取 [R] 卡片档）。
  final double? radius;

  /// 渐变覆盖（默认小米用品牌渐变，其余 null）。
  final Gradient? gradient;

  /// 表面色覆盖（默认按风格：小米渐变底 / 其余 surface）。
  final Color? color;

  final VoidCallback? onTap;

  /// 形状覆盖（传非 null 时完全自定义，绕过风格分支）。
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) {
    final style = context.uiStyle;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final r = radius ?? StyleTokens.cardRadius(context);
    final effectiveGradient =
        gradient ??
        (style == UIStyle.xiaomi
            ? (StyleTokens.cardGradient(context) ??
                LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary,
                    dark
                        ? Color.lerp(scheme.primary, Colors.black, 0.35)!
                        : Color.lerp(scheme.primary, Colors.white, 0.18)!,
                  ],
                ))
            : null);
    final borderSide = StyleTokens.cardBorder(context);
    final shadows = StyleTokens.cardShadow(context);
    final bg = color ??
        (effectiveGradient == null ? scheme.surface : scheme.primary);

    Widget card = Container(
      margin: margin,
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: effectiveGradient == null ? bg : null,
        gradient: effectiveGradient,
        borderRadius: style == UIStyle.xiaomi ? null : BorderRadius.circular(r),
        border: borderSide == null ? null : Border.all(color: borderSide.color, width: borderSide.width),
        boxShadow: shadows,
      ),
      child: style == UIStyle.xiaomi
          ? ClipPath(
              clipper: SquircleClipper(radius: r),
              child: child,
            )
          : child,
    );

    if (onTap != null) {
      card = InkWell(
        onTap: onTap,
        borderRadius: style == UIStyle.xiaomi ? null : BorderRadius.circular(r),
        child: card,
      );
    }
    return card;
  }
}