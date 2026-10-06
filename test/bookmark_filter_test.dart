import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/bookshelf_page.dart';

/// filterBookmarks 纯函数测试：书名/章节标题匹配、空过滤原样返回。
ComicBookmark _mk(String bookName, String chapterTitle) => ComicBookmark(
      book: Bookmark(
        sourceId: 's1',
        comicId: 'c-${bookName.hashCode.abs()}',
        name: bookName,
        pic: '',
      ),
      chapterId: 'ch',
      chapterTitle: chapterTitle,
      pageIndex: 0,
      timestamp: 0,
    );

void main() {
  test('空过滤原样返回（不拷贝）', () {
    final list = [_mk('海贼王', '第1话 起航')];
    expect(identical(filterBookmarks(list, ''), list), isTrue);
    expect(identical(filterBookmarks(list, '   '), list), isTrue);
  });

  test('按书名匹配（子串，忽略大小写）', () {
    final list = [
      _mk('海贼王', '第1话'),
      _mk('火影忍者', '第2话'),
    ];
    final out = filterBookmarks(list, '海贼');
    expect(out.map((b) => b.book.name), ['海贼王']);
  });

  test('按章节标题匹配', () {
    final list = [
      _mk('海贼王', '第1话 起航'),
      _mk('火影忍者', '第2话 修炼'),
    ];
    final out = filterBookmarks(list, '修炼');
    expect(out.map((b) => b.book.name), ['火影忍者']);
  });

  test('书名/章节任一命中即保留', () {
    final list = [
      _mk('海贼王', '第1话 起航'),
      _mk('火影忍者', '第2话 修炼'),
      _mk('死神', '第3话 斩魄刀'),
    ];
    final out = filterBookmarks(list, '起航');
    expect(out.map((b) => b.book.name), ['海贼王']);
    final out2 = filterBookmarks(list, '海贼');
    expect(out2.map((b) => b.book.name), ['海贼王']);
  });

  test('trim 后匹配，大小写不敏感', () {
    final list = [
      _mk('ONE PIECE', 'Chapter 1'),
      _mk('火影忍者', '第2话'),
    ];
    expect(filterBookmarks(list, '  piece ').length, 1);
    expect(filterBookmarks(list, 'CHAPTER 1').length, 1);
  });

  test('无命中返回空列表', () {
    final list = [_mk('海贼王', '第1话')];
    expect(filterBookmarks(list, '不存在的名字'), isEmpty);
  });
}
