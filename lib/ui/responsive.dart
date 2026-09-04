import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 响应式布局系统 - 遵循 Material Design 3 + 业界标准
// ══════════════════════════════════════════════════════════════════════════════
//
// 断点参考 Material Design 3 大屏幕指南：
// - compact（手机）：     < 600dp  → BottomNavigationBar
// - medium（小平板）：    600–840dp → NavigationRail（可折叠）
// - expanded（平板）：    840–1200dp → NavigationRail（图标+标签）
// - large（桌面）：       > 1200dp → NavigationRail（图标+标签）+ 更宽内容区
//   （注：实际导航统一采用 NavigationRail，未实现 NavigationDrawer；见 main_shell.dart）
//
// 参考资料：
// - https://docs.flutter.dev/ui/adaptive-responsive
// - https://m3.material.io/foundations/layout/applying-layout/window-size-classes
// ══════════════════════════════════════════════════════════════════════════════

/// 桌面端判定：桌面 UI 形态（宽侧栏、居中对话框、悬停优先）只在
/// 真正的桌面平台（Windows/macOS/Linux）启用；
/// 平板大屏（如 12.9" 平板横屏 ≥1200dp）仍保持平板布局，不与桌面混同。
/// 这样同一套响应式体系下，电脑端拥有自己的导航形态与弹层形态，
/// 而不是套用移动端的面板/底部弹层。
class DesktopUi {
  DesktopUi._();

  /// 用 [defaultTargetPlatform] 而非 dart:io [Platform]：前者可被测试里的
  /// debugDefaultTargetPlatformOverride 覆盖。dart:io 在 `flutter test` 中
  /// 恒报宿主机（Windows）为真，会导致 widget 测试永远走桌面弹层分支。
  static bool get isDesktopPlatform =>
      !kIsWeb &&
      const {
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);
}

/// 屏幕尺寸分类枚举（Material Design 3 标准）。
enum ScreenSize {
  /// 手机：0–600dp
  compact(0, 600),

  /// 小平板/折叠屏：600–840dp
  medium(600, 840),

  /// 平板/笔记本：840–1200dp
  expanded(840, 1200),

  /// 桌面显示器：1200dp+
  large(1200, double.infinity);

  final double min;
  final double max;
  const ScreenSize(this.min, this.max);

  /// 根据宽度获取屏幕尺寸分类。
  static ScreenSize fromWidth(double width) {
    if (width >= ScreenSize.large.min) return ScreenSize.large;
    if (width >= ScreenSize.expanded.min) return ScreenSize.expanded;
    if (width >= ScreenSize.medium.min) return ScreenSize.medium;
    return ScreenSize.compact;
  }
}

/// 响应式布局工具类：断点判定 / 自适应值 / 网格列数 / 导航模式。
///
/// 使用方式：
/// ```dart
/// // 方式1：静态方法（基于 MediaQuery）
/// if (Responsive.isTablet(context)) ...
///
/// // 方式2：自适应值解析器
/// final padding = AdaptiveValue.of(context, compact: 8, medium: 16, expanded: 24);
///
/// // 方式3：LayoutBuilder（推荐用于需要感知父容器约束的场景）
/// AdaptiveLayoutBuilder(
///   compact: (ctx) => MobileLayout(),
///   medium: (ctx) => TabletLayout(),
///   expanded: (ctx) => DesktopLayout(),
/// )
/// ```
class Responsive {
  Responsive._();

  // ── 标准断点（Material Design 3） ──────────────────────────────────────

  /// compact 断点（手机）：600dp
  static const double compactBreakpoint = 600;

  /// medium 断点（小平板）：840dp
  static const double mediumBreakpoint = 840;

  /// expanded 断点（平板/笔记本）：1200dp
  static const double expandedBreakpoint = 1200;

  /// large 断点（大桌面 / Chromebook）：1600dp
  static const double largeBreakpoint = 1600;

  /// 平板断点（兼容旧代码）：600dp
  static const double tabletBreakpoint = compactBreakpoint;

  // ── 屏幕尺寸检测 ──────────────────────────────────────────────────────

  /// 当前屏幕宽度（dp）。
  static double widthOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width;

