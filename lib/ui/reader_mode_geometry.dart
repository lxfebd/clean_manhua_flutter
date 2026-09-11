/// 阅读器双页几何换算（纯函数，无 Flutter/状态依赖，可独立单测）。
///
/// 「视图」= PageView 的一屏；双页模式下默认一屏左右两页。
/// 封面单独占页（≥3 页）：第 0 页（卷首彩页/封面）独占 view 0，
/// 从页 1 起两两并排；末视图允许单页（总数奇数时多出一页）。
///
/// 单页/纵向模式下视图数=页数（一页一屏），三种换算退化为恒等。
library;

/// 双页模式下“视图”= 一屏左右两页。单页/纵向视图数=页数。
int viewCountOf(int pageCount, ReaderMode mode) {
  if (mode != ReaderMode.double) return pageCount;
  if (pageCount < 3) return (pageCount / 2).ceil();
  return 1 + ((pageCount - 1) / 2).ceil();
}

/// 视图 -> 起始页（双页模式下左页索引；右页为 +1）。
/// 封面单独占页时：view 0 → 页 0；view>0 → 从页 1 起两两并排。
int pageOfView(int view, ReaderMode mode) {
  if (mode != ReaderMode.double) return view;
  if (view <= 0) return 0;
  return 1 + (view - 1) * 2;
}

/// 页 -> 所在视图（双页模式下两页共一个视图）。
/// 封面单独占页时：页 0 → view 0；页>0 → 从页 1 起映射。
int viewOfPage(int page, ReaderMode mode) {
  if (mode != ReaderMode.double) return page;
  if (page <= 0) return 0;
  return 1 + (page - 1) ~/ 2;
}

/// 阅读模式：纵向滚动 / 单页横向 / 双页并排（平板横屏）。
enum ReaderMode {
  vertical(0),
  single(1),
  double(2);

  const ReaderMode(this.value);
  final int value;

  static ReaderMode fromValue(int v) => switch (v) {
        0 => ReaderMode.vertical,
        2 => ReaderMode.double,
        _ => ReaderMode.single,
      };
}
