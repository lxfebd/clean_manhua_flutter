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

  /// hero 槽位（头图 / 大卡）。极简 = 调用点原值（各页历史值不同：详情页头图 14、
  /// 书架封面 10、首页轮播 12），所以原值由调用点传入；小米 = HyperOS 大圆角；
  /// 苹果 = iOS 标准 cornerRadius。
  static double heroRadius(BuildContext c, double minimalistOriginal) =>
      switch (c.uiStyle) {
        UIStyle.minimalist => minimalistOriginal,
        UIStyle.xiaomi => R.heroXiaomi,
        UIStyle.apple => R.heroApple,
      };

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

  // ── 分组列表（苹果 inset grouped）────────────────────────────────────
  /// 列表行图标底块：极简 = 调用点原值（SettingsRow 34）；苹果 = iOS Settings 行的
  /// 29pt 圆角方块容器；小米 = HyperOS 40dp 容器。
  static double iconTileSize(BuildContext c, double minimalistOriginal) =>
      switch (c.uiStyle) {
        UIStyle.minimalist => minimalistOriginal,
        UIStyle.apple => 29,
        UIStyle.xiaomi => 40,
      };

  /// 底块内图标本体：极简锁 18；苹果 17（iOS 字形）；小米 20。
  static double iconGlyphSize(BuildContext c, double minimalistOriginal) =>
      switch (c.uiStyle) {
        UIStyle.minimalist => minimalistOriginal,
        UIStyle.apple => 17,
        UIStyle.xiaomi => 20,
      };

  /// 分组卡底色：极简 = 改造前原值 [ColorScheme.surface]；苹果 = iOS 二级分组
  /// 背景（surfaceContainer，卡与屏幕底色拉开层次）；小米 = surface（走渐变卡）。
  static Color groupCardBackground(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    return c.uiStyle == UIStyle.apple ? scheme.surfaceContainer : scheme.surface;
  }

  /// 行分隔线颜色：极简 = 改造前原值 `onSurface @ T.fill(0.06)`；苹果/小米 =
  /// hairline(0.08)。
  static Color rowSeparatorColor(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    final tier = c.uiStyle == UIStyle.minimalist
        ? TextTier.fill
        : TextTier.hairline;
    return scheme.onSurface.withValues(
      alpha: T.alphaFor(tier, Theme.of(c).brightness),
    );
  }

  /// 分隔线左右缩进。极简 = 调用点原值（各页历史上写的值不同：设置页 0/0、
  /// 详情页 16/16、SettingsRow 64/0），所以原值由调用点传入；苹果 = iOS inset
  /// grouped（从文本列起，右侧留 16）；小米 = HyperOS 通栏。
  static double separatorIndent(BuildContext c, double minimalistOriginal) =>
      switch (c.uiStyle) {
        UIStyle.minimalist => minimalistOriginal,
        UIStyle.apple => 46,
        UIStyle.xiaomi => 0,
      };

  static double separatorEndIndent(BuildContext c, double minimalistOriginal) =>
      switch (c.uiStyle) {
        UIStyle.minimalist => minimalistOriginal,
        UIStyle.apple => 16,
        UIStyle.xiaomi => 0,
      };

  // ── 动效 ────────────────────────────────────────────────────────────
  // 极简分支逐字节锁定改造前原值（与圆角同样的回归面原则）：
  // PressableScale 原为 120ms/easeOut，FadeSlideIn 原为 480ms/Cubic(0.16,1,0.3,1)。

  /// 按下反馈曲线：极简 = 原值 easeOut；小米 = HyperOS 回弹（过冲后收敛）；
  /// 苹果 = iOS spring 近似（无过冲）。
  static Curve pressCurve(BuildContext c) => switch (c.uiStyle) {
        UIStyle.minimalist => Curves.easeOut,
        UIStyle.xiaomi => Curves.easeOutBack,
        UIStyle.apple => const Cubic(0.32, 0.72, 0, 1),
      };

  /// 按下反馈时长：极简 = 原值 120ms。
  static Duration pressDuration(BuildContext c) => switch (c.uiStyle) {
        UIStyle.minimalist => const Duration(milliseconds: 120),
        UIStyle.xiaomi => const Duration(milliseconds: 180),
        UIStyle.apple => const Duration(milliseconds: 200),
      };

  /// 入场曲线：极简 = 原值 Cubic(0.16, 1, 0.3, 1)；小米 = HyperOS 回弹（过冲后
  /// 收敛）；苹果用 iOS 标准 ease（无过冲）。
  static Curve entranceCurve(BuildContext c) => switch (c.uiStyle) {
        UIStyle.minimalist => const Cubic(0.16, 1, 0.3, 1),
        UIStyle.xiaomi => Curves.easeOutBack,
        UIStyle.apple => const Cubic(0.25, 0.1, 0.25, 1),
      };

  /// 入场时长：极简 = 原值 480ms。
  static Duration entranceDuration(BuildContext c) => switch (c.uiStyle) {
        UIStyle.minimalist => const Duration(milliseconds: 480),
        UIStyle.xiaomi => const Duration(milliseconds: 420),
        UIStyle.apple => const Duration(milliseconds: 380),
      };

  /// 页面转场时长/曲线：极简各调用点锁原值（320/360/260），此处只给非极简档。
  static Duration transitionDuration(BuildContext c) => switch (c.uiStyle) {
        UIStyle.minimalist => const Duration(milliseconds: 320),
        UIStyle.xiaomi => const Duration(milliseconds: 300),
        UIStyle.apple => const Duration(milliseconds: 400),
      };

  static Curve transitionCurve(BuildContext c) => switch (c.uiStyle) {
        UIStyle.minimalist => Curves.easeOutCubic,
        UIStyle.xiaomi => Curves.easeOutBack,
        UIStyle.apple => const Cubic(0.25, 0.1, 0.25, 1),
      };

  // ── 苹果毛玻璃 ──────────────────────────────────────────────────────
  /// 苹果风格毛玻璃半透明底（亮/暗分档），非苹果风格返回纯表面色。
  static Color frostedBackground(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    final dark = Theme.of(c).brightness == Brightness.dark;
    if (c.uiStyle != UIStyle.apple) return scheme.surface;
    return scheme.surface.withValues(alpha: dark ? 0.72 : 0.78);
  }
}
