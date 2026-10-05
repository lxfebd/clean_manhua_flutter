import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/profile_page.dart';

void main() {
  group('filterHistoryEntries', () {
    HistoryEntry entry(String name, String chapter) => HistoryEntry(
          book: Bookmark(
            sourceId: 's1',
            comicId: name,
            name: name,
            pic: '',
            author: '',
          ),
          chapterId: 'c',
          chapterTitle: chapter,
          timestamp: 0,
          scrollOffset: 0,
        );

    List<HistoryEntry> entries() => [
          entry('海贼王', '第100话 决战'),
          entry('火影忍者', '第50话 修行'),
          entry('三体', '第1章 科学边界'),
        ];

    test('空过滤返回原列表（同一引用）', () {
      final list = entries();
      expect(filterHistoryEntries(list, ''), same(list));
    });

    test('按书名模糊匹配', () {
      final out = filterHistoryEntries(entries(), '火影');
      expect(out.length, 1);
      expect(out.first.book.name, '火影忍者');
    });

    test('按章节标题匹配', () {
      final out = filterHistoryEntries(entries(), '决战');
      expect(out.length, 1);
      expect(out.first.book.name, '海贼王');
    });

    test('大小写不敏感', () {
      final list = [
        entry('One Piece', '第1话'),
        entry('海贼王', '第100话'),
      ];
      expect(filterHistoryEntries(list, 'one piece').length, 1);
      expect(filterHistoryEntries(list, 'ONE').length, 1);
    });

    test('无匹配返回空列表', () {
      expect(filterHistoryEntries(entries(), '不存在的书'), isEmpty);
    });

    test('空白过滤词视同空', () {
      final list = entries();
      expect(filterHistoryEntries(list, '   '), same(list));
    });
  });
}
