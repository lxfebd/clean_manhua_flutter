import 'package:flutter/material.dart';

/// 最小可点击区（44×44）。
///
/// 8-31 审计 `tools/layout_metrics_test.dart` 实测：首页 390dp 宽度下
/// **22/22 个可点击控件短边不足 44dp**，全应用无一达标（仅"我的"页平板
/// 分支合格）。所有小的图标按钮、胶囊、行内操作都应包一层本控件，
/// 由它保证命中区，而不是靠放大图标视觉尺寸凑数。
///
/// 用法：把 [TapTargetMin] 包在最外层（InkWell/GestureDetector 之外），
/// 这样水波反馈与命中区一致。
class TapTargetMin extends StatelessWidget {
  const TapTargetMin({
    super.key,
    required this.child,
    this.width = 44,
    this.height = 44,
    this.alignment = Alignment.center,
  });

  final Widget child;

  /// 最小宽度（dp）。图标密集的工具条可传 40。
  final double width;

  /// 最小高度（dp）。
  final double height;

  /// 内容在命中区内的对齐方式。
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: width, minHeight: height),
        child: Align(alignment: alignment, child: child),
      );
}
