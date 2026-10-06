import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/detail_providers.dart';

HistoryEntry _mkHistory(String sourceId, String comicId, String chapterId) {
  return HistoryEntry(
    book: Bookmark(
      sourceId: sourceId,
      comicId: comicId,
      name: '测试书',
      pic: '',
    ),
    chapterId: chapterId,
    chapterTitle: '第 $chapterId 话',
    timestamp: 1,
  );
}

void main() {
  group('readChapterIds', () {
    test('空历史返回空集', () {
      expect(
        readChapterIds(
          history: const [],
          sourceId: 's',
          comicId: 'c',
        ),
        isEmpty,
      );
    });

    test('筛出指定作品的已读章节', () {
      final set = readChapterIds(
        history: [
          _mkHistory('s', 'c', 'ch1'),
          _mkHistory('s', 'c', 'ch2'),
          _mkHistory('other', 'c', 'chX'),
        ],
        sourceId: 's',
        comicId: 'c',
      );
      expect(set, {'ch1', 'ch2'});
    });

    test('同一章节多次记录去重', () {
      final set = readChapterIds(
        history: [
          _mkHistory('s', 'c', 'ch1'),
          _mkHistory('s', 'c', 'ch1'),
          _mkHistory('s', 'c', 'ch3'),
        ],
        sourceId: 's',
        comicId: 'c',
      );
      expect(set, {'ch1', 'ch3'});
    });

    test('同作品不同 comicId 不混淆', () {
      final set = readChapterIds(
        history: [
          _mkHistory('s', 'c1', 'ch1'),
          _mkHistory('s', 'c2', 'ch2'),
        ],
        sourceId: 's',
        comicId: 'c1',
      );
      expect(set, {'ch1'});
    });
  });
}
