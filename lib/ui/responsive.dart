import 'package:flutter/material.dart';

/// 响应式布局工具：断点判定 / 网格列数 / 导航模式 / 内容限宽。
///
/// 断点参考 Material Design 3 + 业界标准：
/// - compact（手机）：0–440dp
/// - medium（小平板/折叠屏）：440–840dp
/// - expanded（平板）：840–1200dp
/// - large（桌面）：1200dp+
class Responsive {
  // 平板断点取 440dp：多数 7–10 寸平板竖屏宽在 450–550dp，
  // 普通手机（360–430dp）不受影响。
  static const double _mediumBreak = 440;
  static const double _expandedBreak = 840;
  static const double _largeBreak = 1200;

  /// 当前屏幕宽度（dp）。
  static double widthOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width;

  /// 是否手机（< 600dp）。
  static bool isCompact(BuildContext context) =>
      widthOf(context) < _mediumBreak;

  /// 是否中等屏（小平板/折叠屏，600–840dp）。
  static bool isMedium(BuildContext context) {
    final w = widthOf(context);
    return w >= _mediumBreak && w < _expandedBreak;
  }

  /// 是否平板（≥ 600dp，含 medium + expanded + large）。
  static bool isTablet(BuildContext context) =>
      widthOf(context) >= _mediumBreak;

  /// 是否大屏平板（≥ 840dp）。
  static bool isExpanded(BuildContext context) =>
      widthOf(context) >= _expandedBreak;

  /// 是否桌面级（≥ 1200dp）。
  static bool isLarge(BuildContext context) =>
      widthOf(context) >= _largeBreak;

  /// 内容卡片网格：根据屏幕宽度返回最佳列数。
  /// 手机 3 列 → 大手机 4 → 平板 5–6 → 桌面 7–8。
  static int gridColumns(BuildContext context, {double itemWidth = 120}) {
    final w = widthOf(context);
    // 留 24dp padding 两侧，按指定卡片宽度计算列数，最少 2 列
    final usable = w - 32;
    final cols = (usable / itemWidth).floor().clamp(2, 8);
    return cols;
  }

  /// 章节网格列数（章节卡片更小，可以更密集）。
  static int chapterGridColumns(BuildContext context) {
    final w = widthOf(context);
    if (w < _mediumBreak) return 6;
    if (w < _expandedBreak) return 8;
    if (w < _largeBreak) return 10;
    return 12;
  }

  /// 剧集网格列数。
  static int episodeGridColumns(BuildContext context) {
    final w = widthOf(context);
    if (w < _mediumBreak) return 4;
    if (w < _expandedBreak) return 6;
    if (w < _largeBreak) return 8;
    return 10;
  }

  /// 工具箱网格列数。
  static int toolGridColumns(BuildContext context) {
    final w = widthOf(context);
    if (w < _mediumBreak) return 2;
    if (w < _expandedBreak) return 3;
    if (w < _largeBreak) return 4;
    return 5;
  }

  /// 内容最大宽度（超宽屏时限制内容不无限拉伸）。
  /// 平板不限宽，桌面限 1600dp。
  static double? maxContentWidth(BuildContext context) {
    final w = widthOf(context);
    if (w >= _largeBreak) return 1600;
    return null;
  }

  /// 卡片间距：平板比手机更宽松。
  static double gridSpacing(BuildContext context) {
    return isTablet(context) ? 14 : 10;
  }

  /// 页面水平 padding：平板居中限宽，手机 16dp。
  static double pagePadding(BuildContext context) {
    return isTablet(context) ? 24 : 16;
  }
}

/// 限制内容最大宽度的包装器（超宽屏居中）。
class MaxWidthContainer extends StatelessWidget {
  final Widget child;
  final double? maxWidth;
  const MaxWidthContainer({super.key, required this.child, this.maxWidth});

  @override
  Widget build(BuildContext context) {
    final mw = maxWidth ?? Responsive.maxContentWidth(context);
    if (mw == null) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mw),
        child: child,
      ),
    );
  }
}
