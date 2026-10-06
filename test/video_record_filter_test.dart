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
}