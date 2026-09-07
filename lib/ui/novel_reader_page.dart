import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/local_store.dart';
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

  final Stopwatch _readWatch = Stopwatch();
  Timer? _statsTimer;
  ScrollController? _listController;

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
    _load(widget.chapterId);
    // 桌面端键盘：←/→ 翻章、Esc 返回。仅桌面注册，避免移动端蓝牙键盘误触。
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
    }
  }

  @override
  void dispose() {
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
    if (mounted) {
      setState(() {
        _fontSize = fs;
        _lineHeight = lh;
        _theme = th;
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
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_error!,
                          style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.6))),
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
    // 桌面端：包裹 Focus + 键盘滚动，使空格/PageUp/PageDown 可直接滚动正文；
    // 仅在桌面启用，移动端物理键盘不影响触摸滚动。
    Widget list = ListView.separated(
      controller: _listController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: paras.length,
      separatorBuilder: (_, __) =>
          SizedBox(height: (_lineHeight / 100 * 10).clamp(6.0, 20.0)),
      itemBuilder: (ctx, i) => Text(
        paras[i],
        textAlign: TextAlign.justify,
        style: TextStyle(
          fontSize: _fontSize.toDouble(),
          height: _lineHeight / 100,
          color: textColor,
        ),
      ),
    );
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
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            itemCount: paras.length,
            separatorBuilder: (_, __) =>
                SizedBox(height: (_lineHeight / 100 * 10).clamp(6.0, 20.0)),
            itemBuilder: (ctx, i) => Text(
              paras[i],
              textAlign: TextAlign.justify,
              style: TextStyle(
                fontSize: _fontSize.toDouble(),
                height: _lineHeight / 100,
                color: textColor,
              ),
            ),
          ),
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
  final ValueChanged<int> onFontSize;
  final ValueChanged<int> onLineHeight;
  final ValueChanged<int> onTheme;
  const _NovelReaderSettingsSheet({
    required this.fontSize,
    required this.lineHeight,
    required this.theme,
    required this.onFontSize,
    required this.onLineHeight,
    required this.onTheme,
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