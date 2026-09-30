import 'package:flutter/material.dart';

import 'style_scope.dart';
import 'tokens.dart';

/// 风格感知的 UI 属性集（S1 起统一从这里取值）。
///
/// S0 已把圆角档位并入 [R]，此处把**需要「按风格分支」的组件属性**集中：
/// - [controlRadius]/[cardRadius]/[sheetRadius]：控件/卡片/弹层圆角；
/// - [cardBorder]：卡片描边策略（极简 hairline / 苹果细分割线 / 小米无描边）；
/// - [cardShadow]：卡片阴影（小米彩色浮起 / 其余无）；
/// - [gradient]：主渐变（小米高饱和品牌渐变 / 苹果系统蓝淡渐变 / 极简中性）。
///
/// 极简风格下所有取值与现有实现逐字节一致（回归面为零）。
/// 小米/苹果分支仅影响视觉属性，不碰布局/尺寸/热区（44dp 门禁由组件保持）。
class StyleTokens {
  const StyleTokens._();

  // ── 圆角 ────────────────────────────────────────────────────────────
  static double controlRadius(BuildContext c, {UIStyle? style}) {
    final s = style ?? c.uiStyle;
    return switch (s) {
      UIStyle.minimalist => R.control,
      UIStyle.xiaomi => R.controlXiaomi,
      UIStyle.apple => R.controlApple,
    };
  }

  static double cardRadius(BuildContext c, {UIStyle? style}) {
    final s = style ?? c.uiStyle;
    return switch (s) {
      UIStyle.minimalist => R.card,
      UIStyle.xiaomi => R.cardXiaomi,
      UIStyle.apple => R.cardApple,
    };
  }

  static double sheetRadius(BuildContext c, {UIStyle? style}) {
    final s = style ?? c.uiStyle;
    return switch (s) {
      UIStyle.minimalist => R.sheet,
      UIStyle.xiaomi => R.sheetXiaomi,
      UIStyle.apple => R.sheetApple,
    };
  }

  // ── 卡片描边/阴影 ───────────────────────────────────────────────────
  /// 卡片描边：极简 = hairline 全描边；苹果 = 更淡的分割线；
  /// 小米 = 无描边（靠彩色阴影浮起）。返回 null = 不画描边。
  static BorderSide? cardBorder(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    return switch (c.uiStyle) {
      UIStyle.minimalist => BorderSide(color: scheme.outlineVariant, width: 1),
      UIStyle.apple => BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
          width: 0.5,
        ),
      UIStyle.xiaomi => null,
    };
  }

  /// 卡片阴影：小米 = 柔和彩色浮起；其余 = 无阴影（null）。
  static List<BoxShadow>? cardShadow(BuildContext c) {
    if (c.uiStyle != UIStyle.xiaomi) return null;
    final scheme = Theme.of(c).colorScheme;
    final dark = Theme.of(c).brightness == Brightness.dark;
    return [
      BoxShadow(
        color: scheme.primary.withValues(alpha: dark ? 0.18 : 0.14),
        blurRadius: 16,
        offset: const Offset(0, 6),
      ),
    ];
  }

  /// 小米「高饱和渐变卡片」底色：品牌色柔和 tint 在 [surface] 上（HyperOS 卡片
  /// 观感：浅色底 + 彩色渐变层次 + 彩色投影）。极简/苹果不用渐变卡，回退 null
  /// （调用方用纯色）。
  ///
  /// 曾用「primary → 更亮/更暗」的深色渐变：桌面默认种子「墨」在亮色下是近黑，
  /// 渐变卡变深黑底，而卡上文字是 onSurface（也深色）→ 内容不可见（用户实测
  /// 反馈）。改为 surface 打底的 tint，文字对比度与纯色卡持平，仅叠加品牌色相。
  static Gradient? cardGradient(BuildContext c) {
    if (c.uiStyle != UIStyle.xiaomi) return null;
    final scheme = Theme.of(c).colorScheme;
    final dark = Theme.of(c).brightness == Brightness.dark;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? [
              Color.lerp(scheme.surface, scheme.primary, 0.10)!,
              Color.lerp(scheme.surface, scheme.primary, 0.16)!,
            ]
          : [
              Color.lerp(scheme.surface, scheme.primary, 0.05)!,
              Color.lerp(scheme.surface, scheme.primary, 0.10)!,
            ],
    );
  }

  // ── 苹果毛玻璃 ──────────────────────────────────────────────────────
  /// 苹果风格毛玻璃半透明底（亮/暗分档），非苹果风格返回纯表面色。
  static Color frostedBackground(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    final dark = Theme.of(c).brightness == Brightness.dark;
    if (c.uiStyle != UIStyle.apple) return scheme.surface;
    return scheme.surface.withValues(alpha: dark ? 0.72 : 0.78);
  }
}
