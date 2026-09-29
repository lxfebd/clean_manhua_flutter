import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/sources/video_source.dart';
import 'package:xingmanxia/ui/episode_grouping.dart';

/// 选集分组纯计算回归测试（从播放器主 State 抽出后补的单元覆盖）。
void main() {
  group('groupEpisodesBySeason', () {
    test('单源：按季分组并保持源内顺序', () {
      final groups = groupEpisodesBySeason([
        VideoEpisode(1, 1, '第1集'),
        VideoEpisode(1, 2, '第2集'),
        VideoEpisode(1, 3, '第3集'),
      ], null);
      expect(groups, hasLength(1));
      expect(groups[0].name, '线路 1');
      expect(groups[0].eps.map((e) => e.episode), [1, 2, 3]);
    });

    test('多源：按 season 升序分组，sourceNames 提供源名', () {
      final groups = groupEpisodesBySeason([
        VideoEpisode(1, 1, 's1e1'),
        VideoEpisode(1, 2, 's1e2'),
        VideoEpisode(2, 1, 's2e1'),
      ], {1: '主线-1', 2: '主线-2'});
      expect(groups, hasLength(2));
      expect(groups[0].name, '主线-1');
      expect(groups[1].name, '主线-2');
      expect(groups[0].eps, hasLength(2));
      expect(groups[1].eps, hasLength(1));
    });

    test('sourceNames 缺失某 season 时兜底「线路 N」', () {
      final groups = groupEpisodesBySeason([
        VideoEpisode(1, 1, 'a'),
        VideoEpisode(5, 1, 'b'),
      ], {5: '备用'});
      expect(groups[0].name, '线路 1');
      expect(groups[1].name, '备用');
    });

    test('空列表返回空', () {
      expect(groupEpisodesBySeason(const [], null), isEmpty);
    });

    test('相同 season 的剧集全部聚合', () {
      final groups = groupEpisodesBySeason([
        VideoEpisode(2, 3, 'c'),
        VideoEpisode(2, 1, 'a'),
        VideoEpisode(2, 2, 'b'),
      ], null);
      expect(groups, hasLength(1));
      expect(groups[0].eps.map((e) => e.episode), [3, 1, 2],
          reason: '保持传入顺序，不做内部排序');
    });
  });
}
