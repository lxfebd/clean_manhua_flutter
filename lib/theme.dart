import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 设计系统
/// 简洁克制的单色主题：墨蓝强调色 + 中性灰阶，
/// 避免高饱和撞色，保持阅读类应用的低干扰感。
class AppTheme {
  // 品牌色 — 沉稳墨蓝（默认种子色）
  static const Color accent = Color(0xFF3A6EA5);
  // 暗色调色板
  static const Color darkBg = Color(0xFF111215);
  static const Color darkSurface = Color(0xFF181A1E);
  static const Color darkSurfaceHigh = Color(0xFF202328);
  static const Color darkBorder = Color(0x14FFFFFF);
  static const Color darkText = Color(0xFFE8EAF0);
  static const Color darkTextSoft = Color(0xFF8B92A8);

  // 亮色调色板（柔和米白）
  static const Color lightBg = Color(0xFFFAFAF8);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFF1F1EE);
  static const Color lightBorder = Color(0x1A1A1D26);
  static const Color lightText = Color(0xFF1A1D26);
  static const Color lightTextSoft = Color(0xFF6B7280);

  /// 多主题种子色：0=墨蓝(默认), 1=东京夜(紫蓝), 2=翡翠绿, 3=暖橙, 4=薰衣草紫。
  static const List<Color> seeds = [
    Color(0xFF3A6EA5),
    Color(0xFF7A6FE0),
    Color(0xFF2E9A6B),
    Color(0xFFE0823C),
    Color(0xFF9B5DE5),
  ];

  static Color seedOf(int id) =>
      (id >= 0 && id < seeds.length) ? seeds[id] : accent;

  static ThemeData light([int themeId = 0]) {
    final seed = seedOf(themeId);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      primary: seed,
      onPrimary: Colors.white,
      surface: lightSurface,
      onSurface: lightText,
      surfaceContainerHighest: lightSurfaceHigh,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: lightBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: lightText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: lightText,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: lightBorder, width: 0.6),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: lightSurface.withValues(alpha: 0.94),
        indicatorColor: Colors.transparent,
        elevation: 0,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: lightText);
          }
          return const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500, color: Color(0x591A1D26));
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: lightText, size: 24);
          }
          return const IconThemeData(color: Color(0x591A1D26), size: 23);
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: seed,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: lightText,
          side: BorderSide(color: lightBorder, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightSurfaceHigh,
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
          borderSide: BorderSide(color: seed, width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return seed;
          return lightBorder;
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      dividerTheme: DividerThemeData(
        color: lightBorder,
        thickness: 0.5,
        space: 0.5,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: seed,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: lightSurfaceHigh,
        side: BorderSide.none,
        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        shape: StadiumBorder(),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData dark([int themeId = 0]) {
    final seed = seedOf(themeId);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      primary: seed,
      onPrimary: Colors.white,
      surface: darkSurface,
      onSurface: darkText,
      surfaceContainerHighest: darkSurfaceHigh,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: darkBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: darkText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: darkText,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: darkBorder, width: 0.6),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: darkSurface.withValues(alpha: 0.9),
        indicatorColor: Colors.transparent,
        elevation: 0,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: darkText);
          }
          return const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500, color: Color(0x59E8EAF0));
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: darkText, size: 24);
          }
          return const IconThemeData(color: Color(0x59E8EAF0), size: 23);
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: seed,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: darkText,
          side: BorderSide(color: darkBorder, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurfaceHigh,
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
          borderSide: BorderSide(color: seed, width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return seed;
          return darkBorder;
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      dividerTheme: DividerThemeData(
        color: darkBorder,
        thickness: 0.5,
        space: 0.5,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: seed,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: darkSurfaceHigh,
        side: BorderSide.none,
        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        shape: StadiumBorder(),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 设计 token（阴影、缓动函数、间距）
class D {
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration medium = Duration(milliseconds: 320);
  static const Duration slow = Duration(milliseconds: 560);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeInOut = Cubic(0.4, 0.0, 0.2, 1.0);
  static const Curve spring = Cubic(0.34, 1.56, 0.64, 1.0);

  // 卡片阴影（亮色用柔光，暗色用发光）
  static List<BoxShadow> glow(Color c) => [
        BoxShadow(
          color: c.withValues(alpha: 0.35),
          blurRadius: 20,
          spreadRadius: -4,
        ),
      ];

  static List<BoxShadow> soft(bool dark) => dark
      ? const [
          BoxShadow(
              color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 8)),
        ]
      : const [
          BoxShadow(
              color: Color(0x10000000), blurRadius: 14, offset: Offset(0, 4)),
        ];
}