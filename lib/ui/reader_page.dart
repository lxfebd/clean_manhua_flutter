import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../net/download_manager.dart';
import '../net/http_client.dart';
import '../net/image_cache.dart';
import '../net/jm_scramble.dart';
import '../net/local_store.dart';
import 'responsive.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import '../utils/image_super_res.dart';
import 'widgets/jm_scramble_image.dart';

/// 阅读器（对齐 UI_v2 S5/S6）：沉浸式黑底 + 顶部返回/标题/菜单 +
/// 底部悬浮玻璃工具栏（亮度/目录/翻页模式/下载）+ 底部居中页码。
class ReaderPage extends StatefulWidget {
  final String sourceId;
  final String comicId;
  final String chapterId;
  final String title;
  final String comicName;
  final String comicPic;
  final String comicAuthor;

  /// 全作品章节列表（用于章内切换/沉浸式连读下一话）。空则不启用连读。
  final List<Chapter> chapters;

  /// 上次读到的页码（-1 表示从第一页开始）。
  final int initialPage;

  const ReaderPage({
    super.key,
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.title,
    required this.comicName,
    required this.comicPic,
    this.comicAuthor = '',
    this.chapters = const [],
    this.initialPage = -1,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  List<String> _urls = [];
  bool _loading = true;
  bool _horizontal = false;
  bool _rtl = false; // 日漫 RTL 反向翻页（手势左右交换）
  bool _downloaded = false;
  bool _downloading = false;
  int _curPage = 0;
  int _resLevel = 0; // 0=无, 1=性能, 2=质量
  bool _overlay = true; // 顶部/底部工具栏是否显示
  double _dim = 1.0; // 亮度（1.0=最亮），真实接管系统亮度
  bool _brightnessNative = false; // 是否已接管系统亮度（false 时降级为遮罩）
  Timer? _hideTimer;
  int _autoPage = 0; // 自动翻页间隔（秒），0 = 关闭
  Timer? _autoPageTimer;

  /// 章节图片列表缓存：key=chapterId，已加载/预取的章节直接用，避免连读重复拉取。
  final Map<String, List<String>> _chapterPicCache = {};

  /// 阅读时长统计：累计本次阅读秒数，每 5s flush 一次。
  final Stopwatch _readWatch = Stopwatch();
  Timer? _statsTimer;

  /// 手势配置：left/center/right → 动作字符串。
  Map<String, String> _gesture = const {};

  /// 当前章节索引（-1 表示不在章节列表中，不启用连读）。
  late int _chapterIndex;

  /// 防误触：触摸锁、动画锁、二次返回退出
  bool _touchLocked = false; // 用户主动锁定触控（躺卧阅读）
  bool _pageAnimating = false; // 翻页动画进行中
  DateTime _lastTouchTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastTouchPos;
  // 手动双击检测（不依赖 GestureDetector.onDoubleTap，因与子组件手势竞技场冲突）
  DateTime _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastTapPos;
  // 双击阈值：时间 500ms（比系统 kDoubleTapTimeout=300ms 更宽容，适配低端机），
  // 距离 64px（系统 kDoubleTapSlop 物理像素，适配 DPI）。
  static const int _doubleTapMs = 500;
  static const double _doubleTapDist = 64.0;
  // 滑动检测：事件驱动（Completer），不再用静态轮询。
  // 多个 ReaderPage 实例并存（分屏/画中画）时共享该状态，滑动等待超分
  // 只是推迟一点执行，行为仍是安全的。
  static Completer<void>? _scrollEndCompleter;
  Timer? _scrollEndTimer;
  Timer? _historyDebounce;

  /// 当前加载的章节 id 与页数（记录历史用）。
  String _activeChapterId = '';
  String _activeChapterTitle = '';
  int _activeTotalPages = 0;
  Bookmark get _book => Bookmark(
        sourceId: widget.sourceId,
        comicId: widget.comicId,
        name: widget.comicName,
        pic: widget.comicPic,
        author: widget.comicAuthor,
      );

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // 阅读时保持屏幕常亮
    _initBrightness(); // 接管系统亮度
    _chapterIndex =
        widget.chapters.indexWhere((c) => c.id == widget.chapterId);
    _activeChapterId = widget.chapterId;
    _activeChapterTitle = widget.title;
    _readWatch.start();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _flushStats());
    LocalStore.gestureConfig().then((g) {
      if (mounted) setState(() => _gesture = g);
    });
    _init();
  }

  Future<void> _init() async {
    _horizontal = await LocalStore.horizontalReader();
    _rtl = await LocalStore.rtlReader();
    _resLevel = await LocalStore.resLevel();
    _autoPage = await LocalStore.autoPageTurn();
    _downloaded = await DownloadManager.isDownloaded(_book.key, widget.chapterId);
    _load();
  }

