import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/bookshelf_page.dart';

VideoRecord _mkRecord(String title, {int episode = 1}) {
  return VideoRecord(
    sourceId: 's',
    videoId: 'v$episode',
    title: title,
    season: 1,
    episode: episode,
    timestamp: 0,
  );
}

HistoryEntry _mkHistory(String bookName, String chapterTitle) {
  return HistoryEntry(
    book: Bookmark(
      sourceId: 's',
      comicId: 'c${bookName.hashCode}',
      name: bookName,
      pic: '',
    ),
    chapterId: 'ch',
    chapterTitle: chapterTitle,
    timestamp: 0,
  );
}

void main() {
  group('filterVideoRecords', () {
    test('空过滤原样返回', () {
      final all = [_mkRecord('海贼王'), _mkRecord('火影忍者')];
      expect(filterVideoRecords(all, ''), same(all));
      expect(filterVideoRecords(all, '   '), same(all));
    });

    test('按片名模糊匹配', () {
      final all = [_mkRecord('海贼王'), _mkRecord('海贼王剧场版'), _mkRecord('火影忍者')];
      final hit = filterVideoRecords(all, '海贼');
      expect(hit.length, 2);
      expect(hit.map((r) => r.title), containsAll(['海贼王', '海贼王剧场版']));
    });

    test('大小写不敏感', () {
      final all = [_mkRecord('Spy x Family'), _mkRecord('间谍过家家')];
      expect(filterVideoRecords(all, 'spy').length, 1);
      expect(filterVideoRecords(all, 'SPY').length, 1);
    });

    test('无命中返回空表', () {
      expect(filterVideoRecords([_mkRecord('海贼王')], '不存在'), isEmpty);
    });

    test('空表任意过滤返回空', () {
      expect(filterVideoRecords(const [], '海贼'), isEmpty);
    });
  });

  group('filterHistory', () {
    test('空过滤原样返回', () {
      final all = [
        _mkHistory('海贼王', '第 1 话'),
        _mkHistory('火影忍者', '第 2 话'),
      ];
      expect(filterHistory(all, ''), same(all));
      expect(filterHistory(all, '  '), same(all));
    });

    test('按书名匹配', () {
      final all = [
        _mkHistory('海贼王', '第 1 话'),
        _mkHistory('海贼王外传', '第 3 话'),
        _mkHistory('火影忍者', '第 2 话'),
      ];
      final hit = filterHistory(all, '海贼');
      expect(hit.length, 2);
      expect(hit.map((h) => h.book.name), containsAll(['海贼王', '海贼王外传']));
    });

    test('按章节标题匹配', () {
      final all = [
        _mkHistory('海贼王', '顶上之战'),
        _mkHistory('火影忍者', '终末之谷'),
      ];
      final hit = filterHistory(all, '顶上');
      expect(hit.length, 1);
      expect(hit.single.chapterTitle, '顶上之战');
    });

    test('大小写不敏感', () {
      final all = [_mkHistory('One Piece', '第 1 话')];
      expect(filterHistory(all, 'one').length, 1);
      expect(filterHistory(all, 'PIECE').length, 1);
    });

    test('无命中返回空表', () {
      expect(filterHistory([_mkHistory('海贼王', '第 1 话')], '不存在'), isEmpty);
    });
  });
}