  /// 当前屏幕高度（dp）。
  static double heightOf(BuildContext context) =>
      MediaQuery.sizeOf(context).height;

  /// 当前屏幕尺寸分类。
  static ScreenSize screenSize(BuildContext context) =>
      ScreenSize.fromWidth(widthOf(context));

  /// 是否手机（< 600dp）。
  static bool isCompact(BuildContext context) =>
      widthOf(context) < compactBreakpoint;

  /// 是否小平板（600–840dp）。
  static bool isMedium(BuildContext context) {
    final w = widthOf(context);
    return w >= compactBreakpoint && w < mediumBreakpoint;
  }

  /// 是否平板（≥ 600dp，含 medium + expanded + large）。
  static bool isTablet(BuildContext context) =>
      widthOf(context) >= compactBreakpoint;

  /// 是否大屏平板（≥ 840dp）。
  static bool isExpanded(BuildContext context) =>
      widthOf(context) >= mediumBreakpoint;

  /// 是否桌面级（≥ 1200dp）。
  static bool isLarge(BuildContext context) =>
      widthOf(context) >= expandedBreakpoint;

  // ── 导航模式 ─────────────────────────────────────────────────────────

  /// 推荐的导航模式。
  static NavigationMode navigationMode(BuildContext context) {
    final w = widthOf(context);
    if (w < compactBreakpoint) return NavigationMode.bottomNav;
    if (w < mediumBreakpoint) return NavigationMode.rail;
    if (w < expandedBreakpoint) return NavigationMode.rail;
    return NavigationMode.drawer;
  }

  // ── 自适应值 ─────────────────────────────────────────────────────────

  /// 页面水平 padding。
  static double pagePadding(BuildContext context) {
    final w = widthOf(context);
    if (w >= expandedBreakpoint) return 32;
    if (w >= mediumBreakpoint) return 24;
    if (w >= compactBreakpoint) return 20;
    return 16;
  }

  /// 卡片间距。
  static double gridSpacing(BuildContext context) {
    final w = widthOf(context);
    if (w >= expandedBreakpoint) return 16;
    if (w >= mediumBreakpoint) return 14;
    return 10;
  }

  /// 内容最大宽度（超宽屏限制内容不无限拉伸）。
  ///
  /// 平板横屏（常见 1024~1280dp）内容区本来就没那么宽，限宽意义不大；
  /// 真正需要收口的是桌面/Chromebook 这类 1600dp+ 的窗口。
  static double? maxContentWidth(BuildContext context) {
    final w = widthOf(context);
    if (w >= largeBreakpoint) return 1400; // extra-large
    if (w >= expandedBreakpoint) return 1200; // large
    return null;
  }

  /// 输入框 / 按钮 / 表单类元素在大屏的最大宽度。
  ///
  /// Material 3 大屏质量准则 LS-U2 明确要求：文本框与按钮在大屏上不得占满全宽。
  /// 640dp 取中文阅读舒适行宽（约 30~40 字）与主流搜索框宽度（YouTube ≈600px）的折中。
  /// 窄屏返回无限大，保持撑满。
  static double fieldMaxWidth(BuildContext context) {
    if (widthOf(context) >= mediumBreakpoint) return 640;
    return double.infinity;
  }

  /// 漫画阅读器正文（单页 / 连续滚动）最大宽度。
  ///
  /// 大屏（≥1200dp）收口到 900~1000dp 并居中，避免漫画单页被拉到 2000px 宽。
  /// 竞品 Mihon 的「webtoon / 连续」模式即采用居中限宽；桌面端没有一家默认双页对开。
  static double readerMaxWidth(BuildContext context) {
    final w = widthOf(context);
    if (w >= largeBreakpoint) return 1000;
    if (w >= expandedBreakpoint) return 900;
    return double.infinity;
  }

  /// 小说阅读器正文最大宽度。
  ///
  /// 中文舒适行宽约 30~40 字，折算 640~720dp（微信读书 / 起点桌面版同此量级）。
  /// 超出即居中限宽，避免一行拉到屏幕边缘导致回扫困难。
  static double novelReaderMaxWidth(BuildContext context) {
    final w = widthOf(context);
    if (w >= largeBreakpoint) return 720;
    if (w >= expandedBreakpoint) return 680;
    return double.infinity;
  }