  /// 读取/切换到一个章节（用于章内切章节 / 沉浸式连读）。
  Future<void> _openChapter(String chapterId, String chapterTitle,
      {int startPage = 0}) async {
    _hideTimer?.cancel();
    if (mounted) {
      setState(() {
        _loading = true;
        _activeChapterId = chapterId;
        _activeChapterTitle = chapterTitle;
      });
    }
    try {
      final urls = await _chapterUrls(chapterId);
      final downloaded = await DownloadManager.isDownloaded(_book.key, chapterId);
      if (downloaded) {
        final local = <String>[];
        for (var i = 0; i < urls.length; i++) {
          final p = await DownloadManager.localUrlIfExists(
              _book.key, chapterId, i);
          local.add(p ?? urls[i]);
        }
        urls
          ..clear()
          ..addAll(local);
      }
      if (!mounted) return;
      final target = startPage.clamp(0, urls.length - 1);
      setState(() {
        _urls = urls;
        _activeTotalPages = urls.length;
        _downloaded = downloaded;
        _loading = false;
        if (_horizontal) {
          if (_pageCtrl != null) _pageCtrl!.jumpToPage(target);
        } else if (_scrollCtrl != null && _scrollCtrl!.hasClients) {
          final offset = _indexOffsetCache[target] ?? 0.0;
          _scrollCtrl!.jumpTo(offset);
        }
        _curPage = target;
      });
      // 切章节后重新记录历史（页码以 target 为准）
      _recordHistory(chapterTitle: chapterTitle);
      _prefetch(target);
      _prefetchNextChapter();
      _startAutoPage();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 获取章节图片列表：优先用缓存（连读/重复打开免网络请求）。
  Future<List<String>> _chapterUrls(String chapterId) async {
    final cached = _chapterPicCache[chapterId];
    if (cached != null) return cached;
    final urls =
        await SourceManager.byId(widget.sourceId).chapterPics(chapterId);
    _chapterPicCache[chapterId] = urls;
    return urls;
  }

  /// 沉浸式连读加速：预先拉取下一话的图片列表并预取前 2 页，连读时秒开。
  Future<void> _prefetchNextChapter() async {
    if (!_canContinue) return;
    final next = widget.chapters[_chapterIndex + 1];
    if (_chapterPicCache.containsKey(next.id)) return;
    try {
      final urls = await _chapterUrls(next.id);
      // 预取下一话前 2 页图片字节（与 _prefetch 一致处理 JM 解扰）
      for (var i = 0; i < 2 && i < urls.length; i++) {
        final u = urls[i];
        if (u.startsWith('/')) continue;
        if (u.contains('@') || widget.sourceId == 'jm') {
          ImageCacheManager.load(u, fetch: () async {
            final split = JmScramble.splitUrl(u);
            final referer = _jmReferer(split.url);
            var raw = Uint8List.fromList(await Net.getBytesCronet(
              split.url,
              headers: {
                'User-Agent': Net.defaultUA,
                'Referer': referer,
                'Accept': 'image/webp,image/*,*/*',
              },
            ));
            if (JmScramble.parseAid(u) != null) {
              raw = await JmScramble.descrambleAsync(raw, u);
            }
            return raw;
          });
        } else {
          ImageCacheManager.preload(u, headers: _headersForUrl(u));
        }
      }
    } catch (_) {}
  }

  /// 自动翻页：按间隔定时翻页。每次用户触摸/切章都会重置计时。
  void _startAutoPage() {
    _autoPageTimer?.cancel();
    if (_autoPage <= 0) return;
    _autoPageTimer = Timer.periodic(Duration(seconds: _autoPage), (_) {
      if (!mounted || _loading || _pageAnimating) return;
      if (_overlay || _touchLocked) return; // 工具栏/触控锁定中不自动翻页
      _nextPage();
    });
  }

  void _stopAutoPage() {
    _autoPageTimer?.cancel();
    _autoPageTimer = null;
  }

  /// 记录历史（含页码）。翻页时也会调用以持续更新进度。
  /// 防抖 500ms：快速翻页时合并多次写入为一次磁盘 IO。
  void _recordHistory({String? chapterTitle}) {
    _historyDebounce?.cancel();
    _historyDebounce = Timer(const Duration(milliseconds: 500), () {
      LocalStore.recordHistory(HistoryEntry(
        book: _book,
        chapterId: _activeChapterId,
        chapterTitle: chapterTitle ?? widget.title,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        pageIndex: _curPage,
        chapterTotalPages: _activeTotalPages,
      ));
    });
  }

  Future<void> _load() async {
    try {
      final urls = await _chapterUrls(widget.chapterId);
      if (_downloaded) {
        final local = <String>[];
        for (var i = 0; i < urls.length; i++) {
          final p = await DownloadManager.localUrlIfExists(
              _book.key, widget.chapterId, i);
          local.add(p ?? urls[i]);
        }
        urls
          ..clear()
          ..addAll(local);
      }
      if (mounted) {
        setState(() {
          _urls = urls;
          _activeTotalPages = urls.length;
          _activeChapterId = widget.chapterId;
          _loading = false;
        });
      }
      // 若续读指定了页码，跳到该页
      if (widget.initialPage >= 0 && widget.initialPage < _urls.length) {
        setState(() => _curPage = widget.initialPage);
        _prefetch(widget.initialPage);
      } else {
        _prefetch(0);
      }
      _prefetchNextChapter();
      _startAutoPage();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 预取后续 3 页字节到缓存（本地已下载 / JM 解扰图跳过）。
  /// 注意：headers 必须与 _ImageView 一致（部分 CDN 无 Referer 返回 404，
  /// 若 preload 用无头请求启动 in-flight，后续正式加载会复用该失败 future）。
  void _prefetch(int from) {
    for (var k = from; k < from + 3 && k < _urls.length; k++) {
      final u = _urls[k];
      if (u.startsWith('/')) continue;
      if (u.contains('@') || widget.sourceId == 'jm') {
        ImageCacheManager.load(u, fetch: () async {
          final split = JmScramble.splitUrl(u);
          final referer = _jmReferer(split.url);
          var raw = Uint8List.fromList(await Net.getBytesCronet(
            split.url,
            headers: {
              'User-Agent': Net.defaultUA,
              'Referer': referer,
              'Accept': 'image/webp,image/*,*/*',
            },
          ));
          if (JmScramble.parseAid(u) != null) {
            raw = await JmScramble.descrambleAsync(raw, u);
          }
          return raw;
        });
      } else {
        ImageCacheManager.preload(u, headers: _headersForUrl(u));
      }
    }
  }

  String _jmReferer(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}/';
    } catch (_) {
      return 'https://www.18comic.vg/';
    }
  }

  /// 部分图源 CDN 需要 Referer 头才返回图片（如 dm5 的 cdndm5.com），
  /// 否则返回 403/404 导致「图片加载失败」。
  static Map<String, String>? _headersForUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.contains('cdndm5.com')) {
      // 从 URL 的 cid 参数还原章节页作为 Referer（CDN 校验 Referer 路径）
      final cid = Uri.tryParse(url)?.queryParameters['cid'] ?? '';
      return {
        'Referer': cid.isNotEmpty
            ? 'https://m.dm5.com/m$cid/'
            : 'https://m.dm5.com/'
      };
    }
    if (host.contains('doubaomanhua.com') || host.contains('bzcdn')) {
      return {'Referer': 'https://www.doubaomanhua.com/'};
    }
    return null;
  }

