import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/services/novel_tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NovelTtsService.splitSentences', () {
    test('按中英文标点切句，标点保留在句尾', () {
      final s = '你好。世界！这是测试…真的吗？是的，没错；当然。';
      final out = NovelTtsService.splitSentences(s);
      expect(out, isNotEmpty);
      expect(out.first, '你好。');
      // 标点保留：无一句以「裸字」结束（除末段无标点尾部）。
      for (final seg in out.take(out.length - 1)) {
        expect(RegExp(r'[。！？!?；;，,]$').hasMatch(seg), isTrue,
            reason: '标点应保留在句尾: $seg');
      }
      // 全部拼接回去应还原原文。
      expect(out.join(), s);
    });

    test('无标点长文本 fallback 拆整句', () {
      final s = '这是一段没有标点的长文本内容';
      final out = NovelTtsService.splitSentences(s);
      expect(out.length, greaterThanOrEqualTo(1));
      expect(out.join(), s);
    });

    test('空串与纯标点', () {
      expect(NovelTtsService.splitSentences(''), isEmpty);
      final out = NovelTtsService.splitSentences('……');
      expect(out.join(), '……');
    });
  });

  group('NovelTtsService 状态机', () {
    test('初始 idle，rates 档位齐全', () {
      expect(NovelTtsService.instance.state, TtsPlayState.idle);
      expect(NovelTtsService.rates, [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]);
    });

    test('loadChapter 裁剪段落数组并归零游标', () {
      final svc = NovelTtsService.instance;
      final start = svc.loadChapter(['a', 'b', 'c'], startIndex: 2);
      expect(start, 2);
      svc.seekTo(0);
      // seekTo 不改变状态
      expect(svc.state, TtsPlayState.idle);
    });

    test('rate clamp 到 0.5~2.0', () async {
      final svc = NovelTtsService.instance;
      await svc.init(rate: 99);
      expect(svc.rate, 2.0);
      await svc.init(rate: 0.1);
      expect(svc.rate, 0.5);
    });
  });
}