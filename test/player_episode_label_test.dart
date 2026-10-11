import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/player_utils.dart';

void main() {
  group('episodeLabel 集数标签', () {
    test('有标题用标题', () {
      expect(episodeLabel('第一话 相遇', 3), '第一话 相遇');
    });
    test('空标题回退第 N 集', () {
      expect(episodeLabel('', 3), '第 3 集');
    });
    test('空白标题原样返回（isEmpty 只认真空串，不 trim）', () {
      expect(episodeLabel('   ', 12), '   ');
    });
  });
}