  /// 详情页左侧面板宽度（动态计算，参考竞品 Mihon/Kotatsu）。
  ///
  /// 平板最佳实践：
  /// - expanded (840-1200dp)：左侧 280-300dp，右侧剩余
  /// - large (>1200dp)：左侧 360-400dp，右侧剩余
  ///
  /// 注意：detail_page 的左右分栏断点已统一为 ≥840（mediumBreakpoint），
  /// medium(600-840) 区间走单栏手机布局，不会调用本方法；此处返回仅对
  /// ≥840 生效。缩窄 expanded 区间左栏，避免 840dp 临界时右栏被挤到
  /// 450dp 以下（历史问题：detail 840 分栏右栏约 450dp 偏挤）。
  static double detailLeftWidth(BuildContext context) {
    final w = widthOf(context);
    if (w >= expandedBreakpoint) return 380;
    if (w >= mediumBreakpoint) return 300;
    return (w * 0.42).clamp(240.0, 300.0);
  }

  // ── 网格列数 ─────────────────────────────────────────────────────────

  /// 内容卡片网格列数。
  static int gridColumns(BuildContext context, {double itemWidth = 120}) {
    final w = widthOf(context);
    final usable = w - pagePadding(context) * 2;
    return (usable / itemWidth).floor().clamp(2, 10);
  }

  /// 漫画/番剧卡片网格列数（首页 / 动漫首页 / 书架）。
  ///
  /// 设计目标：大屏不是无脑涨列数把卡片挤小，而是让卡片反而更大更疏，
  /// 与竞品做法一致（Kotatsu 大屏卡片放大到 ~140dp、间距收到 6dp；
  /// Mangayomi 封面固定 2:3 盒子裁剪填充）。
  ///
  /// 主内容区已被 [MaxWidthContainer] 限宽（large 1400 / expanded 1200dp），
  /// 因此 large 段不会无限拉伸列数。
  ///
  /// | 断点       | 宽度        | 列数 | 卡片宽约 |
  /// |------------|-------------|------|----------|
  /// | compact    | <600dp      | 3    | ~112dp   |
  /// | medium     | 600–840dp   | 4    | ~140dp   |
  /// | expanded   | 840–1200dp  | 5    | ~180dp   |
  /// | large      | ≥1200dp     | 6    | ~190dp   |
  static int comicGridColumns(BuildContext context) {
    final w = widthOf(context);
    if (w >= expandedBreakpoint) return 6;
    if (w >= mediumBreakpoint) return 5;
    if (w >= compactBreakpoint) return 4;
    return 3;
  }

  /// 小说卡片网格列数（小说首页 / 书架）。
  ///
  /// 小说封面更窄、文字密度更高，比漫画多 1 列：
  ///
  /// | 断点       | 宽度        | 列数 |
  /// |------------|-------------|------|
  /// | compact    | <600dp      | 3    |
  /// | medium     | 600–840dp   | 4    |
  /// | expanded   | 840–1200dp  | 6    |
  /// | large      | ≥1200dp     | 7    |
  static int novelGridColumns(BuildContext context) {
    final w = widthOf(context);
    if (w >= expandedBreakpoint) return 7;
    if (w >= mediumBreakpoint) return 6;
    if (w >= compactBreakpoint) return 4;
    return 3;
  }

  /// 章节网格列数。
  static int chapterGridColumns(BuildContext context) {
    final w = widthOf(context);
    if (w < compactBreakpoint) return 6;
    if (w < mediumBreakpoint) return 8;
    if (w < expandedBreakpoint) return 10;
    return 14;
  }

  /// 剧集网格列数。
  static int episodeGridColumns(BuildContext context) {
    final w = widthOf(context);
    if (w < compactBreakpoint) return 4;
    if (w < mediumBreakpoint) return 5;
    if (w < expandedBreakpoint) return 6;
    return 8;
  }
}

/// 导航模式枚举。
enum NavigationMode {
  /// 底部导航栏（手机）。
  bottomNav,

  /// 侧边导航栏（平板）。
  rail,

  /// 侧边抽屉/固定侧边栏（桌面）。
  drawer,
}

