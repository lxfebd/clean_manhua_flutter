import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/bookshelf_page.dart';

void main() {
  group('resumeTextOf（网格书架卡续读副标题）', () {
    HistoryEntry entry({
      required String comicId,
      String chapterTitle = '第3话 决战',
      int pageIndex = 4,
      int timestamp = 0,
    }) =>
        HistoryEntry(
          book: Bookmark(
            sourceId: 's1',
            comicId: comicId,
            name: comicId,
            pic: '',
            author: '',
          ),
          chapterId: 'c-$comicId',
          chapterTitle: chapterTitle,
          timestamp: timestamp,
          pageIndex: pageIndex,
          chapterTotalPages: 20,
          scrollOffset: 0,
        );

    test('有页码：续读 章节名 · 第N页（pageIndex 是 0-based）', () {
      final recent = [entry(comicId: 'a', chapterTitle: '第3话 决战', pageIndex: 4)];
      expect(resumeTextOf('s1/a', recent), '续读 第3话 决战 · 第5页');
    });

    test('pageIndex=0：显示 第1页', () {
      final recent = [entry(comicId: 'a', pageIndex: 0)];
      expect(resumeTextOf('s1/a', recent), '续读 第3话 决战 · 第1页');
    });

    test('pageIndex=-1（无页码）：只显示章节名', () {
      final recent = [entry(comicId: 'a', pageIndex: -1)];
      expect(resumeTextOf('s1/a', recent), '续读 第3话 决战');
    });

    test('章节名为空：显示 已读', () {
      // 章节名为空 = 停在目录/顶部，通常也无页码（pageIndex=-1）。
      final recent = [entry(comicId: 'a', chapterTitle: '', pageIndex: -1)];
      expect(resumeTextOf('s1/a', recent), '已读');
    });

    test('按 key 精确匹配：不同 comicId 不命中', () {
      final recent = [entry(comicId: 'a')];
      expect(resumeTextOf('s1/b', recent), '');
    });

    test('同 sourceId 不同 comicId 不命中（key 含 sourceId）', () {
      final recent = [entry(comicId: 'a')];
      expect(resumeTextOf('s2/a', recent), '');
    });

    test('多历史取最近一条（recent 已按时间倒序）', () {
      final recent = [
        entry(comicId: 'a', chapterTitle: '第9话 终章', pageIndex: 2, timestamp: 200),
        entry(comicId: 'a', chapterTitle: '第3话 决战', pageIndex: 4, timestamp: 100),
      ];
      expect(resumeTextOf('s1/a', recent), '续读 第9话 终章 · 第3页');
    });

    test('空历史返回空串', () {
      expect(resumeTextOf('s1/a', const []), '');
    });
  });
}
