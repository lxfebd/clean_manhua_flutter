import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/novel_chapter_cache.dart';
import '../services/novel_tts_service.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../utils/novel_summarizer.dart';
import 'reader_prefs_providers.dart';
import 'responsive.dart';
import 'style_tokens.dart';
import 'widgets/app_toast.dart';

/// 快照构造器：把「章号 + 滚动偏移 + 书目」打包成 HistoryEntry。
/// 抽成纯函数以便单测（无需拉起 Widget tree 就能验证快照语义）。
/// timestamp 由调用方在写盘前补齐，函数里固定为 0。
HistoryEntry snapshotHistoryEntry({
  required String sourceId,
  required String novelId,
  required String novelName,
  required String novelPic,
  required String novelAuthor,
  required String chapterId,
  required String chapterTitle,
  required double scrollOffset,
}) {
  return HistoryEntry(
    book: Bookmark(
      sourceId: sourceId,
      comicId: novelId,
      name: novelName,
      pic: novelPic,
      author: novelAuthor,
    ),
    chapterId: chapterId,
    chapterTitle: chapterTitle,
    timestamp: 0,
    scrollOffset: scrollOffset,
  );
}

/// 滚动位置 → 本章进度（0~1）。纯函数便于单测：
/// - maxScrollExtent <= 0（内容不满一屏）：算读完 1.0；
/// - 否则 offset / maxScrollExtent，夹到 [0,1]。
double chapterProgress(double offset, double maxScrollExtent) {
  if (maxScrollExtent <= 0) return 1.0;
  return (offset / maxScrollExtent).clamp(0.0, 1.0);
}

/// 章节目录「定位到当前章」的目标偏移：让第 idx 项滚到可视区中间偏上
/// （上方留上下文，能看到上一章在滚走的边缘）。每项高按 dense ListTile
/// 约 56px 估算，clamp 到 [0, maxScrollExtent]。纯函数便于单测。
double tocTargetOffset(int idx, double viewport, double maxExtent) {
  final target = idx * 56.0 - viewport * 0.4;
  return target.clamp(0.0, maxExtent);
}

/// 小说阅读器：渲染章节正文（段落列表），支持上下章导航与阅读进度记录。
class NovelReaderPage extends ConsumerStatefulWidget {
  final String sourceId;
  final String novelId;
  final String chapterId;
  final String title;
  final String novelName;
  final String novelPic;
  final String novelAuthor;

  /// 上次读到的滚动偏移（像素）。>0 时打开章节后定位到该位置续读。
  final double initialOffset;

  const NovelReaderPage({
    super.key,
    required this.sourceId,
    required this.novelId,
    required this.chapterId,
    required this.title,
    required this.novelName,
    required this.novelPic,
    required this.novelAuthor,
    this.initialOffset = 0,
  });