  int _downloadDone = 0;
  int _downloadTotal = 0;

  Future<void> _download() async {
    if (_downloading || _urls.isEmpty) return;
    setState(() => _downloading = true);
    try {
      final ok = await DownloadManager.downloadChapter(
        book: _book,
        chapterId: _activeChapterId,
        chapterTitle: _activeChapterTitle,
        urls: _urls,
        onProgress: (d, t) {
          if (!mounted) return;
          _downloadDone = d;
          _downloadTotal = t;
        },
      );
      if (mounted) {
        setState(() => _downloaded = ok);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? '已下载到本地' : '下载未完成')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 去掉防误触二次返回：直接返回上一集/退出，避免多次按返回无效影响使用。
      canPop: true,
      child: Scaffold(
      backgroundColor: Colors.black,
      // 注意：Scaffold body 给的是宽松约束，Stack 会按非 positioned 子节点
      // （顶部栏）收缩到极矮，导致 ListView 只有顶部一条、底部工具栏跑到顶部。
      // 用 SizedBox.expand 强制 Stack 铺满全屏。
      body: SizedBox.expand(
        child: Stack(
          children: [
          Positioned.fill(child: _buildBody()),
          // 亮度遮罩层（仅降级模式：桌面端/无权限时，用黑纱模拟亮度）
          if (!_brightnessNative)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: (1.0 - _dim) * 0.75,
              child: const ColoredBox(color: Colors.black),
            ),
          // 顶部工具栏（返回/标题/菜单）
          _ReaderTopBar(
            visible: _overlay,
            title: _activeChapterTitle,
            onBack: () {
              HapticFeedback.selectionClick();
              Navigator.maybePop(context);
            },
            onMenu: () => _showReaderSettings(),
          ),
          // 底部页码（横向翻页时显示 x / N，纵向整体显示 N 页）
          _ReaderPageIndicator(
            visible: _overlay && _horizontal,
            label: _downloading && _downloadTotal > 0
                ? '下载 $_downloadDone/$_downloadTotal'
                : '${_curPage + 1} / ${_urls.length}',
          ),
          // 底部悬浮玻璃工具栏
          _ReaderToolbar(
            visible: _overlay,
            downloaded: _downloaded,
            horizontal: _horizontal,
            onBrightness: () => _showReaderSettings(),
            onCatalog: () => _showCatalog(),
            onLayout: () {
              setState(() => _horizontal = !_horizontal);
              LocalStore.setHorizontalReader(_horizontal);
            },
            onDownload: _downloading ? null : _download,
          ),
        ],
        ),
      ),
    ),
    );
  }

  /// 点击页面切换工具栏显隐，显示后 3s 自动隐藏。
  void _toggleOverlay() {
    _hideTimer?.cancel();
    if (_overlay) {
      setState(() => _overlay = false);
      return;
    }
    setState(() => _overlay = true);
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  /// 阅读设置底部抽屉：亮度、夜间模式、翻页模式（对齐 S6）。
  void _showReaderSettings() {
    _hideTimer?.cancel();
    setState(() => _overlay = true);
    showResponsiveBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black.withValues(alpha: 0.6),
      barrierColor: Colors.transparent,
      builder: (_) => _ReaderSettingsSheet(
        horizontal: _horizontal,
        dim: _dim,
        resLevel: _resLevel,
        autoPage: _autoPage,
        onDimChanged: (v) {
          _setBrightness(v);
        },
        onLayoutChanged: (h) {
          setState(() => _horizontal = h);
          LocalStore.setHorizontalReader(h);
        },
        onResLevelChanged: (v) {
          setState(() => _resLevel = v);
          LocalStore.setResLevel(v);
        },
        onAutoPageChanged: (v) {
          setState(() => _autoPage = v);
          LocalStore.setAutoPageTurn(v);
          _startAutoPage();
        },
        onCatalog: () {
          Navigator.pop(context);
          _showCatalog();
        },
        onSelectChapter: widget.chapters.isEmpty
            ? null
            : () {
                Navigator.pop(context);
                _showChapterList();
              },
        onDownload: _downloading
            ? null
            : () {
                Navigator.pop(context);
                _download();
              },
      ),
    ).whenComplete(() {
      if (mounted) _toggleOverlay();
    });
  }

  /// 种内章节切换：展示全作品章节列表底部弹窗。
  void _showChapterList() {
    _hideTimer?.cancel();
    setState(() => _overlay = true);
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChapterListSheet(
        chapters: widget.chapters,
        currentIndex: _chapterIndex,
        onSelect: (i) {
          Navigator.pop(context);
          final ch = widget.chapters[i];
          _chapterIndex = i;
          _indexOffsetCache.clear();
          _layoutHeights.clear();
          _openChapter(ch.id, ch.title);
        },
      ),
    );
  }

  /// 目录：章节内页目录（横向翻页时切换页面）。
  void _showCatalog() {
    _hideTimer?.cancel();
    setState(() => _overlay = true);
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CatalogSheet(
        urls: _urls,
        current: _curPage,
        horizontal: _horizontal,
        onSelect: (i) {
          Navigator.pop(context);
          setState(() => _curPage = i);
          if (_horizontal && _pageCtrl != null) {
            _pageCtrl!.jumpToPage(i);
          } else {
            _scrollToIndex(i);
          }
          _toggleOverlay();
        },
      ),
    );
  }

  PageController? _pageCtrl;
  ScrollController? _scrollCtrl;

  /// 接管系统亮度：读取当前值，进入阅读器后亮度条真实控制系统亮度。
  /// 桌面端/无权限时降级为遮罩（与播放器一致）。
  Future<void> _initBrightness() async {
    try {
      final v = await ScreenBrightness.instance.application;
      if (v >= 0 && v <= 1.0) {
        _brightnessNative = true;
        _dim = v;
      }
    } catch (_) {
      _brightnessNative = false;
    }
    if (mounted) setState(() {});
  }

  /// 设置亮度：真实调系统 API，失败则降级为遮罩。
  void _setBrightness(double v) {
    final nv = v.clamp(0.05, 1.0);
    setState(() => _dim = nv);
    if (!_brightnessNative) return; // 遮罩降级
    try {
      ScreenBrightness.instance.setApplicationScreenBrightness(nv);
    } catch (_) {
      _brightnessNative = false;
    }
  }

  /// 纵向模式下记录每页累积偏移（用于精确跳页，替代固定 560 魔数）。
  final Map<int, double> _indexOffsetCache = {};
  final Map<int, double> _layoutHeights = {};

  void _scrollToIndex(int i) {
    final offset = _indexOffsetCache[i] ?? i * 640.0;
    _scrollCtrl?.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _scrollBy(double dx) {
    _scrollCtrl?.animateTo(
      (_scrollCtrl?.offset ?? 0.0) + dx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// 防误触提示 toast。
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.black.withValues(alpha: 0.7),
      ),
    );
  }

  /// 双击解锁/锁定触控（防躺卧误触）。
  void _toggleTouchLock() {
    setState(() => _touchLocked = !_touchLocked);
    _toast(_touchLocked ? '触摸已锁定' : '触摸已解锁');
  }

  /// 标记开始滑动，超分在滑动期间暂停。
  /// 使用 Completer 事件驱动：滑动开始时创建 Completer，结束时 complete 它，
  /// _CachedReaderImage 通过 await Completer.future 等待停止，无需轮询。
  void _markScrolling() {
    _scrollEndTimer?.cancel();
    if (_scrollEndCompleter == null || _scrollEndCompleter!.isCompleted) {
      _scrollEndCompleter = Completer<void>();
    }
    _scrollEndTimer = Timer(const Duration(milliseconds: 400), _markScrollEnd);
  }

  void _markScrollEnd() {
    _scrollEndTimer?.cancel();
    final c = _scrollEndCompleter;
    _scrollEndCompleter = null;
    c?.complete();
  }

  /// 供 _CachedReaderImage 等待滑动结束（事件驱动，非轮询）。
  static Completer<void>? get _currentScrollCompleter =>
      _ReaderPageState._scrollEndCompleter;

  /// 把本次累计的阅读时长 flush 到本地存储（每 5s 一次，退出时再 flush 一次）。
  Future<void> _flushStats() async {
    final elapsed = _readWatch.elapsed.inSeconds;
    if (elapsed <= 0) return;
    _readWatch.reset();
    _readWatch.start();
    await LocalStore.addReadingSeconds(elapsed);
  }

  /// 点击阅读区：按 x 位置判断 left/center/right，按手势配置执行动作。
  void _onReaderTap(Offset pos) {
    // 用户触摸即重置自动翻页计时（从最后交互起重新计 N 秒）
    _startAutoPage();
    // 防误触：动画中禁止操作
    if (_pageAnimating) return;

    final now = DateTime.now();

    // 手动双击检测（不依赖 GestureDetector.onDoubleTap，因与子组件手势竞技场冲突）。
    // 锁定时：双击 → 解锁。未锁定时：双击 → 切换菜单显隐（不会意外锁定）。
    final tapDt = now.difference(_lastTapTime).inMilliseconds;
    if (tapDt < _doubleTapMs && _lastTapPos != null &&
        (pos - _lastTapPos!).distance < _doubleTapDist) {
      if (_touchLocked) {
        _toggleTouchLock();
      } else {
        _toggleOverlay();
      }
      _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);
      _lastTapPos = null;
      return;
    }
    _lastTapTime = now;
    _lastTapPos = pos;

    // 防误触：触摸锁定（躺卧阅读时用户主动锁屏）
    if (_touchLocked) {
      _toast('触摸已锁定，双击解锁');
      return;
    }
    // 防掌按：连续两次触摸间隔 < 200ms 且位置相近 → 判定为掌按手势。
    // 掌按时更新时间戳但不执行动作，防止掌按期间误翻页。
    final touchDt = now.difference(_lastTouchTime).inMilliseconds;
    if (touchDt < 200 && _lastTouchPos != null &&
        (pos - _lastTouchPos!).distance < 80) {
      _lastTouchTime = now;
      return;
    }
    _lastTouchTime = now;
    _lastTouchPos = pos;

    // 热区按"限宽容器实际宽度"三等分：正文被 Center+ConstrainedBox 限宽
    // （大于 readerMaxWidth 时居中留白），若按全屏宽划分，大屏上左右热区
    // 与视觉三等分错位（越宽错位越大），导致翻页/切菜单区域漂移。
    final w = min(MediaQuery.sizeOf(context).width,
        Responsive.readerMaxWidth(context));
    String region;
    if (pos.dx < w / 3) {
      region = 'left';
    } else if (pos.dx < w * 2 / 3) {
      region = 'center';
    } else {
      region = 'right';
    }
    // RTL：日漫从右往左读，左右区域对调（左→下一页，右→上一页）
    if (_rtl && region != 'center') {
      region = region == 'left' ? 'right' : 'left';
    }
    final action = _gesture[region] ??
        (region == 'center'
            ? 'toggleMenu'
            : (region == 'left' ? 'prevPage' : 'nextPage'));
    switch (action) {
      case 'prevPage':
        _prevPage();
      case 'nextPage':
        _nextPage();
      case 'toggleMenu':
        _toggleOverlay();
      case 'toggleBrightness':
        _setBrightness(_dim > 0.5 ? 0.3 : 1.0);
      case 'scrollDown':
        if (_horizontal) {
          _nextPage();
        } else {
          _scrollBy(300);
        }
      case 'scrollUp':
        if (_horizontal) {
          _prevPage();
        } else {
          _scrollBy(-300);
        }
      default:
        _toggleOverlay();
    }
  }

  void _prevPage() {
    _pageAnimating = true;
    if (_horizontal) {
      final c = _pageCtrl;
      if (c != null && c.hasClients) {
        final i = c.page?.round() ?? 0;
        if (i > 0) c.animateToPage(i - 1, duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
      }
    } else {
      final c = _scrollCtrl;
      if (c != null && c.hasClients) {
        c.animateTo((c.offset - 400).clamp(0, c.position.maxScrollExtent),
            duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
      }
    }
    Future.delayed(const Duration(milliseconds: 280), () {
      if (mounted) _pageAnimating = false;
    });
  }

  void _nextPage() {
    _pageAnimating = true;
    if (_horizontal) {
      final c = _pageCtrl;
      if (c != null && c.hasClients) {
        final i = c.page?.round() ?? 0;
        if (i < (_urls.length + (_canContinue ? 1 : 0)) - 1) {
          c.nextPage(duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
        } else if (_canContinue) {
          _continueToNextChapter();
        }
      }
    } else {
      final c = _scrollCtrl;
      if (c != null && c.hasClients) {
        if ((_curPage >= _urls.length - 1) && _canContinue) {
          _continueToNextChapter();
          return;
        }
        c.animateTo((c.offset + 400).clamp(0, c.position.maxScrollExtent),
            duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
      }
    }
    Future.delayed(const Duration(milliseconds: 280), () {
      if (mounted) _pageAnimating = false;
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // 退出阅读时恢复系统默认熄屏
    // 还原系统亮度
    if (_brightnessNative) {
      try {
        ScreenBrightness.instance.resetApplicationScreenBrightness();
      } catch (_) {}
    }
    _statsTimer?.cancel();
    _hideTimer?.cancel();
    _historyDebounce?.cancel();
    _scrollEndTimer?.cancel();
    _stopAutoPage();
    // 清理滑动 Completer，避免等待方永久挂起
    if (_ReaderPageState._scrollEndCompleter != null &&
        !_ReaderPageState._scrollEndCompleter!.isCompleted) {
      _ReaderPageState._scrollEndCompleter!.complete();
    }
    _ReaderPageState._scrollEndCompleter = null;
    _readWatch.stop();
    final elapsed = _readWatch.elapsed.inSeconds;
    if (elapsed > 0) LocalStore.addReadingSeconds(elapsed);
    _pageCtrl?.dispose();
    _scrollCtrl?.dispose();
    super.dispose();
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (_urls.isEmpty) {
      final msg = widget.sourceId == 'mangadex'
          ? '该章节暂时无法获取（外部/已下架章节），可换其它话或换源试试'
          : '暂不支持该源阅读（图片解析接入中），请切换源或换章节';
      return Center(
          child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Text(msg,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54)),
      ));
    }
    if (_horizontal) {
      _pageCtrl?.dispose();
      final ctrl = PageController();
      _pageCtrl = ctrl;
      // 若续读页码 >0，先跳到对应页
      if (widget.initialPage > 0 && _urls.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageCtrl!.hasClients) {
            _pageCtrl!.jumpToPage(
                widget.initialPage.clamp(0, _urls.length - 1));
          }
        });
      }
      return Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: Responsive.readerMaxWidth(context)),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (d) => _onReaderTap(d.localPosition),
            child: PageView.builder(
              controller: ctrl,
              itemCount: _urls.length + (_canContinue ? 1 : 0),
          onPageChanged: (idx) {
            _markScrolling();
            setState(() => _curPage = idx);
            _recordHistory();
            if (idx >= _urls.length && _canContinue) {
              // 读到"下一话"尾页 → 触发连读
              _continueToNextChapter();
              return;
            }
            _prefetch(idx + 1);
          },
          itemBuilder: (c, i) {
            if (i >= _urls.length && _canContinue) {
              return _NextChapterFooter(
                title: _nextChapter()?.title ?? '',
                onTap: _continueToNextChapter,
              );
            }
            return _ImageView(_urls[i],
                pageIndex: i, totalPages: _urls.length, resLevel: _resLevel,
                horizontal: true, sourceId: widget.sourceId);
          },
        ),
      ),
    ),
  );
  }
    _scrollCtrl?.dispose();
    final sctrl = ScrollController();
    _scrollCtrl = sctrl;
    // 点击空白切换工具栏显隐。GestureDetector 放在 body 内层而非 Stack 顶层，
    // 否则会遮蔽顶部返回/底部工具栏按钮（hit test 自顶向下、命中即止）。
    return Center(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: Responsive.readerMaxWidth(context)),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (d) => _onReaderTap(d.localPosition),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification) {
                _markScrolling();
              } else if (n is ScrollEndNotification) {
                _markScrollEnd();
              }
              return false;
            },
            child: ListView.builder(
              controller: sctrl,
              padding: EdgeInsets.zero,
              // cacheExtent 在 Flutter 3.44 中已标记 deprecated（推荐 scrollCacheExtent），
              // 但后者类型为 ScrollCacheExtent? 且未从 widgets 导出，
              // widgets 层无法直接引用；此处保留旧 API 以维持构建通过。
              cacheExtent: 900,
              itemCount: _urls.length + (_canContinue ? 1 : 0),
              itemBuilder: (c, i) {
                if (i >= _urls.length && _canContinue) {
                  return _NextChapterFooter(
                    title: _nextChapter()?.title ?? '',
                    onTap: _continueToNextChapter,
                  );
                }
                return _ImageView(_urls[i],
                    pageIndex: i, totalPages: _urls.length, resLevel: _resLevel,
                    onLayout: (h) => _observeLayout(i, h),
                    sourceId: widget.sourceId);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 是否可连读：当前章节在章节列表中且不是最后一话。
  bool get _canContinue => _chapterIndex >= 0 && _chapterIndex < widget.chapters.length - 1;

  Chapter? _nextChapter() =>
      _canContinue ? widget.chapters[_chapterIndex + 1] : null;

  /// 沉浸式连读：加载下一话并跳到第一页。
  Future<void> _continueToNextChapter() async {
    final next = _nextChapter();
    if (next == null) return;
    _chapterIndex++;
    _indexOffsetCache.clear();
    await _openChapter(next.id, next.title, startPage: 0);
  }

  /// 纵向模式：记录每页实际高度累计偏移，供精确跳页。
  /// 由 _ImageView 通过 onLayout 回调图片加载完成后的高度。
  void _observeLayout(int index, double? height) {
    if (height == null || index < 0) return;
    _layoutHeights[index] = height;
    // 重算到最新一段连续已知高度，更新偏移缓存
    var sum = 0.0;
    for (var k = 0; k < _layoutHeights.length; k++) {
      final h = _layoutHeights[k];
      if (h == null) break;
      _indexOffsetCache[k] = sum;
      sum += h;
    }
  }
}

class _ImageView extends StatefulWidget {
  final String url;
  final int pageIndex;
  final int totalPages;
  final int resLevel;
  final bool horizontal;
  final String sourceId;

  /// 图片加载完成后回调实际高度（纵向模式用于精确跳页）。
  final ValueChanged<double?>? onLayout;
  const _ImageView(this.url,
      {required this.pageIndex, required this.totalPages, required this.resLevel,
      this.horizontal = false, this.sourceId = '', this.onLayout});

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView>
    with AutomaticKeepAliveClientMixin {
  bool _error = false;
  final GlobalKey _imgKey = GlobalKey();

  @override
  bool get wantKeepAlive => true;

  bool get _isJm => widget.sourceId == 'jm';

  bool get _superResEnabled => widget.resLevel >= 2;

  FilterQuality _filterLevel() {
    switch (widget.resLevel) {
      case 0:
        return FilterQuality.none;
      case 1:
        return FilterQuality.low;
      case 2:
        return FilterQuality.medium;
      default:
        return FilterQuality.none;
    }
  }

  void _reportLayout() {
    if (widget.horizontal || widget.onLayout == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _imgKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        widget.onLayout!(box.size.height);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _reportLayout();
  }

  @override
  void didUpdateWidget(covariant _ImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _reportLayout();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error) {
      return SizedBox(
        width: double.infinity,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('图片加载失败', style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () => setState(() => _error = false),
              ),
            ],
          ),
        ),
      );
    }

    final fit = widget.horizontal ? BoxFit.contain : BoxFit.fitWidth;
    Widget img;
    if (widget.url.startsWith('/')) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final cw = (MediaQuery.sizeOf(context).width * dpr).toInt();
      img = Image.file(
          File(widget.url),
          key: _imgKey,
          width: double.infinity,
          fit: fit,
          filterQuality: _filterLevel(),
          cacheWidth: cw,
          errorBuilder: (c, e, s) {
            Future.microtask(() {
              if (mounted) setState(() => _error = true);
            });
            return const SizedBox();
          },
        );
    } else if (widget.url.contains('@') || _isJm) {
      img = KeyedSubtree(
        key: _imgKey,
        child: JmScrambleImageWidget(
          url: widget.url,
          fit: fit,
          filterQuality: _filterLevel(),
        ),
      );
    } else {
      img = KeyedSubtree(
        key: _imgKey,
        child: _CachedReaderImage(
          url: widget.url,
          fit: fit,
          filterQuality: _filterLevel(),
          sourceId: widget.sourceId,
          superRes: _superResEnabled,
          onError: () {
            Future.microtask(() {
              if (mounted) setState(() => _error = true);
            });
          },
        ),
      );
    }

    // 横向翻页：用 Expanded 让图片填满整个页面
    if (widget.horizontal) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.totalPages > 1 && widget.pageIndex == 0)
            SizedBox(
              width: double.infinity,
              height: 40,
              child: Center(
                child: Text(
                  '共 ${widget.totalPages} 页',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          Expanded(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: img,
              ),
            ),
        ],
      );
    }

    // 纵向滚动：页码提示 + 图片
    // 注意：不能用 Column 包裹 img（Column 会把 img 约束到 intrinsic 尺寸，
    // 导致 图片在高 DPR 屏上显示极小）。页码提示单独渲染后，
    // img 作为 ListView item 直接展开，BoxFit.fitWidth 让宽度撑满、
    // 高度按图片比例自适应。
    if (widget.totalPages > 1 && widget.pageIndex == 0) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: 40,
            child: Center(
              child: Text(
                '共 ${widget.totalPages} 页',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          img,
        ],
      );
    }
    return img;
  }
}

