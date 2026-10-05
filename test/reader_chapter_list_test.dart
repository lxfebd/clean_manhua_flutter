import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/ui/reader_page.dart';

/// 回归：第30轮 阅读器章节列表搜索（纯函数覆盖标题占位）。
void main() {
  test('chapterFilterTitle：空标题按话数占位，非空原样', () {
    final c0 = Chapter('c1', '');
    final c1 = Chapter('c2', '第2话 重逢');
    expect(chapterFilterTitle([c0, c1], c0, 0), '第1话');
    expect(chapterFilterTitle([c0, c1], c1, 1), '第2话 重逢');
  });
}
