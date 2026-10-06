import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/bookshelf_page.dart';

/// totalEpisodesWatched 纯函数测试：动画记录累计追番集数（最后播放集数之和）。
VideoRecord _mk(String videoId, int episode, {int seconds = 0}) => VideoRecord(
      sourceId: 's1',
      videoId: videoId,
      title: '番剧$videoId',
      cover: null,
      season: 1,
      episode: episode,
      totalEpisodes: 12,
      seconds: seconds,
      timestamp: 0,
    );

void main() {
  test('空列表返回 0', () {
    expect(totalEpisodesWatched([]), 0);
  });

  test('单条记录累加最后播放集数', () {
    expect(totalEpisodesWatched([_mk('a', 5)]), 5);
    expect(totalEpisodesWatched([_mk('a', 12)]), 12);
  });

  test('多条记录累加', () {
    final list = [_mk('a', 5), _mk('b', 8), _mk('c', 3)];
    expect(totalEpisodesWatched(list), 16);
  });

  test('负数集数按 0 计（脏数据兜底）', () {
    final list = [_mk('a', -1), _mk('b', 4)];
    expect(totalEpisodesWatched(list), 4);
  });

  test('season/episode 大值累加正确', () {
    final list = [_mk('a', 24), _mk('b', 48)];
    expect(totalEpisodesWatched(list), 72);
  });
}
