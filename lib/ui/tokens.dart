import 'package:flutter/material.dart';

import 'style_scope.dart';

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

  // ── 按风格取值 ─────────────────────────────────────────────────────
  // 三套 UI 风格的圆角档位。风格化组件（S2/S3 迁移）用 `R.of(context)` 取，
  // 保证同一语义槽位（control/card/hero/sheet）在各风格下都有定义，且
  // 只新增档位、不动 [control]/[card] 等既有多处引用的静态值（回归面最小）。
  //
  // - minimalist：与静态档位一致（8/12/16/24）—— 极简不因风格轴改变。
  // - xiaomi：超椭圆大圆角（HyperOS 特征）。
  // - apple：iOS 标准 cornerRadius（10/12/16/28），弹层 28 略大贴近系统 sheet。
  static const double controlXiaomi = 14;
  static const double cardXiaomi = 20;
  static const double heroXiaomi = 28;
  static const double sheetXiaomi = 36;

  static const double controlApple = 10;
  static const double cardApple = 12;
  static const double heroApple = 16;
  static const double sheetApple = 28;

  /// 由 [UIStyle] 解析各语义槽位的圆角——风格化组件（S2/S3）统一入口。
  /// 槽位用 [control]/[card]/[hero]/[sheet] 静态值传入；未知槽位回退卡片档。
  static double of(double slot, {required UIStyle style}) {
    final r = switch (style) {
      UIStyle.minimalist => <double>[control, card, hero, sheet],
      UIStyle.xiaomi => <double>[controlXiaomi, cardXiaomi, heroXiaomi, sheetXiaomi],
      UIStyle.apple => <double>[controlApple, cardApple, heroApple, sheetApple],
    };
    final idx = slot == control
        ? 0
        : slot == card
            ? 1
            : slot == hero
                ? 2
                : slot == sheet
                    ? 3
                    : 1; // 未知槽位回退卡片档
    return r[idx];
  }
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
  /// [isTablet] 为 false（手机，宽度 < 600dp）时走手机档，避免手机端被桌面档连带放大。
  /// [style] 决定整套阶梯（字号 + 字重 + 行高），见 [_ramp]。
  static TextTheme textTheme(Color color,
      {bool isTablet = true, UIStyle style = UIStyle.minimalist}) {
    final ramp = _ramp(style, isTablet);
    TextStyle slot(double fontSize, FontWeight weight, double height) => TextStyle(
        fontSize: fontSize, fontWeight: weight, height: height, color: color);
    return TextTheme(
      displaySmall: slot(ramp.display, ramp.wDisplay, ramp.hDisplay),
      titleLarge: slot(ramp.title, ramp.wTitle, ramp.hTitle),
      titleMedium: slot(ramp.section, ramp.wSection, ramp.hSection),
      bodyMedium: slot(ramp.body, ramp.wBody, ramp.hBody),
      bodySmall: slot(ramp.meta, ramp.wMeta, ramp.hMeta),
      labelSmall: slot(ramp.micro, ramp.wMicro, ramp.hMicro),
    );
  }

  // ── 按风格的字号阶梯（极简用上面的既有档位）─────────────────────────
  /// 苹果 = iOS Dynamic Type（Large 默认档）：Subheadline 15 / Footnote 13 /
  /// Caption1 12。iOS 不按屏幕宽度分两套档，苹果手机与平板同阶梯。
  static const double bodyApple = 15;
  static const double metaApple = 13;
  static const double microApple = 12;

  /// 小米 = HyperOS：大标题 24（手机 22）/ 卡片标题 18，正文沿用 Android 14/12/11。
  static const double displayXiaomi = 24;
  static const double displayXiaomiPhone = 22;
  static const double titleXiaomi = 18;

  /// 三套阶梯 = 六档字号 + 字重 + 行高。
  ///
  /// - **极简**：逐字节锁既有档位与既有字重/行高（回归面为零）。
  /// - **苹果**：iOS 阶梯 Title1 22 / Title2 17 / Headline 15 / Subheadline 15 /
  ///   Footnote 13 / Caption1 12；标题 semibold、正文 regular（iOS 不用 w700 大标题），
  ///   行高 1.2-1.35 比 Android 紧。
  /// - **小米**：HyperOS 阶梯，大标题与卡片标题偏粗（w700），行高沿用 Android。
  static _TypeRamp _ramp(UIStyle style, bool isTablet) => switch (style) {
      UIStyle.minimalist => (
          display: isTablet ? display : displayPhone,
          title: isTablet ? title : titlePhone,
          section: isTablet ? section : sectionPhone,
          body: isTablet ? body : bodyPhone,
          meta: isTablet ? meta : metaPhone,
          micro: isTablet ? micro : microPhone,
          wDisplay: FontWeight.w700,
          wTitle: FontWeight.w600,
          wSection: FontWeight.w600,
          wBody: FontWeight.w400,
          wMeta: FontWeight.w400,
          wMicro: FontWeight.w500,
          hDisplay: 1.25,
          hTitle: 1.3,
          hSection: 1.3,
          hBody: 1.45,
          hMeta: 1.4,
          hMicro: 1.4),
      UIStyle.apple => (
          display: display,
          title: title,
          section: section,
          body: bodyApple,
          meta: metaApple,
          micro: microApple,
          wDisplay: FontWeight.w600,
          wTitle: FontWeight.w600,
          wSection: FontWeight.w600,
          wBody: FontWeight.w400,
          wMeta: FontWeight.w400,
          wMicro: FontWeight.w400,
          hDisplay: 1.2,
          hTitle: 1.25,
          hSection: 1.25,
          hBody: 1.35,
          hMeta: 1.3,
          hMicro: 1.3),
      UIStyle.xiaomi => (
          display: isTablet ? displayXiaomi : displayXiaomiPhone,
          title: titleXiaomi,
          section: section,
          body: body,
          meta: meta,
          micro: micro,
          wDisplay: FontWeight.w700,
          wTitle: FontWeight.w700,
          wSection: FontWeight.w600,
          wBody: FontWeight.w400,
          wMeta: FontWeight.w400,
          wMicro: FontWeight.w500,
          hDisplay: 1.25,
          hTitle: 1.3,
          hSection: 1.3,
          hBody: 1.45,
          hMeta: 1.4,
          hMicro: 1.4),
    };
}

/// 六档字号 + 字重 + 行高的阶梯快照（[TypeScale._ramp] 按风格构造）。
typedef _TypeRamp = ({
  double display,
  double title,
  double section,
  double body,
  double meta,
  double micro,
  FontWeight wDisplay,
  FontWeight wTitle,
  FontWeight wSection,
  FontWeight wBody,
  FontWeight wMeta,
  FontWeight wMicro,
  double hDisplay,
  double hTitle,
  double hSection,
  double hBody,
  double hMeta,
  double hMicro,
});