/// 阅读页普通网络图：走 ImageCacheManager（内存+磁盘），带进度与错误回调。
class _CachedReaderImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final String sourceId;
  final bool superRes;
  final VoidCallback onError;
  const _CachedReaderImage({
    required this.url,
    required this.fit,
    required this.filterQuality,
    required this.sourceId,
    required this.superRes,
    required this.onError,
  });

  @override
  State<_CachedReaderImage> createState() => _CachedReaderImageState();
}

class _CachedReaderImageState extends State<_CachedReaderImage>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CachedReaderImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.superRes != widget.superRes) {
      _load();
    }
  }

  /// 部分图源 CDN 需要 Referer 头才返回图片（如 dm5 的 cdndm5.com），
  /// 否则返回 403/404 导致「图片加载失败」。与 _prefetch 保持一致的 headers。
  Map<String, String>? _headers() => _ReaderPageState._headersForUrl(widget.url);

  String _srKey() => '${widget.url}|${ImageSuperRes.algoVersion}';

  /// 先加载原图快速显示，滑动停止后再异步超分升级。
  /// 避免超分 Isolate 在滑动期间并发导致低端机卡死。
  Future<void> _load() async {
    // 保留已加载图片字节，避免占位高度(240)与实际高度来回跳变造成上翻抖动；
    // 仅在确实没有图片时才触发重建显示占位。
    if (_bytes == null) {
      setState(() => _failed = false);
    } else {
      _failed = false;
    }
    try {
      // 第一步：先加载原图（快速显示）
      final raw = await ImageCacheManager.load(widget.url, headers: _headers());
      if (!mounted) return;
      setState(() => _bytes = raw);

      if (!widget.superRes) return;

      // 第二步：等滑动停止后再做超分（防止滑动期间 Isolate 并发卡死）
      await _waitForScrollEnd();
      if (!mounted) return;

      // 超分缓存命中则秒换；未命中则排队做 Lanczos-3（全局互斥锁串行化）
      final sr = await ImageCacheManager.load(_srKey(),
          headers: _headers(),
          fetch: () async => await ImageSuperRes.upscale2x(raw));
      if (mounted) {
        setState(() {
          _bytes = sr;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
        widget.onError();
      }
    }
  }

  /// 等待滑动停止（事件驱动，非轮询）。滑动中不启动超分。
  /// 使用 Completer：滑动停止时 notification 触发 complete，等待方立即恢复。
  Future<void> _waitForScrollEnd() async {
    final c = _ReaderPageState._currentScrollCompleter;
    if (c == null || c.isCompleted) return;
    await c.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_failed) {
      return SizedBox(
        width: double.infinity,
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset('assets/placeholder_cover.webp',
                fit: BoxFit.cover, gaplessPlayback: true),
            Center(
              child: GestureDetector(
                onTap: _load,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.refresh_rounded,
                      color: Colors.white70, size: 26),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(
        width: double.infinity,
        height: 240,
        child: Image.asset('assets/placeholder_cover.webp',
            fit: BoxFit.cover),
      );
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cw = (MediaQuery.sizeOf(context).width * dpr).toInt();
    return Image.memory(
      bytes,
      width: double.infinity,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
      cacheWidth: cw,
      gaplessPlayback: true,
    );
  }
}

/// 顶部工具栏：返回 / 章节名 / 菜单（对齐 S5）。
class _ReaderTopBar extends StatelessWidget {
  final bool visible;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onMenu;
  const _ReaderTopBar({
    required this.visible,
    required this.title,
    required this.onBack,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -0.4),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: visible ? 1 : 0,
          child: Padding(
            padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 8, Responsive.pagePadding(context), 0),
            child: Row(
              children: [
                _GlassCircle(icon: Icons.arrow_back_rounded, onTap: onBack),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _GlassCircle(icon: Icons.more_vert_rounded, onTap: onMenu),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部居中页码（S5：`3 / 128`）。
class _ReaderPageIndicator extends StatelessWidget {
  final bool visible;
  final String label;
  const _ReaderPageIndicator({required this.visible, required this.label});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 102,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: visible ? 1 : 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部悬浮玻璃工具栏（S5：亮度 / 目录 / 翻页模式 / 下载）。
class _ReaderToolbar extends StatelessWidget {
  final bool visible;
  final bool downloaded;
  final bool horizontal;
  final VoidCallback? onBrightness;
  final VoidCallback onCatalog;
  final VoidCallback onLayout;
  final VoidCallback? onDownload;
  const _ReaderToolbar({
    required this.visible,
    required this.downloaded,
    required this.horizontal,
    this.onBrightness,
    required this.onCatalog,
    required this.onLayout,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(0, 0.5),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: visible ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 26),
              child: Center(
                child: Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ToolBtn(
                        icon: Icons.brightness_6_outlined,
                        onTap: onBrightness,
                      ),
                      _sep(),
                      _ToolBtn(
                        icon: Icons.list_alt_rounded,
                        onTap: onCatalog,
                      ),
                      _sep(),
                      _ToolBtn(
                        icon: horizontal
                            ? Icons.view_carousel_outlined
                            : Icons.view_stream_outlined,
                        onTap: onLayout,
                      ),
                      _sep(),
                      _ToolBtn(
                        icon: downloaded
                            ? Icons.download_done_rounded
                            : Icons.download_outlined,
                        active: downloaded,
                        onTap: onDownload,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sep() => Container(
        width: 0.5,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: Colors.white.withValues(alpha: 0.18),
      );
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  const _ToolBtn({required this.icon, this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 20,
          color: active ? Colors.amber : Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// 阅读设置抽屉（S6）：亮度滑块 + 翻页模式 + 画质 + 自动翻页 + 目录/章节/下载。
class _ReaderSettingsSheet extends StatefulWidget {
  final bool horizontal;
  final double dim;
  final int resLevel;
  final int autoPage;
  final ValueChanged<double> onDimChanged;
  final ValueChanged<bool> onLayoutChanged;
  final ValueChanged<int> onResLevelChanged;
  final ValueChanged<int> onAutoPageChanged;
  final VoidCallback onCatalog;

  /// 章内切换章节（章节列表非空时才可用）。
  final VoidCallback? onSelectChapter;
  final VoidCallback? onDownload;
  const _ReaderSettingsSheet({
    required this.horizontal,
    required this.dim,
    required this.resLevel,
    required this.autoPage,
    required this.onDimChanged,
    required this.onLayoutChanged,
    required this.onResLevelChanged,
    required this.onAutoPageChanged,
    required this.onCatalog,
    this.onSelectChapter,
    this.onDownload,
  });

  @override
  State<_ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<_ReaderSettingsSheet> {
  late double _localDim;
  late int _localResLevel;
  late bool _localHorizontal;
  late int _localAutoPage;

  @override
  void initState() {
    super.initState();
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localHorizontal = widget.horizontal;
    _localAutoPage = widget.autoPage;
  }

  @override
  void didUpdateWidget(covariant _ReaderSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localHorizontal = widget.horizontal;
    _localAutoPage = widget.autoPage;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 16, Responsive.pagePadding(context), 28),
      // 固定深色背景：阅读器本身是黑底图片查看器，弹窗用深色与整体一致，
      // 且无论 App 是浅色/深色主题，白色文字都必定可读
      // （原先用 scheme.surface，浅色主题下变成白底白字，完全看不见）。
      decoration: BoxDecoration(
        color: const Color(0xFF1C1B1F),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
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
          const SizedBox(height: 16),
          Text('阅读设置',
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: 12),
          // 内容区可滚动：亮度+翻页+画质+自动翻页+按钮在横屏平板上
          // 容易超出 BottomSheet 默认高度（原溢出 ~129px）。
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
          // 亮度
          Row(
            children: [
              const Icon(Icons.light_mode_rounded,
                  size: 16, color: Colors.white70),
              const SizedBox(width: 10),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: scheme.primary,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                    thumbColor: Colors.white,
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 8),
                  ),
                  child: Slider(
                    value: _localDim,
                    onChanged: (v) {
                      setState(() => _localDim = v);
                      widget.onDimChanged(v);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('${(_localDim * 100).round()}%',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 14),
          // 翻页模式
          Text('翻页模式',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 8),
          Row(
            children: [
              _layoutOption('横向翻页', _localHorizontal, () {
                setState(() => _localHorizontal = true);
                widget.onLayoutChanged(true);
              }),
              const SizedBox(width: 8),
              _layoutOption('纵向滚动', !_localHorizontal, () {
                setState(() => _localHorizontal = false);
                widget.onLayoutChanged(false);
              }),
            ],
          ),
          const SizedBox(height: 16),
          // 画质（真超分 = Lanczos-3 2x 上采样）
          Text('画质增强',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
          const SizedBox(height: 8),
          Row(
            children: [
              _resOption('原图', 0, _localResLevel, () {
                setState(() => _localResLevel = 0);
                widget.onResLevelChanged(0);
              }),
              const SizedBox(width: 6),
              _resOption('平滑', 1, _localResLevel, () {
                setState(() => _localResLevel = 1);
                widget.onResLevelChanged(1);
              }),
              const SizedBox(width: 6),
              _resOption('高清(2x)', 2, _localResLevel, () {
                setState(() => _localResLevel = 2);
                widget.onResLevelChanged(2);
              }),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '「高清(2x)」= 真实 Lanczos-3 超分（Isolate 内 2x 上采样），首张慢、之后秒开',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 16),
          // 自动翻页
          Text('自动翻页',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 8),
          Row(
            children: [
              _autoOption('关闭', 0, _localAutoPage, () {
                setState(() => _localAutoPage = 0);
                widget.onAutoPageChanged(0);
              }),
              const SizedBox(width: 6),
              _autoOption('5秒', 5, _localAutoPage, () {
                setState(() => _localAutoPage = 5);
                widget.onAutoPageChanged(5);
              }),
              const SizedBox(width: 6),
              _autoOption('10秒', 10, _localAutoPage, () {
                setState(() => _localAutoPage = 10);
                widget.onAutoPageChanged(10);
              }),
              const SizedBox(width: 6),
              _autoOption('20秒', 20, _localAutoPage, () {
                setState(() => _localAutoPage = 20);
                widget.onAutoPageChanged(20);
              }),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '开启后自动翻页，触摸屏幕或显示菜单时暂停',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ghostBtn('目录', Icons.list_alt_rounded,
                    () => widget.onCatalog()),
              ),
              const SizedBox(width: 8),
              if (widget.onSelectChapter != null) ...[
                Expanded(
                  child: _ghostBtn('章节', Icons.menu_book_rounded,
                      () => _showChapterPicker()),
                ),
                const SizedBox(width: 8),
              ],
              if (widget.onDownload != null)
                Expanded(
                  child: _ghostBtn('下载本话', Icons.download_outlined,
                      () => widget.onDownload!()),
                ),
            ],
          ),
        ],
      ),
    ),
  ),
        ],
      ),
    );
  }

  /// 章内切换：展示章节列表底部弹窗。
  void _showChapterPicker() {
    final cb = widget.onSelectChapter;
    if (cb == null) return;
    Navigator.of(context).pop(); // 关闭设置抽屉
    cb();
  }

  Widget _layoutOption(String label, bool active, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: active
                ? scheme.primary
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? scheme.primary
                  : Colors.white.withValues(alpha: 0.1),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.white : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }

  Widget _resOption(String label, int value, int current, VoidCallback onTap) {
    final active = value == current;
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active
                ? scheme.primary
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? scheme.primary
                  : Colors.white.withValues(alpha: 0.1),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.white : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }

  /// 自动翻页选项按钮（复用画质选项风格）。
  Widget _autoOption(String label, int value, int current, VoidCallback onTap) =>
      _resOption(label, value, current, onTap);

  Widget _ghostBtn(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: Colors.white),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 13, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// 页目录底部弹窗（点击跳页）。
class _CatalogSheet extends StatelessWidget {
  final List<String> urls;
  final int current;
  final bool horizontal;
  final ValueChanged<int> onSelect;
  const _CatalogSheet({
    required this.urls,
    required this.current,
    required this.horizontal,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 16, Responsive.pagePadding(context), 20),
        decoration: BoxDecoration(
          // 固定深色背景，避免浅色主题下白底白字（与设置弹窗一致）
        color: const Color(0xFF1C1B1F),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
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
            const SizedBox(height: 14),
            Text('本话目录 · 共 ${urls.length} 页',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 12),
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 目录弹窗被限宽（500dp）居中，网格列数不能按全屏宽算
                  // （全屏宽在桌面高达 14 列，500dp 内每格会被挤到 ~24dp）。
                  // 按容器实际宽度推导，每格约 44dp 起，最多 10 列。
                  final cols =
                      (constraints.maxWidth / 44).floor().clamp(4, 10);
                  return GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.1,
                    ),
                    itemCount: urls.length,
                    itemBuilder: (_, i) {
                      final active = i == current;
                      return InkWell(
                        onTap: () => onSelect(i),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          decoration: BoxDecoration(
                            color: active
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  active ? FontWeight.w700 : FontWeight.w500,
                              color: active
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 玻璃态圆形按钮。
class _GlassCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _GlassCircle({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }
}

/// 章末连读尾页：提示"下一话"并点击跳转。
class _NextChapterFooter extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  const _NextChapterFooter({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_downward_rounded,
                size: 28, color: Colors.white.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              '已到底部',
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.skip_next_rounded, size: 18),
              label: Text('下一话：$title'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全作品章节列表底部弹窗（章内切换章节）。
class _ChapterListSheet extends StatelessWidget {
  final List<Chapter> chapters;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  const _ChapterListSheet({
    required this.chapters,
    required this.currentIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 16, Responsive.pagePadding(context), 20),
        decoration: BoxDecoration(
          // 固定深色背景，避免浅色主题下白底白字（与设置弹窗一致）
        color: const Color(0xFF1C1B1F),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
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
            const SizedBox(height: 14),
            Text('章节列表 · 共 ${chapters.length} 话',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                itemCount: chapters.length,
                itemBuilder: (_, i) {
                  final active = i == currentIndex;
                  return InkWell(
                    onTap: () => onSelect(i),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                      margin: const EdgeInsets.only(bottom: 2),
                      decoration: BoxDecoration(
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: active
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.45),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              chapters[i].title.isEmpty
                                  ? '第${i + 1}话'
                                  : chapters[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: active
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: active
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                          if (active)
                            Icon(Icons.check_rounded,
                                size: 16, color: Colors.white),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}