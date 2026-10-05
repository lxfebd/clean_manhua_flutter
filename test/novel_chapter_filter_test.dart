import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/novel_source.dart';
import 'package:xingmanxia/ui/novel_detail_page.dart';

/// 回归：第29轮 小说详情页章节目录搜索过滤（纯函数覆盖）。
void main() {
  final chapters = [
    NovelChapter('n1', '第一章 初识'),
    NovelChapter('n2', '第二章 重逢'),
    NovelChapter('n3', '第三章 试炼'),
  ];

  test('空过滤：原列表原样', () {
    expect(filterNovelChapters(chapters, ''), same(chapters));
  });

  test('标题模糊匹配', () {
    final r = filterNovelChapters(chapters, '重逢');
    expect(r.map((c) => c.id), ['n2']);
  });

  test('大小写不敏感', () {
    final r = filterNovelChapters(chapters, '第');
    expect(r.map((c) => c.id), ['n1', 'n2', 'n3']);
  });

  test('无匹配：空列表', () {
    expect(filterNovelChapters(chapters, '不存在'), isEmpty);
  });
}
