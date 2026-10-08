import 'package:flutter/material.dart';

/// 首页吸顶折叠头部的通用 [SliverPersistentHeaderDelegate]。
///
/// home_page 与 anime_home_page 各有一份逐字同构的私有 delegate
/// （仅类名不同），收起为这一份：min/max 高度 + 内容 builder 参数化，
/// 无状态，页面各自传入折叠逻辑。
class HomeHeaderDelegate extends SliverPersistentHeaderDelegate {
  const HomeHeaderDelegate({
    required double minExtent,
    required double maxExtent,
    required this.builder,
  })  : _minExtent = minExtent,
        _maxExtent = maxExtent;

  final double _minExtent;
  final double _maxExtent;

  /// (context, shrinkOffset, overlapsContent) → 当前头部视图。
  final Widget Function(BuildContext, double, bool) builder;

  @override
  double get minExtent => _minExtent;

  @override
  double get maxExtent => _maxExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return builder(context, shrinkOffset, overlapsContent);
  }

  @override
  bool shouldRebuild(covariant HomeHeaderDelegate oldDelegate) {
    return oldDelegate._minExtent != _minExtent ||
        oldDelegate._maxExtent != _maxExtent ||
        oldDelegate.builder != builder;
  }
}