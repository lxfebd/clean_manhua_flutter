import 'package:flutter/widgets.dart';

/// UI 风格维度 —— 与「明暗」「种子色」并列的第三根主题轴。
///
/// - [minimalist]：极简单色（项目原设计，零彩色/零阴影/克制圆角）。
/// - [xiaomi]：小米 HyperOS —— 超椭圆大圆角、高饱和渐变卡片、回弹动效。
/// - [apple]：苹果 iOS —— 系统蓝、毛玻璃头/浮层、inset grouped 分组列表、平滑动效。
///
/// 默认「跟随平台」：Android/小米设备 → [xiaomi]，iOS → [apple]，
/// 桌面与 Web → [minimalist]（桌面回归面最小，且无强平台规范）。
/// 用户可在设置页手动覆盖为任意一种，覆盖值持久化到 [LocalStore.uiStyle]。
enum UIStyle {
  minimalist,
  xiaomi,
  apple;

  /// 稳定标识符（持久化用）：与枚举名一致，含字母数字下划线。
  String get id => name;

  /// 展示名（设置页选择器用）。
  String get label => switch (this) {
        UIStyle.minimalist => '极简',
        UIStyle.xiaomi => '小米',
        UIStyle.apple => '苹果',
      };

  /// 解析持久化值；无效/空输入回退 [minimalist]（旧用户无该字段时的默认）。
  static UIStyle fromId(String? id) => UIStyle.values.firstWhere(
        (s) => s.id == id,
        orElse: () => UIStyle.minimalist,
      );

  /// 平台默认映射（跟随平台时使用）。
  static UIStyle forPlatform(TargetPlatform platform) => switch (platform) {
        TargetPlatform.android => UIStyle.xiaomi,
        TargetPlatform.iOS => UIStyle.apple,
        // 桌面与 Web 无强平台规范 → 保留项目原极简风格（回归面最小）。
        _ => UIStyle.minimalist,
      };
}

/// 全局 UI 风格作用域（InheritedWidget）。
///
/// 挂在 MaterialApp 外层（与 [AnimatedTheme] 同级），整棵 Widget 树都能通过
/// `context.uiStyle` 读到当前风格。测试可用 [StyleScope.demo] 固定风格，避免
/// 依赖真实平台（`debugDefaultTargetPlatformOverride` 的 widget 测试仍会受
/// [Theme] 影响，而 UIStyle 走这里独立控制）。
class StyleScope extends InheritedWidget {
  const StyleScope({
    super.key,
    required this.style,
    required super.child,
  });

  /// 当前生效风格（已解析「跟随平台」后的最终值）。
  final UIStyle style;

  /// 测试用固定风格构造。
  const StyleScope.demo({
    super.key,
    this.style = UIStyle.minimalist,
    required super.child,
  });

  static StyleScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StyleScope>();

  static UIStyle of(BuildContext context) =>
      maybeOf(context)?.style ?? UIStyle.minimalist;

  @override
  bool updateShouldNotify(StyleScope oldWidget) => oldWidget.style != style;
}

/// [BuildContext] 便捷读取：`context.uiStyle`。
extension UIStyleContext on BuildContext {
  UIStyle get uiStyle => StyleScope.of(this);
}