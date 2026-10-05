import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/video_source.dart';
import 'package:xingmanxia/ui/episode_list_page.dart';

void main() {
  group('filterVideoEpisodes', () {
    List<VideoEpisode> eps() => [
          VideoEpisode(1, 1, '第1话 初识'),
          VideoEpisode(1, 2, '第2话 冲突'),
          VideoEpisode(1, 3, '第3话 决战'),
          VideoEpisode(1, 10, '番外：日常'),
          VideoEpisode(1, 12, ''),
          VideoEpisode(2, 1, '第二季 第1话 归来'),
        ];

    test('空过滤返回原列表（同一引用）', () {
      final list = eps();
      expect(filterVideoEpisodes(list, ''), same(list));
    });

    test('标题模糊匹配', () {
      final out = filterVideoEpisodes(eps(), '决战');
      expect(out.length, 1);
      expect(out.first.episode, 3);
    });

    test('集数直接匹配（「12」命中第 12 集）', () {
      final out = filterVideoEpisodes(eps(), '12');
      expect(out.map((e) => e.episode), [12]);
      // 番外第 10 集标题不含「12」，不误命中
      expect(out.map((e) => e.title), isNot(contains('番外')));
    });

    test('空标题不匹配任何关键词（不崩）', () {
      final out = filterVideoEpisodes(eps(), '话');
      expect(out.every((e) => e.title.isNotEmpty), isTrue);
    });

    test('大小写不敏感', () {
      final e = VideoEpisode(1, 5, 'OVA Special');
      expect(filterVideoEpisodes([e], 'special').length, 1);
      expect(filterVideoEpisodes([e], 'SPECIAL').length, 1);
    });

    test('无匹配返回空列表', () {
      expect(filterVideoEpisodes(eps(), '不存在的词'), isEmpty);
    });

    test('空白过滤词视同空', () {
      final list = eps();
      expect(filterVideoEpisodes(list, '   '), same(list));
    });
  });
}
