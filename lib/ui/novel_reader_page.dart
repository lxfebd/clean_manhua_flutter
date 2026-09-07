import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/local_store.dart';
import '../services/novel_tts_service.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import 'responsive.dart';

/// 小说阅读器：渲染章节正文（段落列表），支持上下章导航与阅读进度记录。
class NovelReaderPage extends StatefulWidget {
  final String sourceId;
  final String novelId;
  final String chapterId;
  final String title;
  final String novelName;
  final String novelPic;
  final String novelAuthor;
  const NovelReaderPage({
    super.key,
    required this.sourceId,
    required this.novelId,
    required this.chapterId,
    required this.title,
    required this.novelName,
    required this.novelPic,
    required this.novelAuthor,
  });

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  NovelContent? _content;
  bool _loading = true;
  String? _error;
  String _curChapterId;

  // 阅读自定义
  int _fontSize = 17;
  int _lineHeight = 180;
  int _theme = 0;
  int _paragraphGap = 18; // 段间距（px）
  bool _firstIndent = true; // 首行缩进 2 字符
  int _colorTemp = 0; // 色温 0~100（0 = 无色温滤镜）

  final Stopwatch _readWatch = Stopwatch();
  Timer? _statsTimer;
  ScrollController? _listController;

  // ---- 朗读（TTS） ----
  final NovelTtsService _tts = NovelTtsService.instance;
  TtsPlayState _ttsState = TtsPlayState.idle;
  int _ttsRateIdx = 2; // NovelTtsService.rates 下标，默认 1.0x
  int _ttsSentence = -1; // 当前朗读中的段落下标（-1 = 未朗读）

  static const _themes = [
    (name: '跟随', bg: '0xFF111215', text: '0xFFE8EAF0', isDark: true),
    (name: '米白', bg: '0xFFF5F0E8', text: '0xFF3A342C', isDark: false),
    (name: '浅绿', bg: '0xFFDCE8D4', text: '0xFF2E3A2A', isDark: false),
    (name: '深青', bg: '0xFF10242B', text: '0xFFC8D8DC', isDark: true),
  ];

  _NovelReaderPageState() : _curChapterId = '';

