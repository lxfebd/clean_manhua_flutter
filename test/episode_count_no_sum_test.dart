import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/video_source.dart';
import 'package:xingmanxia/ui/episode_grouping.dart';

/// 回归：动漫多线路（season）剧集**不得相加**。
///
/// 背景：同一部番剧在多个播放渠道（线路）上都有剧集，各线路互为镜像。
/// 早期实现直接取 `episodes.length` 显示「共 N 集」，4 个渠道 × 12 集
/// 会被显示成 48 集，严重误导。本测试锁死正确口径。
void main() {
  List<VideoEpisode> lines(Map<int, int> counts) => [
        for (final e in counts.entries)
          for (var i = 1; i <= e.value; i++)
            VideoEpisode(e.key, i, '第 $i 集'),
      ];

  group('episodeCountFor：多线路不累加', () {
    test('单线路：就是该线路集数', () {
      final eps = lines({1: 12});
      expect(episodeCountFor(eps, {1: '主线'}), 12);
    });

    test('4 线路各 12 集：报 12 集，绝不报 48', () {
      final eps = lines({1: 12, 2: 12, 3: 12, 4: 12});
      final n = episodeCountFor(eps, {1: 'A', 2: 'B', 3: 'C', 4: 'D'});
      expect(n, 12);
      expect(n, isNot(48));
    });

    test('多线路且集数不同：报线路数（不报相加）', () {
      final eps = lines({1: 12, 2: 10});
      expect(episodeCountFor(eps, {1: 'A', 2: 'B'}), 2);
    });

    test('空列表：0', () {
      expect(episodeCountFor(const [], null), 0);
    });
  });

  group('episodeCountLabelFor：文案口径', () {
    test('单线路：共 N 集', () {
      expect(episodeCountLabelFor(lines({1: 12}), {1: '主线'}), '共 12 集');
    });

    test('多线路各 12 集：M 线路 · 共 12 集（不是 48）', () {
      final eps = lines({1: 12, 2: 12, 3: 12, 4: 12});
      final label = episodeCountLabelFor(eps, {1: 'A', 2: 'B', 3: 'C', 4: 'D'});
      expect(label, '4 线路 · 共 12 集');
      expect(label.contains('48'), isFalse);
    });

    test('多线路集数不同且有当前集：报当前线路集数', () {
      final eps = lines({1: 12, 2: 10});
      final label = episodeCountLabelFor(eps, {1: 'A', 2: 'B'},
          currentSeason: 2, currentEpisode: 3);
      expect(label, '2 线路 · 当前 10 集');
    });

    test('多线路集数不同且无当前集：不报具体集数', () {
      final eps = lines({1: 12, 2: 10});
      final label = episodeCountLabelFor(eps, {1: 'A', 2: 'B'});
      expect(label, '2 线路 · 各线路集数不同');
      expect(label.contains('22'), isFalse);
    });
  });
}