// ══════════════════════════════════════════════════════════════════════════════
// 自适应值解析器
// ══════════════════════════════════════════════════════════════════════════════

/// 自适应值解析器：根据屏幕尺寸返回不同值。
///
/// 示例：
/// ```dart
/// final padding = AdaptiveValue.of<double>(
///   context,
///   compact: 8,
///   medium: 16,
///   expanded: 24,
///   large: 32,
/// );
///
/// final widget = AdaptiveValue.of<Widget>(
///   context,
///   compact: MobileHeader(),
///   medium: TabletHeader(),
///   expanded: DesktopHeader(),
/// );
/// ```
class AdaptiveValue {
  AdaptiveValue._();

  /// 根据当前屏幕尺寸解析值。
  ///
  /// [compact] 必填，其他可选，未指定时回退到前一个值。
  static T of<T>(
    BuildContext context, {
    required T compact,
    T? medium,
    T? expanded,
    T? large,
  }) {
    final size = Responsive.screenSize(context);
    switch (size) {
      case ScreenSize.large:
        return large ?? expanded ?? medium ?? compact;
      case ScreenSize.expanded:
        return expanded ?? medium ?? compact;
      case ScreenSize.medium:
        return medium ?? compact;
      case ScreenSize.compact:
        return compact;
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 自适应布局组件
// ══════════════════════════════════════════════════════════════════════════════

/// 基于 LayoutBuilder 的自适应布局构建器。
///
/// 推荐用于需要感知父容器约束的场景（如分栏布局）。
///
/// 示例：
/// ```dart
/// AdaptiveLayoutBuilder(
///   compact: (ctx) => MobileLayout(),
///   medium: (ctx) => TabletLayout(),
///   expanded: (ctx) => DesktopLayout(),
/// )
/// ```
class AdaptiveLayoutBuilder extends StatelessWidget {
  final Widget Function(BuildContext context) compact;
  final Widget Function(BuildContext context)? medium;
  final Widget Function(BuildContext context)? expanded;
  final Widget Function(BuildContext context)? large;

  const AdaptiveLayoutBuilder({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
    this.large,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = ScreenSize.fromWidth(constraints.maxWidth);
        switch (size) {
          case ScreenSize.large:
            return (large ?? expanded ?? medium ?? compact)(context);
          case ScreenSize.expanded:
            return (expanded ?? medium ?? compact)(context);
          case ScreenSize.medium:
            return (medium ?? compact)(context);
          case ScreenSize.compact:
            return compact(context);
        }
      },
    );
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

/// 折叠屏检测：感知折叠状态、铰链位置、屏幕分区。
///
/// 在折叠屏设备上（如 Samsung Galaxy Fold、Pixel Fold），
/// 可以根据折叠状态调整布局：
/// - 展开状态：使用分栏布局
/// - 折叠状态：使用单栏布局
///
/// 示例：
/// ```dart
/// FoldDetector(
///   onFoldChanged: (isFolded) {
///     setState(() => _isFolded = isFolded);
///   },
///   builder: (context, isFolded) {
///     return isFolded ? SingleColumnLayout() : DualColumnLayout();
///   },
/// )
/// ```
class FoldDetector extends StatelessWidget {
  final Widget Function(BuildContext context, bool isFolded) builder;
  final VoidCallback? onFoldChanged;

  const FoldDetector({
    super.key,
    required this.builder,
    this.onFoldChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 检测折叠屏：当屏幕宽度 < 600dp 且高度 > 宽度时，可能是折叠状态
        final size = MediaQuery.sizeOf(context);
        final isFolded = size.width < Responsive.compactBreakpoint &&
            size.height > size.width;

        // 通知折叠状态变化
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onFoldChanged?.call();
        });

        return builder(context, isFolded);
      },
    );
  }
}

// DisplayFeatureDetector 已移除：当前 Flutter SDK 无 DisplayFeature/DisplayFeatureType，
// 折叠屏铰链感知待后续升级 SDK 后再实现。

// ════════════════════════════════════════════════════════════════════════════
// 全局设计常量
// ══════════════════════════════════════════════════════════════════════════════

/// 卡片圆角（统一用于书架、动漫、小说等卡片）。
const double kCardRadius = 12;

/// 封面图片圆角（统一用于缩略图/封面）。
const double kCoverRadius = 10;

/// 平板分栏左侧面板宽度（详情页/信息页）。
const double kPanelWidth = 300;

/// 播放器分栏右侧控制面板宽度（需要更大空间容纳控件）。
const double kPlayerPanelWidth = 336;

/// 底部弹窗顶部圆角。
const double kSheetRadius = 24;

/// 底部弹窗拖拽手柄宽度/高度。
const double kHandleWidth = 36;
const double kHandleHeight = 4;

/// 平板/桌面端底部弹窗最大宽度。
const double kSheetMaxWidth = 500;

/// 侧边栏宽度（窄图标栏：图标在上、标签在下的竖排）。
/// 88dp 是"图标+下方短标签"的舒适窄栏宽度，比纯图标 72 厚实，
/// 在 1080 高的平板屏上不至于细高成电线杆。
const double kRailWidth = 88;

/// 侧边栏宽度（展开+标签模式）。收窄到 160：
/// 原 200 在平板上显得过宽且空旷（仅 4 个导航项），160 仍可舒适放下
/// 中文标签与「星漫匣」Logo，视觉更紧凑正常。
// 中文标签（如"动画记录""工具"）在 128dp 内被 ellipsis 截断，
// 放宽到 160dp 可完整展示图标+文字；内容区损失 32dp 在 1024dp+ 平板上可忽略。
const double kRailExpandedWidth = 160;

/// 桌面端宽侧栏（Windows/macOS/Linux）：导航项为「图标+文字」横排行，
/// 顶部为完整 Logo 字标，与 VS Code / Discord 桌面端侧栏同构。
const double kRailDesktopWidth = 208;

/// 键盘快捷键映射（Ctrl/Cmd + 数字键切换标签页）。
final Map<LogicalKeyboardKey, int> kTabShortcuts = {
  LogicalKeyboardKey.digit1: 0,
  LogicalKeyboardKey.digit2: 1,
  LogicalKeyboardKey.digit3: 2,
  LogicalKeyboardKey.digit4: 3,
};

// ══════════════════════════════════════════════════════════════════════════════
// 响应式底部弹窗
// ══════════════════════════════════════════════════════════════════════════════

/// 显示响应式底部弹窗：平板端限制最大宽度（居中于底部），手机端全宽；
/// 桌面端（Windows/macOS/Linux）改为**居中对话框**——桌面没有"从底部滑出"
/// 的交互心智，底部弹层是移动端形态（鼠标用户需长距离移动、Sheet 拖拽
/// 手柄在桌面也无意义），业界桌面应用一律用居中模态对话框。
Future<T?> showResponsiveBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  Color? backgroundColor,
  Color? barrierColor,
  ShapeBorder? shape,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  if (DesktopUi.isDesktopPlatform) {
    return showDialog<T>(
      context: context,
      barrierDismissible: isDismissible,
      builder: (ctx) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kSheetMaxWidth),
          child: SingleChildScrollView(
            child: Material(
              color: backgroundColor ?? Theme.of(ctx).colorScheme.surface,
              borderRadius: BorderRadius.circular(kSheetRadius),
              clipBehavior: Clip.antiAlias,
              child: builder(ctx),
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    barrierColor: barrierColor,
    shape: shape,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    constraints: Responsive.isTablet(context)
        ? const BoxConstraints(maxWidth: kSheetMaxWidth)
        : null,
    builder: builder,
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// 桌面端规范（Fluent / WinUI 3 惯例）
// ══════════════════════════════════════════════════════════════════════════════

/// 桌面滚动物理：Windows 桌面用 clamping（无橡皮筋回弹），
/// 移动端保持 bouncing。所有页面经 [desktopPhysics] 统一取值。
const ScrollPhysics kDesktopScrollPhysics = ClampingScrollPhysics();

/// 桌面页头（Fluent PageHeader 惯例）：
/// 左侧 28px 大标题（可选副标题），右侧命令栏按钮组。
/// 页面不再用 21px 小标题挤在第一行——大标题是桌面应用的页面身份标识。
class DesktopPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  const DesktopPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(32, 18, 32, 12),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    height: 1.2,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: 8),
            ...actions,
          ],
        ],
      ),
    );
  }
}

