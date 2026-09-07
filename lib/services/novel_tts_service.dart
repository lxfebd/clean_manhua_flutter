import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 朗读状态机：idle → speaking ↔ paused。
enum TtsPlayState { idle, speaking, paused }

/// 章节朗读服务：段落队列 + 状态机 + 句间自然停顿。
///
/// 模型：一段文本 = 多次 [FlutterTts.speak] 调用（按标点切句），引擎完成回调
/// 驱动队列前进 → 完成回调全平台可靠，不依赖 Android 26+ 的逐词进度。
/// 标点断句自带停顿：句号/问号/叹号后 0.55s，段末 0.8s，读感接近真人断句。
///
/// 暂停策略：Android 原生 pause 依赖 SDK 26+，低版本不可靠 → 统一用
/// stop + 句内偏移记录，恢复时从偏移重新合成（低版本效果一致）。
class NovelTtsService {
  NovelTtsService._internal();

  static final NovelTtsService instance = NovelTtsService._internal();

  final FlutterTts _tts = FlutterTts();

  /// 语速显示档位（0.5x ~ 2x），对应 setSpeechRate 的数值。
  static const List<double> rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  /// 当前语速（0.5~2.0）。
  double rate = 1.0;

  List<String> _queue = [];
  int _index = 0;
  int _spokenChars = 0;

  /// 当前朗读段落下标（UI 高亮用；-1 = 无）。
  void Function(int paragraphIndex)? onParagraph;

  /// 播放状态翻转（UI 换图标用）。
  void Function(TtsPlayState state)? onStateChange;

  TtsPlayState _state = TtsPlayState.idle;
  TtsPlayState get state => _state;

  bool _accumulating = false;
  Timer? _timer;
  bool _disposed = false;

  void _setState(TtsPlayState s) {
    if (_state == s) return;
    _state = s;
    onStateChange?.call(s);
  }

  /// 初始化引擎会话（语言 + 档位 + 完成回调），幂等；换速时仅需重调。
  Future<void> init({double? rate}) async {
    if (_disposed) return;
    if (rate != null) this.rate = rate.clamp(0.5, 2.0);
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(this.rate);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      _tts.setCompletionHandler(() {
        // stop() 也会触发完成回调 → 用 _accumulating 拦截（停、跳转都不前进）。
        if (!_accumulating) return;
        _timer?.cancel();
        _timer = Timer(const Duration(milliseconds: 550), _speakNext);
      });
    } catch (e) {
      debugPrint('NovelTts init: $e');
    }
  }

  /// 停止并重置（翻章/换书/退出阅读器）。
  Future<void> reset() async {
    _cancelTimer();
    _queue = [];
    _index = 0;
    _spokenChars = 0;
    _accumulating = false;
    await _stopEngine();
  }

  Future<void> _stopEngine() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _setState(TtsPlayState.idle);
  }

  /// 载入一章（整体替换队列），返回起始段下标。
  int loadChapter(List<String> paragraphs, {int startIndex = 0}) {
    _cancelTimer();
    _queue = List.of(paragraphs);
    _index = startIndex.clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
    _spokenChars = 0;
    return _index;
  }

  /// 跳到指定段（不改变播放状态；配合 UI 点段朗读）。
  void seekTo(int paragraphIndex) {
    _cancelTimer();
    _index = paragraphIndex.clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
    _spokenChars = 0;
  }

  /// 开始/继续朗读（从上次位置；被 [pause]/[reset] 中断后可恢复）。
  Future<void> play() async {
    if (_disposed) return;
    if (_queue.isEmpty || _index >= _queue.length) {
      _setState(TtsPlayState.idle);
      return;
    }
    _accumulating = true;
    _setState(TtsPlayState.speaking);
    onParagraph?.call(_index);
    await _speakNext();
  }

  Future<void> pause() async {
    if (_disposed) return;
    if (_state == TtsPlayState.paused) return;
    _setState(TtsPlayState.paused);
    _cancelTimer();
    // stop 会触发完成回调 → 先关掉累计开关，让回调只停不前进。
    _accumulating = false;
    await _stopEngine();
    // 低版本 Android 无法精确续读：句首过半就整句重读（回到本段开头）。
    if (_spokenChars > 0 && _spokenChars < _queue[_index].length / 2) {
      _spokenChars = 0;
    }
  }

  Future<void> stop() => reset();

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _speakNext() async {
    _timer = null;
    if (_disposed) return;
    if (!_accumulating) return;
    if (_queue.isEmpty) return;

    final paras = _queue[_index];
    if (_spokenChars >= paras.length) {
      // 本段读完 → 下一段，段间停顿 0.8s。
      _index++;
      _spokenChars = 0;
      if (_index >= _queue.length) {
        _accumulating = false;
        _setState(TtsPlayState.idle);
        onParagraph?.call(-1);
        return;
      }
      onParagraph?.call(_index);
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 800), _speakNext);
      return;
    }

    final sentences = splitSentences(paras.substring(_spokenChars));
    if (sentences.isEmpty) {
      _spokenChars = paras.length;
      _speakNext();
      return;
    }
    final text = sentences.first;
    _spokenChars += text.length;
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('NovelTts speak: $e');
      _accumulating = false;
      _setState(TtsPlayState.idle);
    }
  }

  /// 按中文/英文标点切句；标点保留在句尾（作为停顿点）。
  /// 公开为静态以便纯逻辑测试（不依赖 TTS 引擎）。
  static List<String> splitSentences(String s) {
    if (s.isEmpty) return [];
    final re = RegExp(r'.+?[。！？!?；;]|.+?[，,]|.+?(?=[。！？!?；;，,])|.+');
    final matches = re.allMatches(s);
    if (matches.isEmpty) return [s];
    return matches.map((m) => m.group(0)!).toList();
  }

  void dispose() {
    _disposed = true;
    _cancelTimer();
    try {
      _tts.stop();
    } catch (_) {}
  }
}