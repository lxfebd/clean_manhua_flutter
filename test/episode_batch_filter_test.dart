import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/video_source.dart';
import 'package:xingmanxia/ui/episode_batch_download_sheet.dart';

void main() {
  group('filterEpisodeDownloadIndexes（批量下载选集过滤）', () {
    List<VideoEpisode> eps() => [
          VideoEpisode(1, 1, '第一集 序章'),
          VideoEpisode(1, 2, '第二集 相遇'),
          VideoEpisode(1, 12, '第十二集 决战'),
        ];

    test('空过滤返回原索引列表（同一引用）', () {
      final indices = [0, 2];
      expect(
          filterEpisodeDownloadIndexes(eps(), indices, ''), same(indices));
    });

    test('按标题模糊匹配', () {
      final out = filterEpisodeDownloadIndexes(eps(), [0, 1, 2], '相遇');
      expect(out, [1]);
    });

    test('直接输集数精确匹配（12 匹配第 12 集）', () {
      final out = filterEpisodeDownloadIndexes(eps(), [0, 1, 2], '12');
      expect(out, [2]);
    });

    test('集数子串匹配（1 同时命中第 1 与第 12 集）', () {
      final out = filterEpisodeDownloadIndexes(eps(), [0, 1, 2], '1');
      expect(out.toSet(), {0, 2});
    });

    test('只过滤传入的索引子集', () {
      final out = filterEpisodeDownloadIndexes(eps(), [1, 2], '决战');
      expect(out, [2]);
    });

    test('无匹配返回空列表', () {
      final out = filterEpisodeDownloadIndexes(eps(), [0, 1, 2], '不存在');
      expect(out, isEmpty);
    });

    test('大小写不敏感（英文标题）', () {
      final list = [VideoEpisode(1, 1, 'Episode One')];
      final out = filterEpisodeDownloadIndexes(list, [0], 'episode');
      expect(out, [0]);
    });
  });
}
