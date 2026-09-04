import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/tokens.dart';

// 设计 token（间距 S / 圆角 R / 透明度阶 T / 字号阶 TypeScale / 动效阴影 D）
// 已迁至 ui/tokens.dart，此处转出保持既有 import 兼容。
export 'ui/tokens.dart';

/// 设计系统 · Minimalist（极简单色）
///
/// 设计原则（对齐风格方案 C）：
/// - 零彩色：结构层完全走中性灰阶，层级只靠字重 + hairline 细线 + 留白建立。
/// - 零阴影：卡片/浮层一律 1px 描边，不使用 elevation / glow。
/// - 克制圆角：统一 12（卡片）/ 10（控件），拒绝大圆角气泡感。
/// - 强调色：默认「墨」——primary 即近黑，界面里所有 primary 衍生块自动读作中性灰；
///   仍保留 5 档种子色，用户可在设置里替换为彩色强调（主题色选择器不变）。
class AppTheme {
  // ── 中性基座（ink / paper） ──────────────────────────────────────────
  // 品牌/默认强调色 — 墨（近黑），Minimalist 的默认"强调"即中性本身
  static const Color accent = Color(0xFF18181B);

  // 暗色调色板
  static const Color darkBg = Color(0xFF0C0C0E);
  static const Color darkSurface = Color(0xFF17171A);
  static const Color darkSurfaceHigh = Color(0xFF202024);
  static const Color darkBorder = Color(0xFF27272A);
  static const Color darkText = Color(0xFFF4F4F5);
  static const Color darkTextSoft = Color(0xFFA1A1AA);

  // 亮色调色板（纯白纸面）
  static const Color lightBg = Color(0xFFFAFAFA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFF4F4F5);
  static const Color lightBorder = Color(0xFFE4E4E7);
  static const Color lightText = Color(0xFF18181B);
  static const Color lightTextSoft = Color(0xFF71717A);

  /// 多主题种子色：0=墨(默认，纯单色), 1=墨蓝, 2=翡翠绿, 3=靛蓝, 4=薰衣草紫。
  /// Minimalist 默认走 0=墨，界面呈现为纯黑白灰；其余档为可选彩色强调。
  static const List<Color> seeds = [
    Color(0xFF18181B),
    Color(0xFF3A6EA5),
    Color(0xFF2E9A6B),
    Color(0xFF4C6FE0),
    Color(0xFF7A5DE5),
  ];

  static Color seedOf(int id) =>
      (id >= 0 && id < seeds.length) ? seeds[id] : accent;

  /// [isTablet] 传 true（平板/桌面）走桌面档字号，传 false（手机）走手机档字号。
  static ThemeData light([int themeId = 0, bool isTablet = true]) {
    final seed = seedOf(themeId);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      primary: seed,
      onPrimary: Colors.white,
      secondary: seed,
      onSecondary: Colors.white,
      surface: lightSurface,
      onSurface: lightText,
      surfaceContainerHighest: lightSurfaceHigh,
      outline: lightBorder,
      outlineVariant: lightBorder,
      error: const Color(0xFFB3261E),
    );
    return _base(
      scheme: scheme,
      isDark: false,
      seed: seed,
      bg: lightBg,
      border: lightBorder,
      text: lightText,
      textSoft: lightTextSoft,
      isTablet: isTablet,
    );
  }

  /// [isTablet] 传 true（平板/桌面）走桌面档字号，传 false（手机）走手机档字号。
  static ThemeData dark([int themeId = 0, bool isTablet = true]) {
    final seed = seedOf(themeId);
    // 暗色下若种子为"墨"，primary 反转为近白，保证对比与"墨"对称。
    final primary = (themeId == 0) ? const Color(0xFFF4F4F5) : seed;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      primary: primary,
      onPrimary: const Color(0xFF0C0C0E),
      secondary: primary,
      onSecondary: const Color(0xFF0C0C0E),
      surface: darkSurface,
      onSurface: darkText,
      surfaceContainerHighest: darkSurfaceHigh,
      outline: darkBorder,
      outlineVariant: darkBorder,
      error: const Color(0xFFFFB4AB),
    );
    return _base(
      scheme: scheme,
      isDark: true,
      seed: primary,
      bg: darkBg,
      border: darkBorder,
      text: darkText,
      textSoft: darkTextSoft,
      isTablet: isTablet,
    );
  }

  /// 共用主题骨架：Minimalist = 零 elevation + hairline 描边 + 克制的控件尺寸。
  static ThemeData _base({
    required ColorScheme scheme,
    required bool isDark,
    required Color seed,
    required Color bg,
    required Color border,
    required Color text,
    required Color textSoft,
    bool isTablet = true,
  }) {
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent)
            : SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
        titleTextStyle: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: text,
          letterSpacing: 0.1,
        ),
        iconTheme: IconThemeData(color: text),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border, width: 1),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: Colors.transparent,
        elevation: 0,
        height: 66,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final sel = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 10.5,
            fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
            letterSpacing: 0.2,
            color: sel ? text : text.withValues(alpha: 0.42),
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final sel = states.contains(WidgetState.selected);
          return IconThemeData(
            color: sel ? text : text.withValues(alpha: 0.42),
            size: 22,
          );
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: seed,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          textStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: border, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          textStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? darkSurfaceHigh : lightSurfaceHigh,
        hintStyle: TextStyle(color: text.withValues(alpha: 0.38)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: text.withValues(alpha: 0.6), width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? scheme.onPrimary : Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? seed
                : text.withValues(alpha: 0.14)),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? darkSurfaceHigh : lightSurfaceHigh,
        side: BorderSide(color: border, width: 1),
        labelStyle: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: text),
        shape: const StadiumBorder(),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border, width: 1),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: seed,
        linearTrackColor: border,
        circularTrackColor: border,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: seed,
        inactiveTrackColor: border,
        thumbColor: seed,
        overlayColor: seed.withValues(alpha: 0.12),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
    // 6 档字号并入主题派生的 TextTheme：未覆盖的槽位保留平台默认，
    // 已覆盖的 6 档成为全应用字号的唯一来源（阶段 2 迁移调用点的基础）。
    return theme.copyWith(
      textTheme: theme.textTheme.merge(TypeScale.textTheme(text, isTablet: isTablet)),
    );
  }
}

