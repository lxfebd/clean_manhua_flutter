import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/ui/detail_batch_download_sheet.dart';

/// 回归：批量下载选章弹窗章节搜索过滤（纯函数覆盖）。
///
/// 覆盖 [filterBatchDownloadIndexes]：
/// - 空过滤 = 原索引列表原样；
/// - 标题模糊匹配（大小写不敏感）；
/// - 空标题按「第N话」占位参与匹配；
/// - 过滤只作用于传入的候选索引（未下载章节）；
/// - 无匹配返回空列表；
/// - 空白视为空。
void main() {
  final chapters = [
    Chapter('c1', '第1话 初识'),
    Chapter('c2', '第2话 重逢'),
    Chapter('c3', ''),
    Chapter('c4', '第4话 决战'),
  ];
  final all = [0, 1, 2, 3];
  // 模拟已下载 c1/c3：候选索引只剩 1/3
  final candidates = [1, 3];

  test('空过滤：原索引列表原样返回', () {
    final r = filterBatchDownloadIndexes(chapters, all, '');
    expect(r, same(all));
  });

  test('标题模糊匹配：命中关键词', () {
    final r = filterBatchDownloadIndexes(chapters, all, '重逢');
    expect(r, [1]);
  });

  test('标题模糊匹配：大小写不敏感', () {
    final r = filterBatchDownloadIndexes(chapters, all, '第2话');
    expect(r, [1]);
  });

  test('空标题按话数占位参与匹配', () {
    final r = filterBatchDownloadIndexes(chapters, all, '第3话');
    expect(r, [2]);
  });

  test('过滤只作用于传入的候选索引', () {
    final r = filterBatchDownloadIndexes(chapters, candidates, '第');
    // 候选 1/3：第2话、第4话都命中「第」；已下载的 c1/c3 不在候选。
    expect(r, [1, 3]);
  });

  test('无匹配：返回空列表', () {
    final r = filterBatchDownloadIndexes(chapters, all, '不存在的章节');
    expect(r, isEmpty);
  });

  test('空白视为空过滤', () {
    final r = filterBatchDownloadIndexes(chapters, all, '   ');
    expect(r, same(all));
  });

  _invertTests();
}

/// 反选 [invertSelection]：翻转 targets 内索引选中态，其余不变。
void _invertTests() {
  test('反选翻转目标内选中态', () {
    expect(invertSelection({1, 3}, [1, 2, 3]), {2});
  });

  test('反选保留目标外选中态', () {
    expect(invertSelection({0, 5}, [1, 2, 3]), {0, 5, 1, 2, 3});
  });

  test('反选空目标 = 原集合', () {
    final sel = {1, 2};
    expect(invertSelection(sel, const []), {1, 2});
  });

  test('反选两次幂等', () {
    final s = {1, 3};
    final once = invertSelection(s, [1, 2, 3, 4]);
    expect(invertSelection(once, [1, 2, 3, 4]), s);
  });

  test('反选不修改原集合', () {
    final s = {1, 3};
    invertSelection(s, [1, 2, 3]);
    expect(s, {1, 3});
  });
}