/// 右键上下文菜单项。
class CtxMenuItem {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool destructive;
  const CtxMenuItem({
    required this.label,
    this.icon,
    this.onTap,
    this.destructive = false,
  });

  const CtxMenuItem.separator()
      : label = '',
        icon = null,
        onTap = null,
        destructive = false;
}

/// 在鼠标位置弹出桌面右键上下文菜单（Fluent ContextMenu 惯例）。
/// [globalPosition] 传 onSecondaryTapDown 的 globalPosition 即可。
Future<void> showContextMenu(
  BuildContext context,
  Offset globalPosition, {
  required List<CtxMenuItem> items,
}) {
  final scheme = Theme.of(context).colorScheme;
  final menuItems = <PopupMenuEntry<String>>[];
  var index = 0;
  for (final it in items) {
    if (it.label.isEmpty) {
      menuItems.add(const PopupMenuDivider());
      continue;
    }
    final key = 'item_${index++}';
    menuItems.add(
      PopupMenuItem<String>(
        value: key,
        height: 38,
        child: Row(
          children: [
            if (it.icon != null) ...[
              Icon(it.icon,
                  size: 16,
                  color: it.destructive
                      ? scheme.error
                      : scheme.onSurface.withValues(alpha: 0.65)),
              const SizedBox(width: 10),
            ],
            Text(
              it.label,
              style: TextStyle(
                fontSize: 13,
                color: it.destructive ? scheme.error : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
  // 记录每个可选项对应的回调（跳过 separator）
  final callbacks = <String, VoidCallback?>{
    for (var i = 0, k = 0; i < items.length; i++)
      if (items[i].label.isNotEmpty)
        'item_${k++}': items[i].onTap,
  };
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
        globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy),
    color: scheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: scheme.outlineVariant, width: 1),
    ),
    elevation: 8,
    items: menuItems,
  ).then<void>((value) {
    if (value != null) callbacks[value]?.call();
  });
}

/// 右键菜单包装器：给任意子组件加桌面右键上下文菜单。
class ContextMenuWrapper extends StatelessWidget {
  final Widget child;
  final List<CtxMenuItem> Function() items;
  const ContextMenuWrapper({
    super.key,
    required this.child,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    if (!DesktopUi.isDesktopPlatform) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) =>
          showContextMenu(context, d.globalPosition, items: items()),
      onSecondaryTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final center = box.localToGlobal(box.size.center(Offset.zero));
          showContextMenu(context, center, items: items());
        }
      },
      child: child,
    );
  }
}

