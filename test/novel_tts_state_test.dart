import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/services/novel_tts_service.dart';

/// P1-22：TTS「暂停」状态机回归。
///
/// 旧 bug：`pause()` 先置 paused，再调 `_stopEngine()`，而后者无条件把状态
/// 洗成 idle —— 暂停按钮表现成停止，UI 的 idle 分支还会重新 loadChapter，
/// 句内偏移设计完全失效。本测试用假引擎（不依赖任何 TTS 插件）锁死
/// speaking ↔ paused ↔ idle 的翻转语义。
class _FakeTts extends FlutterTts {
  int stopCalls = 0;
  int speakCalls = 0;

  @override
  Future<dynamic> stop() async {
    stopCalls++;
    return 1;
  }

  @override
  Future<dynamic> speak(String? text, {bool? focus}) async {
    speakCalls++;
    return 1;
  }

  @override
  Future<dynamic> setLanguage(String? language) async => 1;

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> setVolume(double volume) async => 1;

  @override
  Future<dynamic> setCompletionHandler(Function? handler) async => 1;
}

void main() {
  // FlutterTts 构造时会注册 MethodChannel handler，必须先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  late NovelTtsService tts;
  late _FakeTts engine;

  setUp(() {
    tts = NovelTtsService.instance;
    engine = _FakeTts();
    tts.engineForTest = engine;
    // 每个用例从干净状态开始（reset 会走 stop → idle）。
    tts.reset();
    tts.onParagraph = null;
    tts.onStateChange = null;
    tts.onError = null;
  });

  group('pause/reset 状态机（P1-22）', () {
    test('play → pause：状态保持 paused（不再被洗成 idle）', () async {
      tts.loadChapter(['第一段话，有标点。第二句！'], startIndex: 0);
      await tts.play();
      expect(tts.state, TtsPlayState.speaking,
          reason: '前置条件：已进入朗读');
      final before = engine.stopCalls;

      await tts.pause();
      expect(tts.state, TtsPlayState.paused,
          reason: '暂停后必须停在 paused；旧实现会掉回 idle 并重载章节');
      expect(engine.stopCalls - before,
          1, reason: '暂停要停掉引擎实例（只多一次）');
    });

    test('paused → play：恢复为 speaking', () async {
      tts.loadChapter(['第一段话，有标点。第二句！'], startIndex: 0);
      await tts.play();
      await tts.pause();
      await tts.play();
      expect(tts.state, TtsPlayState.speaking);
    });

    test('reset/stop：状态回 idle（唯一允许的洗白路径）', () async {
      tts.loadChapter(['第一段话，有标点。第二句！'], startIndex: 0);
      await tts.play();
      await tts.pause();
      expect(tts.state, TtsPlayState.paused);
      await tts.reset();
      expect(tts.state, TtsPlayState.idle,
          reason: '翻章/换书/退出才允许 reset 到 idle');
    });

    test('引擎 speak 抛异常时落 idle 并回调 onError（既有降级行为不回退）',
        () async {
      var errored = false;
      tts.onError = () => errored = true;
      tts.loadChapter(['第一段话，有标点。'], startIndex: 0);
      // speak 抛异常（模拟无引擎环境）时不应把状态卡在 speaking。
      final thrower = _ThrowingTts();
      tts.engineForTest = thrower;
      await tts.play();
      expect(tts.state, TtsPlayState.idle);
      expect(errored, isTrue);
      // 恢复 setUp 的引擎引用，避免影响后续用例。
      tts.engineForTest = engine;
    });

    test('reset 后队列清空：空队列 play 不再回到 speaking', () async {
      await tts.reset();
      await tts.play();
      expect(tts.state, TtsPlayState.idle);
    });
  });

  group('splitSentences 纯逻辑', () {
    test('中文标点断句，标点保留在句尾', () {
      expect(
        NovelTtsService.splitSentences('你好。世界！结束？'),
        ['你好。', '世界！', '结束？'],
      );
    });

    test('无句号时逗号作停顿点', () {
      expect(
        NovelTtsService.splitSentences('第一，第二'),
        ['第一，', '第二'],
      );
    });

    test('有句号时以句号断（逗号不打断）——正则语义：句号类优先', () {
      expect(
        NovelTtsService.splitSentences('第一，第二。'),
        ['第一，第二。'],
      );
      expect(
        NovelTtsService.splitSentences('甲，乙。丙。'),
        ['甲，乙。', '丙。'],
      );
    });

    test('无标点时整段一句', () {
      expect(NovelTtsService.splitSentences('没有标点的一句话'), ['没有标点的一句话']);
    });

    test('空串返回空列表', () {
      expect(NovelTtsService.splitSentences(''), isEmpty);
    });
  });
}

class _ThrowingTts extends FlutterTts {
  @override
  Future<dynamic> speak(String? text, {bool? focus}) async =>
      throw Exception('no engine');

  @override
  Future<dynamic> stop() async => 1;

  @override
  Future<dynamic> setCompletionHandler(Function? handler) async => 1;
}
