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

  group('章节边界判定（canContinueChapter/hasPrevChapter）', () {
    test('canContinue：首章可连读，末章不可', () {
      expect(canContinueChapter(0, 5), isTrue, reason: '首章有下一话');
      expect(canContinueChapter(3, 5), isTrue, reason: '中间章有下一话');
      expect(canContinueChapter(4, 5), isFalse, reason: '末章没有下一话');
    });

    test('canContinue：单章/无章/索引越界全部不可连读', () {
      expect(canContinueChapter(0, 1), isFalse, reason: '单章节不可连读');
      expect(canContinueChapter(0, 0), isFalse, reason: '无章节不可连读');
      expect(canContinueChapter(-1, 5), isFalse, reason: '未定位（-1）不可');
      expect(canContinueChapter(5, 5), isFalse, reason: '越界不可');
    });

    test('hasPrev：首章无上一话，后续章有', () {
      expect(hasPrevChapter(0), isFalse, reason: '首章无上一话');
      expect(hasPrevChapter(1), isTrue);
      expect(hasPrevChapter(4), isTrue);
      expect(hasPrevChapter(-1), isFalse);
    });
  });
}
