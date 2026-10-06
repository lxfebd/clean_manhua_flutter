import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/anime_home_page.dart';

VideoRecord _mk(String sourceId, String videoId, int episode) {
  return VideoRecord(
    sourceId: sourceId,
    videoId: videoId,
    title: '测试番',
    episode: episode,
    timestamp: 1,
  );
}

void main() {
  group('watchedEpisodesOf', () {
    test('无记录返回 null', () {
      expect(
        watchedEpisodesOf(const [], 's', 'v1'),
        isNull,
      );
    });

    test('返回该作品最后一次播放的集数', () {
      expect(
        watchedEpisodesOf(
          [
            _mk('s', 'v1', 3),
            _mk('s', 'v1', 8),
            _mk('s', 'v1', 5),
          ],
          's',
          'v1',
        ),
        8,
      );
    });

    test('按 sourceId + videoId 双键精确匹配', () {
      expect(
        watchedEpisodesOf(
          [
            _mk('s', 'v1', 12),
            _mk('other', 'v1', 99),
            _mk('s', 'v2', 7),
          ],
          's',
          'v1',
        ),
        12,
      );
    });

    test('单条记录直接返回', () {
      expect(
        watchedEpisodesOf([_mk('s', 'v9', 4)], 's', 'v9'),
        4,
      );
    });

    test('负数/异常集数不放大', () {
      expect(
        watchedEpisodesOf(
          [
            _mk('s', 'v1', -1),
            _mk('s', 'v1', 0),
            _mk('s', 'v1', 6),
          ],
          's',
          'v1',
        ),
        6,
      );
    });
  });
}