/// 桌面端悬停效果包装器：鼠标悬停时添加微妙的视觉反馈。
class HoverEffect extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final double opacity;
  final Duration duration;

  const HoverEffect({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 1.02,
    this.opacity = 0.9,
    this.duration = const Duration(milliseconds: 200),
  });

  @override
  State<HoverEffect> createState() => _HoverEffectState();
}

class _HoverEffectState extends State<HoverEffect> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: widget.duration,
          curve: Curves.easeOutCubic,
          transform: _isHovered
              ? (Matrix4.identity()..scaleByDouble(widget.scale, widget.scale, widget.scale, 1.0))
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          child: AnimatedOpacity(
            opacity: _isHovered ? widget.opacity : 1.0,
            duration: widget.duration,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 桌面端工具提示包装器：鼠标悬停时显示提示信息。
class TooltipWrapper extends StatelessWidget {
  final Widget child;
  final String message;

  const TooltipWrapper({
    super.key,
    required this.child,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    if (!Responsive.isLarge(context)) return child;
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 500),
      child: child,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 共享 UI 组件
// ══════════════════════════════════════════════════════════════════════════════

/// 漫画 / 动漫 / 小说 分段切换（黑底胶囊，统一用于首页顶部 segment）。
class TypeSegment extends StatelessWidget {
  final int type;
  final ValueChanged<int>? onChanged;
  final List<String> labels;

  const TypeSegment({
    super.key,
    required this.type,
    this.onChanged,
    this.labels = const ['漫画', '动漫', '小说'],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = AdaptiveValue.of<double>(context, compact: 40, medium: 44);
    final hPad = AdaptiveValue.of<double>(context, compact: 12, medium: 14);
    final fontSize =
        AdaptiveValue.of<double>(context, compact: 12, medium: 13);

    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++)
            _seg(context, labels[i], i, hPad, fontSize),
        ],
      ),
    );
  }

  Widget _seg(
      BuildContext context, String label, int v, double hPad, double fontSize) {
    final scheme = Theme.of(context).colorScheme;
    final active = type == v;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 6),
        decoration: BoxDecoration(
          color: active ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active
                ? scheme.onPrimary
                : scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

/// 底部弹窗顶部拖拽手柄（统一用于所有 BottomSheet）。
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: kHandleWidth,
        height: kHandleHeight,
        margin: const EdgeInsets.only(top: 12, bottom: 8),
        decoration: BoxDecoration(
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 统一空状态视图（图标 + 标题 + 可选副标题）。
class EmptyStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  const EmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconSize = AdaptiveValue.of<double>(context, compact: 72, medium: 96);
    final iconInner =
        AdaptiveValue.of<double>(context, compact: 36, medium: 48);
    final titleSize =
        AdaptiveValue.of<double>(context, compact: 14, medium: 16);
    final subSize = AdaptiveValue.of<double>(context, compact: 12, medium: 14);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.08),
            ),
            child: Icon(icon, size: iconInner, color: scheme.primary),
          ),
          SizedBox(height: AdaptiveValue.of<double>(context, compact: 14, medium: 18)),
          Text(title,
              style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withValues(alpha: 0.7))),
          if (subtitle != null) ...[
            SizedBox(height: AdaptiveValue.of<double>(context, compact: 6, medium: 8)),
            Text(subtitle!,
                style: TextStyle(
                    fontSize: subSize,
                    color: scheme.onSurface.withValues(alpha: 0.45))),
          ],
        ],
      ),
    );
  }
}

