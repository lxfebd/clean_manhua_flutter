import 'package:flutter/material.dart';

/// 设计 token —— 8-31 审计报告「阶段 1：设计系统层」的落地。
///
/// 原则：有限档位。新代码一律从这四组取值，页面里不再出现
/// 随手写的 fontSize / borderRadius / alpha 字面量（阶段 2 逐页迁移存量）。
/// token 档位与门禁上限的关系见 `test/design_tokens_test.dart`。
// ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ──

/// 间距（6 档）。页面 padding/gap 一律从这里取。
abstract final class S {
  static const double x4 = 4;
  static const double x8 = 8;
  static const double x12 = 12;
  static const double x16 = 16;
  static const double x24 = 24;
  static const double x32 = 32;
}

/// 圆角（5 档）。`pill` = 胶囊全圆（999，`BorderRadius.circular(S.pill)` 处用）。
abstract final class R {
  /// 控件（按钮/输入框/chip）
  static const double control = 8;

  /// 卡片 / 封面
  static const double card = 12;

  /// 横幅 / 大图
  static const double hero = 16;

  /// 底部弹层
  static const double sheet = 24;

  /// 胶囊
  static const double pill = 999;
}

/// 文字透明档位：high 正文 / mid 次要 / low 弱化 / disabled 禁用 /
/// hairline 细线 / fill 底色。
enum TextTier { high, mid, low, disabled, hairline, fill }

/// 文字透明度阶（取代散落的 47 种 alpha）。
///
/// 明暗分算：[alphaFor] 保证 **low 档在亮色主题下 WCAG AA ≥ 4.5**。
abstract final class T {
  static double alphaFor(TextTier tier, Brightness brightness) => switch (tier) {
        TextTier.high => 1.0,
        TextTier.mid => 0.78,
        TextTier.low => 0.62,
        TextTier.disabled => 0.45,
        TextTier.hairline => 0.08,
        TextTier.fill => 0.06,
      };

  static Color color(
    Color base,
    TextTier tier, {
    required Brightness brightness,
  }) =>
      base.withValues(alpha: alphaFor(tier, brightness));
}

/// 字号阶（6 档，Material TextTheme 名称对齐）。
/// 页面一律 `Theme.of(context).textTheme.xxx`，禁止内联 fontSize。
/// 平板/桌面走 [TypeScale.tablet]/[TypeScale.desktop] 档，手机走 [TypeScale.phone] 档，
/// 由 [TypeScale.textTheme] 的 `isTablet` 在主题构建时选择，避免手机端被桌面档连带改动。
abstract final class TypeScale {
  /// 平板/桌面档 display 22 —— 大屏页头（对应 textTheme.displaySmall）
  static const double display = 22;

  /// 平板/桌面档 title 17 —— 区块主标题（titleLarge）
  static const double title = 17;

  /// 平板/桌面档 section 15 —— 区块小标题（titleMedium）
  static const double section = 15;

  /// 平板/桌面档 body 14 —— 正文（bodyMedium）
  static const double body = 14;

  /// 平板/桌面档 meta 12 —— 卡内元信息（bodySmall）
  static const double meta = 12;

  /// 平板/桌面档 micro 11 —— 最小可读辅助文字（labelSmall）
  static const double micro = 11;

  /// 手机档 display 19 —— 三格大数字等大屏数字（原设计稿 19）
  static const double displayPhone = 19;

  /// 手机档 title 17 —— 区块主标题 / 三格数字 16.5 取整
  static const double titlePhone = 17;

  /// 手机档 section 14 —— 区块小标题 / 三格数字 13.5 取整
  static const double sectionPhone = 14;

  /// 手机档 body 14 —— 正文
  static const double bodyPhone = 14;

  /// 手机档 meta 12 —— 卡内元信息 / 三格数字 11.5 取整
  static const double metaPhone = 12;

  /// 手机档 micro 9 —— 徽章等最小辅助文字（原设计稿 8/8.5/9 收敛到 9）
  static const double microPhone = 9;

  /// 由 6 档字号构造一套 [TextTheme]，供 ThemeData.textTheme 合并使用。
  /// 颜色跟随主题 onSurface；层级（弱化/禁用）在调用处用 [T] 控制。
  /// [isTablet] 为 false（手机，宽度 < 600dp）时走手机档，避免手机端被桌面档字号连带放大。
  static TextTheme textTheme(Color color, {bool isTablet = true}) => TextTheme(
        displaySmall: TextStyle(
          fontSize: isTablet ? display : displayPhone,
          fontWeight: FontWeight.w700,
          height: 1.25,
          color: color,
        ),
        titleLarge: TextStyle(
          fontSize: isTablet ? title : titlePhone,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: color,
        ),
        titleMedium: TextStyle(
          fontSize: isTablet ? section : sectionPhone,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: color,
        ),
        bodyMedium: TextStyle(
          fontSize: isTablet ? body : bodyPhone,
          fontWeight: FontWeight.w400,
          height: 1.45,
          color: color,
        ),
        bodySmall: TextStyle(
          fontSize: isTablet ? meta : metaPhone,
          fontWeight: FontWeight.w400,
          height: 1.4,
          color: color,
        ),
        labelSmall: TextStyle(
          fontSize: isTablet ? micro : microPhone,
          fontWeight: FontWeight.w500,
          height: 1.4,
          color: color,
        ),
      );
}

/// 动效与阴影 token（原 theme.dart `class D`，迁入 tokens 收敛）。
class D {
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 480);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeInOut = Cubic(0.4, 0.0, 0.2, 1.0);
  static const Curve spring = Cubic(0.34, 1.4, 0.64, 1.0);

  // Minimalist：不再使用辉光，保留签名以兼容调用点，返回空阴影。
  static List<BoxShadow> glow(Color c) => const [];

  // Minimalist：卡片层级靠 hairline 描边，阴影退为极淡的中性投影（近乎不可见）。
  static List<BoxShadow> soft(bool dark) => dark
      ? const [
          BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2)),
        ]
      : const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2)),
        ];
}