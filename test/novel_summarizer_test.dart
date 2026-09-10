import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/novel_summarizer.dart';

void main() {
  group('NovelSummarizer', () {
    test('空输入返回空列表', () {
      expect(NovelSummarizer.summarize(const []), isEmpty);
    });

    test('短段数量不超过上限直接全量返回', () {
      final paras = ['这是第一句完整内容。', '这是第二句完整内容。', '这是第三句完整内容。'];
      final out = NovelSummarizer.summarize(paras, maxSentences: 5);
      expect(out.length, 3);
    });

    test('过短/纯语气行被过滤', () {
      final paras = [
        '嗯。',
        '……',
        '张伟抬头，忽然看到远处有人影闪过，他心头一紧，却想到今天该回来了。',
        '好。',
      ];
      final out = NovelSummarizer.summarize(paras, maxSentences: 5);
      expect(out.length, 1);
      expect(out.single.contains('张伟'), isTrue);
    });

    test('长章节按位置+关键词挑出代表性句子且按原文序输出', () {
      final paras = <String>[];
      for (var i = 0; i < 40; i++) {
        paras.add('这是第$i段的普通填充内容，没有任何关键信息，仅用于拉长篇幅以触发摘牌算法。');
      }
      // 中间放一段高潮句（第 20 段附近）
      paras[20] = '他忽然发现真相，决定立刻回去救人，但没想到敌人已经先一步赶到。';
      final out = NovelSummarizer.summarize(paras, maxSentences: 3);
      expect(out.length, 3);
      expect(out.any((s) => s.contains('真相')), isTrue,
          reason: '高潮句应被关键词加权选中');
      // 按原文顺序
      final idx = out.map(paras.indexOf).toList();
      for (var i = 1; i < idx.length; i++) {
        expect(idx[i] >= idx[i - 1], isTrue);
      }
    });

    test('主角名加权', () {
      final paras = [
        '林晚照常翻开古籍，却发现那一页的批注与昨日不同。',
        '风吹过庭院，秋叶落了一地。',
        '他盯着那行字，笑了起来。',
      ];
      final out = NovelSummarizer.summarize(paras, maxSentences: 2, focusName: '林晚');
      expect(out.first.contains('林晚'), isTrue,
          reason: '主角名命中应优先入选');
    });

    test('结尾段权重高（钩子句入选）', () {
      final paras = <String>[];
      for (var i = 0; i < 30; i++) {
        paras.add('重复的日常描写，吃饭睡觉修炼，平平淡淡无波无澜。');
      }
      paras.add('第二天清晨，宗门上下却传遍了一个惊人的消息。');
      final out = NovelSummarizer.summarize(paras, maxSentences: 2);
      expect(out.any((s) => s.contains('惊人的消息')), isTrue,
          reason: '结尾钩子句应入选');
    });

    test('省略号句读不拆散', () {
      final out = NovelSummarizer.summarize(
          ['他沉默良久，终于下定了决心……这一去，便再难回头。'], maxSentences: 5);
      expect(out.length, 2);
      expect(out.first.endsWith('……'), isTrue);
    });
  });
}