/// 统一分区标题：小圆角图标块 + 标题 + 可选计数徽章 + 可选尾部操作。
///
/// 取代各页面零散的「蓝色竖线 + 标题」内联写法，保证多端视觉一致：
/// - 手机/平板/桌面字号与图标块尺寸阶梯化；
/// - 强调色只出现在图标块与计数徽章，不再用整条色带。
class SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final int? count;
  final Widget? trailing;
  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.count,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final block = AdaptiveValue.of<double>(context, compact: 26, medium: 30);
    final iconSize = AdaptiveValue.of<double>(context, compact: 15, medium: 17);
    final titleSize =
        AdaptiveValue.of<double>(context, compact: 15, medium: 16.5);

    return Row(
      children: [
        Container(
          width: block,
          height: block,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(block / 3),
            border: Border.all(color: scheme.outline, width: 1),
          ),
          child: Icon(icon,
              size: iconSize,
              color: scheme.onSurface.withValues(alpha: 0.72)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              color: scheme.onSurface,
            ),
          ),
        ),
        if (count != null && count! > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scheme.outline, width: 1),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
        ],
        if (trailing != null) ...[
          const Spacer(),
          trailing!,
        ],
      ],
    );
  }
}

/// 统一错误视图（图标 + 标题 + 重试按钮）。
class ErrorStateView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorStateView({super.key, required this.message, this.onRetry});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconSize = AdaptiveValue.of<double>(context, compact: 72, medium: 96);
    final iconInner =
        AdaptiveValue.of<double>(context, compact: 36, medium: 48);
    final msgSize =
        AdaptiveValue.of<double>(context, compact: 14, medium: 16);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.error.withValues(alpha: 0.08),
            ),
            child: Icon(Icons.error_outline_rounded,
                size: iconInner, color: scheme.error),
          ),
          SizedBox(height: AdaptiveValue.of<double>(context, compact: 14, medium: 18)),
          Text(message,
              style: TextStyle(
                  fontSize: msgSize,
                  color: scheme.onSurface.withValues(alpha: 0.6))),
          if (onRetry != null) ...[
            SizedBox(height: AdaptiveValue.of<double>(context, compact: 14, medium: 18)),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }
}