  @override
  ConsumerState<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends ConsumerState<NovelReaderPage> {
  NovelContent? _content;
  bool _loading = true;
  String? _error;

  /// 当前章来自本地缓存（网络失败兜底）：顶部提示「缓存数据」而非错误页。
  bool _offlineHint = false;
  String _curChapterId;

  /// 最近一次尝试加载的章（含失败目标）：翻章失败时 `_curChapterId` 仍是
  /// 旧章，错误态「重试」必须重载失败的目标章而不是被拉回上一章。
  String _pendingChapterId;

  // 阅读自定义（经 novelReaderPrefsProvider 读写；下方 getter 供渲染取当前值）
  NovelReaderPrefs get _prefs => ref.read(novelReaderPrefsProvider);
  int get _fontSize => _prefs.fontSize;
  int get _lineHeight => _prefs.lineHeight;
  int get _theme => _prefs.theme;
  int get _paragraphGap => _prefs.paragraphGap;
  bool get _firstIndent => _prefs.firstIndent;
  int get _colorTemp => _prefs.colorTemp;

  final Stopwatch _readWatch = Stopwatch();
  Timer? _statsTimer;
  ScrollController? _listController;
  Timer? _recordHistoryDebounce; // 滚动位置防抖落盘（合并快速滚动为一次写盘）

  /// 本章阅读进度（0~1）：滚动监听里更新，底部进度条经
  /// [ValueListenableBuilder] 局部重建——不触发整页 setState 重建正文。
  final ValueNotifier<double> _chapterProgress = ValueNotifier(0);

  // ---- 朗读（TTS） ----
  final NovelTtsService _tts = NovelTtsService.instance;
  TtsPlayState _ttsState = TtsPlayState.idle;
  int _ttsRateIdx = 2; // NovelTtsService.rates 下标，默认 1.0x
  int _ttsSentence = -1; // 当前朗读中的段落下标（-1 = 未朗读）
  bool _bookmarked = false; // 当前章是否已加书签（B 键/目录可切换）

  static const _themes = [
    (name: '跟随', bg: '0xFF111215', text: '0xFFE8EAF0', isDark: true),
    (name: '米白', bg: '0xFFF5F0E8', text: '0xFF3A342C', isDark: false),
    (name: '浅绿', bg: '0xFFDCE8D4', text: '0xFF2E3A2A', isDark: false),
    (name: '深青', bg: '0xFF10242B', text: '0xFFC8D8DC', isDark: true),
  ];

  _NovelReaderPageState()
      : _curChapterId = '',
        _pendingChapterId = '';

  @override
  void initState() {
    super.initState();
    _curChapterId = widget.chapterId;
    _readWatch.start();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _flushStats());
    _resumePrefs();
    _initTts();
    _load(widget.chapterId);
    _initBookmark();
    // 桌面端键盘：←/→ 翻章、Esc 返回。仅桌面注册，避免移动端蓝牙键盘误触。
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
    }
  }

  /// 首次进入懒载阅读偏好（幂等；provider 内部保证只读盘一次）。
  Future<void> _resumePrefs() async {
    await ref.read(novelReaderPrefsProvider.notifier).resume();
    if (mounted) setState(() {});
  }

  /// 读取当前章书签状态（B 键/目录高亮用）。
  /// 异步查询返回前若已换章，丢弃结果——快速连点翻章时旧章的查询晚
  /// 返回会覆盖新章的正确书签态（按钮高亮错乱）。
  Future<void> _initBookmark() async {
    final chapterId = _curChapterId;
    final marked = await LocalStore.isBookmarked(
        widget.sourceId, widget.novelId, chapterId, 0);
    if (!mounted || _curChapterId != chapterId) return;
    setState(() => _bookmarked = marked);
  }

  /// 书签当前章：复用漫画书签存储（pageIndex 固定 0），书架"书签"栏统一展示。
  Future<void> _toggleBookmark() async {
    if (_content == null) return;
    final b = Bookmark(
      sourceId: widget.sourceId,
      comicId: widget.novelId,
      name: widget.novelName,
      pic: widget.novelPic,
      author: widget.novelAuthor,
    );
    if (_bookmarked) {
      await LocalStore.removeBookmark(
          widget.sourceId, widget.novelId, _curChapterId, 0);
    } else {
      await LocalStore.addBookmark(ComicBookmark(
        book: b,
        chapterId: _curChapterId,
        chapterTitle: _content!.title,
        pageIndex: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    if (!mounted) return;
    setState(() => _bookmarked = !_bookmarked);
    AppToast.info(context, _bookmarked ? '已添加书签' : '已取消书签',
        duration: const Duration(seconds: 1));
  }

  /// 章节目录：拉取全本目录（detail），点选跳章。
  Future<void> _showToc() async {
    final s = SourceManager.novelById(widget.sourceId);
    if (s == null) return;
    // 目录 sheet 里标注已离线缓存的章节（断网时用户无需退出即可辨识）。
    final cached = await NovelChapterCache.cachedChapterIds(
      widget.sourceId,
      widget.novelId,
    );
    if (!mounted) return;
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _TocSheet(
        load: () => s.detail(widget.novelId)
            .timeout(const Duration(seconds: 15)),
        currentChapterId: _curChapterId,
        cachedIds: cached,
        onPick: (id) {
          Navigator.pop(ctx);
          _go(id);
        },
      ),
    );
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
    _tts.onError = () {
      if (!mounted) return;
      setState(() => _ttsState = TtsPlayState.idle);
      AppToast.error(context, '朗读失败：未找到可用的语音引擎');
    };
    await _tts.init(rate: NovelTtsService.rates[_ttsRateIdx]);
  }

  @override
  void dispose() {
    // 只做会话级清理：NovelTtsService 是全局单例，dispose() 会置 _disposed
    // 使本次会话内朗读功能永久失效。退出阅读器只需停止并复位当前会话，
    // 保持引擎可再次 init/play。
    _tts.reset();
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.removeHandler(_keyHandler);
    }
    _statsTimer?.cancel();
    _recordHistoryDebounce?.cancel();
    _chapterProgress.dispose();
    // ScrollController dispose：detach 所有 scroll position，避免页面退出后
    // listener 闭包（引用本 State）被 controller/position 长期持有。
    _listController?.dispose();
    _listController = null;
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

  Future<void> _load(String chapterId) async {
    // 先记 pending（含失败目标）：翻章失败后错误态「重试」重载此章。
    _pendingChapterId = chapterId;
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
    // 新章加载中进度条回零（旧章残留值先清掉，加载完成前显示空条）。
    _chapterProgress.value = 0;
    // 复用同一 controller：翻章时已由 _go 跳回顶部，卸载不清除以便重建 Focus。
    // 首次创建时挂滚动监听：活动中持续记录进度（防抖），退出后可按偏移续读。
    _listController ??= ScrollController()
      ..addListener(() {
        _updateProgress();
        if (_loading || _content == null) return;
        _recordHistory(_content!.title);
      });
    try {
      final c = await s.chapterContent(chapterId).timeout(const Duration(seconds: 15));
      // 成功事件用 debug 级，不写 ERROR 日志（避免污染 7 天滚动日志与错误计数）。
      ErrorLogger.instance.debug('[novel-reader] chapterContent OK id=$chapterId title=${c.title} paras=${c.paragraphs.length} prev=${c.prevChapterId != null} next=${c.nextChapterId != null}');
      // 写盘缓存：断网/源失效时离线兜底。静默失败（写盘错误不影响本次阅读）。
      if (mounted) {
        unawaited(NovelChapterCache.write(
          widget.sourceId,
          widget.novelId,
          chapterId,
          c,
        ));
      }
      if (mounted) {
        _content = c;
        _curChapterId = chapterId;
        _error = null;
        _offlineHint = false;
        _autoNextFired = false; // 新章重置「章末自动加载」标记
        _recordHistory(c.title);
        // 换章后刷新朗读队列：内容加载期间朗读自然停在旧章末尾。
        _tts.reset();
        _tts.loadChapter(c.paragraphs);
        // 换章后刷新书签状态（B 键/目录高亮跟随当前章）。
        _initBookmark();
        // 首次打开（从详情页进入）且有历史偏移：布局完成后定位到上次位置续读。
        // 注意 _go(prev/next) 传入的是空偏移（0），不会触发恢复逻辑。
        if (widget.initialOffset > 0 &&
            chapterId == widget.chapterId &&
            _listController != null) {
          final target = widget.initialOffset;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final sc = _listController;
            if (sc == null || !sc.hasClients) return;
            sc.jumpTo(target.clamp(0, sc.position.maxScrollExtent));
            _updateProgress(); // 续读定位后同步进度条
          });
        }
        // 短章（内容不满一屏）不会触发滚动事件：布局完成后主动刷新
        // 一次进度，避免进度条停在 0%（应显示读完）。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _updateProgress();
        });
      }
    } catch (e) {
      ErrorLogger.instance.logError('[novel-reader] FAIL id=$chapterId err=$e');
      // 网络失败回退：尝试本地缓存（离线阅读）。缓存章节不置 error 态，
      // 正常渲染但顶部提示「缓存数据，可能非最新」，与 _error 互斥。
      final cached = await NovelChapterCache.read(
        widget.sourceId,
        widget.novelId,
        chapterId,
      );
      if (mounted && cached != null) {
        _content = cached;
        _curChapterId = chapterId;
        _error = null;
        _offlineHint = true;
        _autoNextFired = false;
        _tts.reset();
        _tts.loadChapter(cached.paragraphs);
        _initBookmark();
      } else if (mounted) {
        _error = '章节加载失败，请重试';
        _offlineHint = false;
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 滚动位置 → 本章进度（0~1）。内容不满一屏时算读完（1.0）。
  void _updateProgress() {
    final sc = _listController;
    if (sc == null || !sc.hasClients) {
      _chapterProgress.value = 0.0;
      return;
    }
    _chapterProgress.value = chapterProgress(
      sc.offset,
      sc.position.maxScrollExtent,
    );
  }

  /// 用 [snapshotHistoryEntry]（文件顶部纯函数）构造 HistoryEntry 并写盘。
  /// 快照在 Timer 建立时刻抓取（立即读 `_curChapterId` 与 `_listController.offset`），
  /// 500ms 防抖回调只写快照，不再读 live 状态——
  /// 若期间 `_go` 已 `jumpTo(0)` 清偏移或切到新章，旧章续读位置依然保留。
  void _recordHistory(String chapterTitle) {
    final chapterId = _curChapterId;
    final scrollOffset = (_listController?.hasClients ?? false)
        ? _listController!.offset.toDouble()
        : 0.0;
    _recordHistoryDebounce?.cancel();
    _recordHistoryDebounce = Timer(const Duration(milliseconds: 500), () {
      final entry = snapshotHistoryEntry(
        sourceId: widget.sourceId,
        novelId: widget.novelId,
        novelName: widget.novelName,
        novelPic: widget.novelPic,
        novelAuthor: widget.novelAuthor,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        scrollOffset: scrollOffset,
      );
      // 时间戳在写盘时确定，快照里留的 0 会被覆盖。
      LocalStore.recordHistory(HistoryEntry(
        book: entry.book,
        chapterId: entry.chapterId,
        chapterTitle: entry.chapterTitle,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        scrollOffset: entry.scrollOffset,
      ));
    });
  }

  void _go(String? chapterId) {
    if (chapterId == null) return;
    if (chapterId == _curChapterId) return; // 同章重复点击（含快速连点）
    if (_loading) return; // 切章加载中忽略重复点击，防并发请求
    HapticFeedback.lightImpact();
    // 换章前落盘当前章进度（防抖计时器未触发就切走的情况）：
    // `_recordHistory` 会立即抓 (章号 + 偏移) 快照，500ms 防抖回调只写快照，
    // 不再读 live 状态——即使下面 jumpTo(0) 把 offset 清 0、新章异步加载
    // 覆盖 _curChapterId，旧章续读位置也不会被冲掉。
    if (_content != null) _recordHistory(_content!.title);
    // 同步置 loading：让 jumpTo(0) 触发的滚动监听跳过落盘，
    // 避免把旧章位置覆盖成偏移 0（_load 里 setState 幂等）。
    _loading = true;
    // 翻章时新章节从顶部开始读。
    if (_listController != null && _listController!.hasClients) {
      _listController!.jumpTo(0);
    }
    _load(chapterId);
  }

  /// 桌面端键盘：←/→ 翻章、Esc 返回、B 书签、G 目录、S 设置、
  /// T 朗读、+/- 字号。
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
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyB:
        _toggleBookmark();
        return true;
      case LogicalKeyboardKey.keyG:
        _showToc();
        return true;
      case LogicalKeyboardKey.keyS:
        _showSettings();
        return true;
      case LogicalKeyboardKey.keyT:
        _ttsToggle();
        return true;
      case LogicalKeyboardKey.equal:
      case LogicalKeyboardKey.numpadAdd:
        _adjustFontSize(1);
        return true;
      case LogicalKeyboardKey.minus:
      case LogicalKeyboardKey.numpadSubtract:
        _adjustFontSize(-1);
        return true;
    }
    // PageUp/PageDown/空格 滚动正文（移动到 ListView 滚动事件处理）。
    return false;
  }

  /// 键盘 +/- 字号。
  void _adjustFontSize(int dir) {
    final v = (_fontSize + dir).clamp(13, 28);
    if (v == _fontSize) return;
    ref.read(novelReaderPrefsProvider.notifier).update(fontSize: v);
  }

  /// 本章摘要：当前章正文本地纯规则生成（无网络、无模型依赖）。
  Future<void> _showSummary() {
    final content = _content;
    if (content == null) return Future.value();
    final sentences =
        NovelSummarizer.summarize(content.paragraphs, maxSentences: 4);
    return showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SummarySheet(
        title: content.title,
        sentences: sentences,
      ),
    );
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
          await ref.read(novelReaderPrefsProvider.notifier).update(fontSize: v);
        },
        onLineHeight: (v) async {
          await ref.read(novelReaderPrefsProvider.notifier).update(lineHeight: v);
        },
        onTheme: (v) async {
          await ref.read(novelReaderPrefsProvider.notifier).update(theme: v);
        },
        onParagraphGap: (v) async {
          await ref.read(novelReaderPrefsProvider.notifier).update(paragraphGap: v);
        },
        onFirstIndent: (v) async {
          await ref.read(novelReaderPrefsProvider.notifier).update(firstIndent: v);
        },
        onColorTemp: (v) async {
          await ref.read(novelReaderPrefsProvider.notifier).update(colorTemp: v);
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
    // watch 偏好：update 写回后本页即时重建（getter 用 ref.read 读当前值）。
    ref.watch(novelReaderPrefsProvider);
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
          if (_content != null)
            IconButton(
              tooltip: '本章摘要',
              icon: const Icon(Icons.auto_awesome_rounded, size: 20),
              onPressed: _showSummary,
            ),
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
        fit: StackFit.expand,
        children: [
          // 离线缓存提示条：网络失败但命中本地缓存时显示（非错误态）。
          if (_offlineHint)
            Align(
              alignment: Alignment.topCenter,
              child: SafeArea(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '缓存数据，可能非最新',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          _loading
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(strokeWidth: 2),
                      const SizedBox(height: 14),
                      Text(_content != null ? '正在加载下一章…' : '正在加载…',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurface.withValues(alpha: 0.5))),
                    ],
                  ),
                )
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
                                // 重载失败的目标章（翻章失败时 _curChapterId
                                // 仍停在旧章，用 pending 才不会被拉回上一章）。
                                _load(_pendingChapterId);
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 本章阅读进度：细进度线 + 百分比。仅进度条局部重建，
                        // 滚动时不会连带重建按钮行/正文。
                        ValueListenableBuilder<double>(
                          valueListenable: _chapterProgress,
                          builder: (_, p, __) {
                            final pct = (p * 100).round();
                            return Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(1),
                                    child: LinearProgressIndicator(
                                      value: p,
                                      minHeight: 2,
                                      backgroundColor:
                                          scheme.onSurface.withValues(alpha: 0.1),
                                      color: _colorTemp > 0
                                          ? const Color(0xFFE8A87C)
                                          : scheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '$pct%',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: scheme.onSurface.withValues(alpha: 0.5),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 6),
                        Row(
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
                            // 首章禁用上一章：避免「点了没反应」。
                            onPressed: _content?.prevChapterId != null
                                ? () => _go(_content!.prevChapterId)
                                : null,
                            child: const Text('上一章'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            // 末章禁用下一章：无下章时置灰而非空响应。
                            onPressed: _content?.nextChapterId != null
                                ? () => _go(_content!.nextChapterId)
                                : null,
                            child: const Text('下一章'),
                          ),
                        ),
                      ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
    );
  }

  /// 防止「章末自动加载」在一次滚动中重复触发：滚到章末已自动加载过
  /// 标记 true，换章（_load 成功）后重置为 false；加载下一章中也为 true。
  bool _autoNextFired = false;
  /// 章末自动加载下一章（到达底部且还有下一章时静默触发）。
  void _maybeAutoNext(ScrollMetrics m) {
    if (_autoNextFired) return;
    if (_loading) return;
    final nextId = _content?.nextChapterId;
    if (nextId == null) return; // 无下一章
    final trigger = m.maxScrollExtent - m.pixels;
    if (trigger > m.viewportDimension * 0.25) return; // 还没到章末附近
    _autoNextFired = true;
    _go(nextId); // _load 成功后重置 _autoNextFired
  }

  Widget _reader(scheme) {
    final paras = _content!.paragraphs;
    final useCustomBg = _theme > 0;
    final textColor = useCustomBg
        ? Color(int.parse(_themes[_theme.clamp(0, _themes.length - 1)].text))
        : scheme.onSurface.withValues(alpha: 0.92);

    final isSpeaking = _ttsState != TtsPlayState.idle && _ttsSentence >= 0;
    Widget para(int i) => GestureDetector(
          // 点段落即从该段开始朗读：听书时跳读/校准位置的高频操作
          // （读岔了不用从头，点目标段直接续）。朗读中同段点击无效。
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_ttsState == TtsPlayState.idle) return;
            if (i == _ttsSentence && _ttsState != TtsPlayState.paused) return;
            _tts.seekTo(i);
            if (_ttsState == TtsPlayState.paused) _tts.play();
          },
          child: Text(
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
        ),
        );

    // 单一 ListView：挂 _listController（翻章回顶、桌面键滚动都依赖它），
    // 段间距独立可调（不再跟行距耦合）。
    Widget list = NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        _maybeAutoNext(n.metrics);
        return false;
      },
      child: ListView.separated(
        controller: _listController,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        itemCount: paras.length,
        separatorBuilder: (_, __) =>
            SizedBox(height: _paragraphGap.toDouble()),
        itemBuilder: (ctx, i) => para(i),
      ),
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('阅读设置',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface)),
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
                    inactiveTrackColor: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.15),
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
      borderRadius: BorderRadius.circular(
          StyleTokens.controlRadiusOr(context, 8)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(
              StyleTokens.controlRadiusOr(context, 8)),
          border: Border.all(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('朗读设置',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface)),
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
              : Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
/// 本章摘要底部面板：标题 + 摘要句列表 + 免责说明。
class _SummarySheet extends StatelessWidget {
  final String title;
  final List<String> sentences;

  const _SummarySheet({required this.title, required this.sentences});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('本章摘要',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
                const Spacer(),
                Text('本地生成',
                    style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withValues(alpha: 0.45))),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 14),
            if (sentences.isEmpty)
              Text('本章暂无内容可摘要',
                  style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.6)))
            else
              for (var i = 0; i < sentences.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary),
                      ),
                      Expanded(
                        child: Text(
                          sentences[i],
                          style: TextStyle(
                              fontSize: 13.5,
                              height: 1.55,
                              color: scheme.onSurface.withValues(alpha: 0.85)),
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 6),
            Text(
              '摘要由本地算法生成，仅作快速回顾参考。',
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.4)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 章节目录底部弹窗：加载中/失败重试/列表三态。
class _TocSheet extends StatefulWidget {
  final Future<NovelDetail> Function() load;
  final String currentChapterId;

  /// 已离线缓存的章节 id 集合（打开目录时快照；断网标记用）。
  final Set<String> cachedIds;
  final ValueChanged<String> onPick;

  const _TocSheet({
    required this.load,
    required this.currentChapterId,
    required this.cachedIds,
    required this.onPick,
  });

  @override
  State<_TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<_TocSheet> {
  List<NovelChapter>? _chapters;
  bool _failed = false;
  final ScrollController _ctrl = ScrollController();
  final TextEditingController _filterCtrl = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  /// 过滤后的可见章节（标题模糊匹配；空 = 全量）。
  List<NovelChapter> get _visible {
    final all = _chapters;
    if (all == null) return const [];
    final f = _filter.trim().toLowerCase();
    if (f.isEmpty) return all;
    return [
      for (final c in all)
        if (c.title.toLowerCase().contains(f)) c,
    ];
  }

  Future<void> _fetch() async {
    setState(() {
      _chapters = null;
      _failed = false;
    });
    try {
      final d = await widget.load();
      if (mounted) setState(() => _chapters = d.chapters);
      if (mounted) _scrollToCurrent();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 目录加载后定位到当前章：长篇（几十上百章）打开目录时当前章可能
  /// 在屏幕外，高亮章需要自动滚进可视区。post-frame 等 ListView 挂载。
  void _scrollToCurrent() {
    final chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final idx = chapters.indexWhere((c) => c.id == widget.currentChapterId);
    if (idx < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      // 定位到可视区中间偏上，四周留上下文（当前章上下各约 2 屏）。
      final target = tocTargetOffset(
        idx,
        MediaQuery.of(context).size.height,
        _ctrl.position.maxScrollExtent,
      );
      _ctrl.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: [
                Text('章节目录', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    final chapters = _chapters;
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 38, color: scheme.onSurface.withValues(alpha: 0.35)),
            const SizedBox(height: 10),
            const Text('目录加载失败，请重试'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _fetch,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (chapters == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (chapters.isEmpty) {
      return const Center(child: Text('暂无目录'));
    }
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: TextField(
            controller: _filterCtrl,
            onChanged: (v) => setState(() => _filter = v),
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索章节标题',
              hintStyle: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
              suffixIcon: _filter.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () {
                        _filterCtrl.clear();
                        setState(() => _filter = '');
                      },
                    ),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    '没有匹配「$_filter」的章节',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _ctrl,
                  itemCount: visible.length,
                  itemBuilder: (ctx, i) {
                    final ch = visible[i];
                    final cur = ch.id == widget.currentChapterId;
                    final cached = widget.cachedIds.contains(ch.id);
                    return ListTile(
                      dense: true,
                      selected: cur,
                      title: Text(
                        ch.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: cur ? Theme.of(ctx).colorScheme.primary : null,
                        ),
                      ),
                      // 已缓存章节标注离线小图标（断网可读），当前章高亮优先。
                      trailing: cur
                          ? null
                          : cached
                              ? Icon(
                                  Icons.offline_pin_rounded,
                                  size: 15,
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.6),
                                )
                              : null,
                      onTap: () => widget.onPick(ch.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
