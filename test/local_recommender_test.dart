import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/utils/local_recommender.dart';

void main() {
  group('LocalRecommender 纯规则聚合', () {
    test('同作品只计一次（按 sourceId::comicId 去重）', () {
      final h = [
        HistoryEntry(
          book: Bookmark(sourceId: 'a', comicId: '1', name: 'A', author: '作者X', pic: ''),
          chapterId: 'c1',
          chapterTitle: '第1话',
          timestamp: 1,
        ),
        HistoryEntry(
          book: Bookmark(sourceId: 'a', comicId: '1', name: 'A', author: '作者X', pic: ''),
          chapterId: 'c2',
          chapterTitle: '第2话',
          timestamp: 2,
        ),
      ];
      final counts = LocalRecommender.authorCounts(h);
      expect(counts, {'作者X': 1});
    });

    test('无作者的历史不产生计数', () {
      final h = [
        HistoryEntry(
          book: Bookmark(sourceId: 'a', comicId: '1', name: 'A', author: '', pic: ''),
          chapterId: 'c1',
          chapterTitle: 'x',
          timestamp: 1,
        ),
      ];
      expect(LocalRecommender.authorCounts(h), isEmpty);
    });

    test('不同作者各自计数，空作者跳过', () {
      final h = [
        HistoryEntry(
          book: Bookmark(sourceId: 'a', comicId: '1', name: 'A', author: ' 作者X ', pic: ''),
          chapterId: 'c1',
          chapterTitle: 'x',
          timestamp: 1,
        ),
        HistoryEntry(
          book: Bookmark(sourceId: 'a', comicId: '2', name: 'B', author: '作者Y', pic: ''),
          chapterId: 'c1',
          chapterTitle: 'x',
          timestamp: 2,
        ),
        HistoryEntry(
          book: Bookmark(sourceId: 'a', comicId: '3', name: 'C', author: '', pic: ''),
          chapterId: 'c1',
          chapterTitle: 'x',
          timestamp: 3,
        ),
      ];
      final counts = LocalRecommender.authorCounts(h);
      expect(counts, {'作者X': 1, '作者Y': 1});
    });
  });
}