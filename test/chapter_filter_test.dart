import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/ui/detail_page.dart';
import 'package:xingmanxia/ui/widgets/chapter_list_sheet.dart';

/// 回归：第28轮 全部章节 sheet 章节搜索过滤 + 倒序（纯函数覆盖）。
///
/// 覆盖 [filterChapters] 与 [titleOfChapter]：
/// - 空过滤 = 原序原样；
/// - 标题模糊匹配（大小写不敏感）；
/// - 空标题按「第N话」占位参与匹配；
/// - 倒序 + 过滤组合；
/// - 无匹配返回空列表。
void main() {
  final chapters = [
    Chapter('c1', '第1话 初识'),
    Chapter('c2', '第2话 重逢'),
    Chapter('c3', ''),
    Chapter('c4', '第4话 决战'),
  ];

  test('空过滤：原序原样返回', () {
    final r = filterChapters(chapters, '');
    expect(r, same(chapters));
  });

  test('标题模糊匹配：命中关键词', () {
    final r = filterChapters(chapters, '重逢');
    expect(r.map((c) => c.id), ['c2']);
  });

  test('标题模糊匹配：大小写不敏感', () {
    final r = filterChapters(chapters, '第2话');
    expect(r.map((c) => c.id), ['c2']);
  });

  test('空标题按话数占位参与匹配', () {
    final r = filterChapters(chapters, '第3话');
    expect(r.map((c) => c.id), ['c3']);
  });

  test('无匹配：返回空列表', () {
    final r = filterChapters(chapters, '不存在的章节');
    expect(r, isEmpty);
  });

  test('倒序 + 过滤组合', () {
    final r = filterChapters(chapters, '第',
        descending: true);
    // 倒序后：第4/空/第2/第1，空标题按「第3话」占位也命中「第」。
    expect(r.map((c) => c.id), ['c4', 'c3', 'c2', 'c1']);
  });

  test('titleOfChapter：空标题给话数占位，非空标题原样', () {
    expect(chapterFilterTitle(chapters, chapters[2], 2), '第3话');
    expect(chapterFilterTitle(chapters, chapters[0], 0), '第1话 初识');
  });
}