  @override
  void initState() {
    super.initState();
    _curChapterId = widget.chapterId;
    _readWatch.start();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _flushStats());
    _loadSettings();
    _initTts();
    _load(widget.chapterId);
    // 桌面端键盘：←/→ 翻章、Esc 返回。仅桌面注册，避免移动端蓝牙键盘误触。
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
    }
  }

  Future<void> _initTts() async {
    final saved = await LocalStore.ttsRate();
    _ttsRateIdx = NovelTtsService.rates.indexWhere((r) => (r - saved).abs() < 0.01);
    if (_ttsRateIdx < 0) _ttsRateIdx = 2;
    _tts.onParagraph = (idx) {
      if (!mounted) return;
      setState(() => _ttsSentence = idx);
      // 朗读到当前段时滚动跟随：仅当段在可视区外才滚（避免打断手动翻页）。
      if (idx < 0) return;
      final controller = _listController;
      if (controller == null || !controller.hasClients) return;
      // 段高估算：行高 * 行数 + 段间距，取下标即段落位置。
      final estPos = idx * (_fontSize * (_lineHeight / 100) + _paragraphGap);
      final view = MediaQuery.of(context).size.height * 0.7;
      if ((estPos - controller.offset).abs() > view) {
        controller.animateTo(
          (estPos - view * 0.3).clamp(0.0, controller.position.maxScrollExtent),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    };
    _tts.onStateChange = (s) {
      if (!mounted) return;
      setState(() => _ttsState = s);
    };
    await _tts.init(rate: NovelTtsService.rates[_ttsRateIdx]);
  }

  @override
  void dispose() {
    _tts.dispose();
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.removeHandler(_keyHandler);
    }
    _statsTimer?.cancel();
    _readWatch.stop();
    final elapsed = _readWatch.elapsed.inSeconds;
    if (elapsed > 0) LocalStore.addReadingSeconds(elapsed);
    super.dispose();
  }

  Future<void> _flushStats() async {
    final elapsed = _readWatch.elapsed.inSeconds;
    if (elapsed <= 0) return;
    _readWatch.reset();
    _readWatch.start();
    await LocalStore.addReadingSeconds(elapsed);
  }

  Future<void> _loadSettings() async {
    final fs = await LocalStore.novelFontSize();
    final lh = await LocalStore.novelLineHeight();
    final th = await LocalStore.novelTheme();
    final gap = await LocalStore.novelParagraphGap();
    final indent = await LocalStore.novelFirstIndent();
    final ct = await LocalStore.novelColorTemp();
    if (mounted) {
      setState(() {
        _fontSize = fs;
        _lineHeight = lh;
        _theme = th;
        _paragraphGap = gap;
        _firstIndent = indent;
        _colorTemp = ct;
      });
    }
  }

  Future<void> _load(String chapterId) async {
    final s = SourceManager.novelById(widget.sourceId);
    if (s == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '未找到小说源';
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _loading = true);
    }
    // 复用同一 controller：翻章时已由 _go 跳回顶部，卸载不清除以便重建 Focus。
    _listController ??= ScrollController();
    try {
      final c = await s.chapterContent(chapterId).timeout(const Duration(seconds: 15));
      if (mounted) {
        _content = c;
        _curChapterId = chapterId;
        _error = null;
        _recordHistory(c.title);
        // 换章后刷新朗读队列：内容加载期间朗读自然停在旧章末尾。
        _tts.reset();
        _tts.loadChapter(c.paragraphs);
      }
    } catch (e) {
      if (mounted) _error = '加载失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _recordHistory(String chapterTitle) {
    LocalStore.recordHistory(HistoryEntry(
      book: Bookmark(
        sourceId: widget.sourceId,
        comicId: widget.novelId,
        name: widget.novelName,
        pic: widget.novelPic,
        author: widget.novelAuthor,
      ),
      chapterId: _curChapterId,
      chapterTitle: chapterTitle,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  void _go(String? chapterId) {
    if (chapterId == null) return;
    HapticFeedback.lightImpact();
    // 翻章时新章节从顶部开始读。
    if (_listController != null && _listController!.hasClients) {
      _listController!.jumpTo(0);
    }
    _load(chapterId);
  }

  /// 桌面端键盘：←/→ 翻章、Esc 返回。
  bool _keyHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_loading) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(_content?.prevChapterId);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(_content?.nextChapterId);
      return true;
    }
    // PageUp/PageDown/空格 滚动正文（移动到 ListView 滚动事件处理）。
    return false;
  }

  /// 打开阅读设置底部抽屉。
  void _showSettings() {
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _NovelReaderSettingsSheet(
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        theme: _theme,
        paragraphGap: _paragraphGap,
        firstIndent: _firstIndent,
        colorTemp: _colorTemp,
        onFontSize: (v) async {
          setState(() => _fontSize = v);
          await LocalStore.setNovelReadSettings(fontSize: v);
        },
        onLineHeight: (v) async {
          setState(() => _lineHeight = v);
          await LocalStore.setNovelReadSettings(lineHeight: v);
        },
        onTheme: (v) async {
          setState(() => _theme = v);
          await LocalStore.setNovelReadSettings(theme: v);
        },
        onParagraphGap: (v) async {
          setState(() => _paragraphGap = v);
          await LocalStore.setNovelReadSettings(paragraphGap: v);
        },
        onFirstIndent: (v) async {
          setState(() => _firstIndent = v);
          await LocalStore.setNovelReadSettings(firstIndent: v);
        },
        onColorTemp: (v) async {
          setState(() => _colorTemp = v);
          await LocalStore.setNovelReadSettings(colorTemp: v);
        },
      ),
    );
  }

  // ---- 朗读控制 ----
  void _ttsToggle() async {
    final paras = _content?.paragraphs;
    if (paras == null || paras.isEmpty) return;
    switch (_ttsState) {
      case TtsPlayState.idle:
        // 从头开始；若队列未载入（上章残留）则重新装载。
        _tts.loadChapter(paras);
        await _tts.play();
      case TtsPlayState.speaking:
        await _tts.pause();
      case TtsPlayState.paused:
        await _tts.play();
    }
  }

  /// 朗读设置抽屉：语速档位 + 关闭朗读。
  void _showTtsSettings() {
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _NovelTtsSheet(
        rateIdx: _ttsRateIdx,
        onRate: (idx) {
          setState(() => _ttsRateIdx = idx);
          final r = NovelTtsService.rates[idx];
          _tts.init(rate: r);
          LocalStore.setTtsRate(r);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final useCustomBg = _theme > 0;
    final bgColor = useCustomBg
        ? Color(int.parse(_themes[_theme.clamp(0, _themes.length - 1)].bg))
        : scheme.surface;
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        foregroundColor: scheme.onSurface,
        title: Text(_content?.title ?? widget.title,
            style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: '阅读设置',
            icon: const Icon(Icons.text_fields_rounded, size: 20),
            onPressed: _showSettings,
          ),
        ],
      ),
      // 色温护眼：正文区叠加暖色半透明滤镜（纯图层，无额外解码开销）。
      // 0 = 无色温，100 = 最暖（约 3000K），透明度随档位线性增强。
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(_error!,
                              style: TextStyle(
                                  color: scheme.onSurface
                                      .withValues(alpha: 0.6))),
                          const SizedBox(height: 12),
                          FilledButton(
                              onPressed: () {
                                setState(() => _loading = true);
                                _load(_curChapterId);
                              },
                              child: const Text('重试')),
                        ],
                      ),
                    )
                  : _reader(scheme),
          if (_colorTemp > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: const Color(0xFFFF9E4D).withValues(
                      alpha: _colorTemp / 100 * 0.25),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _content == null
          ? null
          : SafeArea(
              child: Container(
                color: bgColor,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                // 按钮行与正文同宽（680/720 限宽）居中：桌面端两个按钮不会
                // 横跨全屏变成超宽大按钮，与上方限宽正文比例协调。
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: Responsive.novelReaderMaxWidth(context)),
                    child: Row(
                      children: [
                        // 朗读开关：首按钮常驻，让“听书”入口一眼可见。
                        if (_ttsState == TtsPlayState.idle)
                          IconButton(
                            tooltip: '朗读本章',
                            icon: const Icon(Icons.volume_up_rounded, size: 20),
                            onPressed: _ttsToggle,
                          )
                        else
                          IconButton(
                            tooltip: _ttsState == TtsPlayState.paused
                                ? '继续朗读'
                                : '暂停朗读',
                            icon: Icon(
                              _ttsState == TtsPlayState.paused
                                  ? Icons.play_arrow_rounded
                                  : Icons.pause_rounded,
                              size: 20,
                            ),
                            onPressed: _ttsToggle,
                          ),
                        IconButton(
                          tooltip: '朗读设置',
                          icon: const Icon(Icons.tune_rounded, size: 20),
                          onPressed: _showTtsSettings,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _go(_content!.prevChapterId),
                            child: const Text('上一章'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => _go(_content!.nextChapterId),
                            child: const Text('下一章'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _reader(scheme) {
    final paras = _content!.paragraphs;
    final useCustomBg = _theme > 0;
    final textColor = useCustomBg
        ? Color(int.parse(_themes[_theme.clamp(0, _themes.length - 1)].text))
        : scheme.onSurface.withValues(alpha: 0.92);

    final isSpeaking = _ttsState != TtsPlayState.idle && _ttsSentence >= 0;
    Widget para(int i) => Text(
          // 首行缩进 2 字符：全角空格前缀是中文排版最稳的实现方式
          // （TextIndent 对跨平台字体/缩放兼容性差，文本前缀永远正确）。
          _firstIndent ? '　　${paras[i]}' : paras[i],
          textAlign: TextAlign.justify,
          style: TextStyle(
            fontSize: _fontSize.toDouble(),
            height: _lineHeight / 100,
            color: isSpeaking && i == _ttsSentence
                ? scheme.primary
                : textColor,
          ),
        );

    // 单一 ListView：挂 _listController（翻章回顶、桌面键滚动都依赖它），
    // 段间距独立可调（不再跟行距耦合）。
    Widget list = ListView.separated(
      controller: _listController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: paras.length,
      separatorBuilder: (_, __) =>
          SizedBox(height: _paragraphGap.toDouble()),
      itemBuilder: (ctx, i) => para(i),
    );
    // 桌面端：包裹 Focus + 键盘滚动，使空格/PageUp/PageDown 可直接滚动正文；
    // 仅在桌面启用，移动端物理键盘不影响触摸滚动。
    if (DesktopUi.isDesktopPlatform) {
      list = Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final controller = _listController;
          if (controller == null || !controller.hasClients) {
            return KeyEventResult.ignored;
          }
          final step = MediaQuery.of(context).size.height * 0.85;
          if (event.logicalKey == LogicalKeyboardKey.pageDown ||
              event.logicalKey == LogicalKeyboardKey.space) {
            controller.animateTo(
              (controller.offset + step).clamp(0.0, controller.position.maxScrollExtent),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
            );
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.pageUp) {
            controller.animateTo(
              (controller.offset - step).clamp(0.0, controller.position.maxScrollExtent),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
            );
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: list,
      );
    }
    return Container(
      color: useCustomBg
          ? Color(int.parse(_themes[_theme.clamp(0, _themes.length - 1)].bg))
          : scheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: Responsive.novelReaderMaxWidth(context),
          ),
          child: list,
        ),
      ),
    );
  }
}

/// 小说阅读设置底部抽屉。
class _NovelReaderSettingsSheet extends StatefulWidget {
  final int fontSize;
  final int lineHeight;
  final int theme;
  final int paragraphGap;
  final bool firstIndent;
  final int colorTemp;
  final ValueChanged<int> onFontSize;
  final ValueChanged<int> onLineHeight;
  final ValueChanged<int> onTheme;
  final ValueChanged<int> onParagraphGap;
  final ValueChanged<bool> onFirstIndent;
  final ValueChanged<int> onColorTemp;
  const _NovelReaderSettingsSheet({
    required this.fontSize,
    required this.lineHeight,
    required this.theme,
    required this.paragraphGap,
    required this.firstIndent,
    required this.colorTemp,
    required this.onFontSize,
    required this.onLineHeight,
    required this.onTheme,
    required this.onParagraphGap,
    required this.onFirstIndent,
    required this.onColorTemp,
  });

  @override
  State<_NovelReaderSettingsSheet> createState() =>
      _NovelReaderSettingsSheetState();
}

class _NovelReaderSettingsSheetState
    extends State<_NovelReaderSettingsSheet> {
  static const _sizes = [14, 16, 17, 18, 20, 22];
  static const _heights = [150, 160, 170, 180, 190, 200];
  static const _themeNames = ['跟随', '米白', '浅绿', '深青'];
  static const _gaps = [8, 14, 18, 24, 30];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text('阅读设置',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 18),
            _row('字号',
                children: [
                  for (final s in _sizes)
                    _opt(s.toString(), s == widget.fontSize, () {
                      widget.onFontSize(s);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('行距',
                children: [
                  for (final h in _heights)
                    _opt('${h / 100}', h == widget.lineHeight, () {
                      widget.onLineHeight(h);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('背景',
                children: [
                  for (var i = 0; i < _themeNames.length; i++)
                    _opt(_themeNames[i], i == widget.theme, () {
                      widget.onTheme(i);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('段间距',
                children: [
                  for (final g in _gaps)
                    _opt('$g', g == widget.paragraphGap, () {
                      widget.onParagraphGap(g);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('首行缩进',
                children: [
                  _opt('关', !widget.firstIndent, () {
                    widget.onFirstIndent(false);
                    setState(() {});
                  }),
                  _opt('开（2字符）', widget.firstIndent, () {
                    widget.onFirstIndent(true);
                    setState(() {});
                  }),
                ]),
            const SizedBox(height: 14),
            // 色温无级调节：0 = 无色温，100 = 最暖（约 3000K）。
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('色温',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.85))),
                    const SizedBox(width: 8),
                    Text(
                      widget.colorTemp == 0
                          ? '关闭'
                          : '${(6500 - widget.colorTemp * 35)}K',
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor:
                        Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                    thumbColor: Theme.of(context).colorScheme.primary,
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10),
                  ),
                  child: Slider(
                    value: widget.colorTemp.toDouble(),
                    max: 100,
                    divisions: 20,
                    label: widget.colorTemp == 0
                        ? '关闭'
                        : '${(6500 - widget.colorTemp * 35)}K',
                    onChanged: (v) {
                      widget.onColorTemp(v.round());
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, {required List<Widget> children}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.85))),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: children,
        ),
      ],
    );
  }

  Widget _opt(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}

/// 朗读设置抽屉：语速档位（0.5x ~ 2x）。
class _NovelTtsSheet extends StatelessWidget {
  final int rateIdx;
  final ValueChanged<int> onRate;
  const _NovelTtsSheet({required this.rateIdx, required this.onRate});

  @override
  Widget build(BuildContext context) {
    final rates = NovelTtsService.rates;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text('朗读设置',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 18),
            Row(
              children: [
                Text('语速',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.85))),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < rates.length; i++)
                        _TtsRateChip(
                          label: '${rates[i]}x',
                          active: i == rateIdx,
                          onTap: () => onRate(i),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TtsRateChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TtsRateChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}