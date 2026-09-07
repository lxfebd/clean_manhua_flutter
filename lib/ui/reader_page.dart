import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../net/download_manager.dart';
import '../net/http_client.dart';
import '../net/image_cache.dart';
import '../net/jm_scramble.dart';
import '../net/local_store.dart';
import '../net/smart_prefetch.dart';
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

  /// 纵向滚动模式续读的精确滚动偏移（像素），优先于 [initialPage] 定位。
  final double initialOffset;

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
    this.initialOffset = 0,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

/// 阅读器右键菜单动作。
enum _ReaderMenuAction { catalog, chapters, settings, download, bookmark }

/// 阅读模式：纵向滚动 / 单页横向 / 双页并排（平板横屏）。
enum ReaderMode {
  vertical(0),
  single(1),
  double(2);

  const ReaderMode(this.value);
  final int value;

  static ReaderMode fromValue(int v) => switch (v) {
        0 => ReaderMode.vertical,
        2 => ReaderMode.double,
        _ => ReaderMode.single,
      };
}

/// 双页模式下“视图”= 一屏左右两页。单页/纵向视图数=页数。
int viewCountOf(int pageCount, ReaderMode mode) {
  if (mode != ReaderMode.double) return pageCount;
  // 双页：每视图两页，末视图允许单页（总数奇数时多出一页）。
  return (pageCount / 2).ceil();
}

/// 视图 -> 起始页（双页模式下左页索引；右页为 +1）。
int pageOfView(int view, ReaderMode mode) {
  if (mode != ReaderMode.double) return view;
  return view * 2;
}

/// 页 -> 所在视图（双页模式下两页共一个视图）。
int viewOfPage(int page, ReaderMode mode) {
  if (mode != ReaderMode.double) return page;
  return page ~/ 2;
}

class _ReaderPageState extends State<ReaderPage> {
  List<String> _urls = [];
  bool _loading = true;
  ReaderMode _readerMode = ReaderMode.single;
  bool get _horizontal =>
      _readerMode != ReaderMode.vertical; // 单页/双页共用横向 PageView 基础设施
  bool _doublePage = false; // 双页并排模式（平板横屏推荐）
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
  /// 连读时缓存的章节图片列表（避免重复打开免网络请求）。
  /// 章末预取会把整话 URL 列表拉进来，连读几十话时只增不减，
  /// 加上限防无限增长：超过 40 话时淘汰最旧（LinkedHashMap 迭代序 = 插入序）。
  final Map<String, List<String>> _chapterPicCache = {};
  static const int _chapterPicCacheMax = 40;

  /// 阅读时长统计：累计本次阅读秒数，每 5s flush 一次。
  final Stopwatch _readWatch = Stopwatch();
  Timer? _statsTimer;

  /// 手势配置：left/center/right → 动作字符串。
  Map<String, String> _gesture = const {};

  /// 当前章节索引（-1 表示不在章节列表中，不启用连读）。
  late int _chapterIndex;

  /// 章末预取出的下一话标题（未预取到时为 null，过渡页回退到章节列表标题）。
  String? _nextChapterTitle;

  /// 防误触：触摸锁、动画锁、二次返回退出
  bool _touchLocked = false; // 用户主动锁定触控（躺卧阅读）
  bool _pageAnimating = false; // 翻页动画进行中
  DateTime _lastTouchTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastTouchPos;
  // 手动双击检测（不依赖 GestureDetector.onDoubleTap，因与子组件手势竞技场冲突）
  DateTime _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastTapPos;

  // 纵向模式双指缩放：用 raw Listener 采集原始指针事件，不走手势竞技场，
  // 因此不会与列表滚动手势冲突。放大后：单指拖动平移、轻点复位。
  final Map<int, Offset> _pinchPointers = {};
  double _pinchScale = 1.0;
  double _pinchBaseScale = 1.0;
  double _pinchStartDist = 0;
  Offset _pinchOffset = Offset.zero;
  Offset _pinchFocal = Offset.zero;
  String _pinchUrl = '';
  bool _pinching = false; // 当前正有两指按下
  bool _pinchMoved = false; // 放大态下单指是否产生过明显位移（区分轻点/拖动）
  int? _panId; // 放大后单指拖动
  Offset _panStartPos = Offset.zero;
  Offset _panStartOffset = Offset.zero;

  // 点击局部放大（放大镜）：长按（系统 LongPress 500ms）激活，2.2x 放大触点
  // 区域并跟随手指，松开消失。由 GestureDetector 的 LongPress 识别器触发——
  // 竞技场胜出会取消本次 tap（长按不误翻页/切菜单），也不会抢列表滚动。
  // 触点位置由顶层 raw Listener 在按下时采集（栈坐标系，与浮层 Positioned 对齐）。
  bool _loupeVisible = false;
  Offset _loupePos = Offset.zero;
  String _loupeUrl = '';
  int? _loupePointer; // 按下时的指针 id（raw Listener 跟随移动用）
  Offset? _loupeAnchorPos; // 按下时的触点位置（栈坐标）
  static const double _loupeRadius = 72; // 放大镜圆半径
  static const double _loupeZoom = 2.2; // 放大倍数

  /// 缩放遮罩是否显示（超过 1.01 视为放大态）。
  bool get _pinchActive => _pinchScale > 1.01 && _pinchUrl.isNotEmpty;
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
    // 预热网络类型探测：让后续翻页的智能预取深度能同步读取快照
    SmartPrefetch.warmUp();
    _chapterIndex =
        widget.chapters.indexWhere((c) => c.id == widget.chapterId);
    _activeChapterId = widget.chapterId;
    _activeChapterTitle = widget.title;
    _readWatch.start();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _flushStats());
    LocalStore.gestureConfig().then((g) {
      if (mounted) setState(() => _gesture = g);
    });
    // 桌面端键盘翻页：←/→ 或 Space 翻页、Esc 隐藏/显示工具栏。
    // 仅桌面平台注册，避免移动端物理键盘冲突（蓝牙键盘误触发）。
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
    }
    _init();
  }

  /// 桌面键盘处理：←/→/空格翻页（RTL 反转），Esc 切换工具栏。
  bool _keyHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_loading || _pageAnimating) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _overlay = !_overlay);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.space) {
      // RTL：← 表示下一页
      if (_rtl) {
        _nextPage();
      } else if (event.logicalKey == LogicalKeyboardKey.space) {
        _nextPage();
      } else {
        _prevPage();
      }
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (_rtl) {
        _prevPage();
      } else {
        _nextPage();
      }
      return true;
    }
    return false;
  }

  Future<void> _init() async {
    _readerMode = ReaderMode.fromValue(await LocalStore.readerMode());
    _doublePage = _readerMode == ReaderMode.double;
    _rtl = await LocalStore.rtlReader();
    _resLevel = await LocalStore.resLevel();
    _autoPage = await LocalStore.autoPageTurn();
    _downloaded = await DownloadManager.isDownloaded(_book.key, widget.chapterId);
    // 书签状态：横向看当前视图，纵向看整章（页 0 代表章节级标记）。
    _bookmarked = await LocalStore.isBookmarked(
        widget.sourceId, widget.comicId, _activeChapterId,
        _horizontal ? _curPage : 0);
    if (mounted) setState(() {});
    _load();
  }

  /// 读取/切换到一个章节（用于章内切章节 / 沉浸式连读）。
  Future<void> _openChapter(String chapterId, String chapterTitle,
      {int startPage = 0}) async {
    _hideTimer?.cancel();
    _resetPinch();
    _nextChapterTitle = null; // 换章后旧预取标题失效，重新按需拉取
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
          // 切章节时重置 PageController（复用旧的会带旧章节的页码偏移）。
          // 双页模式下 view = 页索引/2。
          final targetView = viewOfPage(target, _readerMode);
          _pageCtrl?.dispose();
          _pageCtrl = PageController(initialPage: targetView);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _pageCtrl?.jumpToPage(targetView);
          });
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
    if (_chapterPicCache.length >= _chapterPicCacheMax) {
      // 容量到顶：淘汰最旧一条，保持连读窗口内的章节不被清掉
      final eldest = _chapterPicCache.keys.first;
      _chapterPicCache.remove(eldest);
    }
    _chapterPicCache[chapterId] = urls;
    return urls;
  }

  /// 沉浸式连读加速：预先拉取下一话的图片列表并预取前 2 页，连读时秒开。
  /// 章末预取：剩余页数 ≤ 3 时预取下一话的图片列表和前 2 页字节，
  /// 再在「下一话」过渡页上转成当前 chapterTitle 角标（连读时免白屏）。
  Future<void> _prefetchNextChapter() async {
    final rem = _urls.length - _curPage;
    if (rem > 3) return; // 离章末还远，不提前拉取
    if (!_canContinue) return;
    final next = widget.chapters[_chapterIndex + 1];
    if (_chapterPicCache.containsKey(next.id)) return;
    try {
      final urls = await _chapterUrls(next.id);
      if (mounted) setState(() => _nextChapterTitle = next.title);
      // 网络自适应：Wi-Fi 预取 5 页、蜂窝 2 页、无网 0 页
      _prefetchRange(urls, 0,
          SmartPrefetch.nextChapterDepth(SmartPrefetch.cachedNetwork()));
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

  /// 记录历史（含页码与纵向滚动偏移）。翻页/滚动时也会调用以持续更新进度。
  /// 防抖 500ms：快速翻页/滚动时合并多次写入为一次磁盘 IO。
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
        // 纵向模式记录精确滚动偏移（像素），横向模式不记录（页码足够）。
        scrollOffset:
            _horizontal ? 0 : (_scrollCtrl?.offset ?? 0),
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
      // 若续读指定了页码，跳到该页（双页模式下定位到所在视图）
      if (widget.initialPage >= 0 && widget.initialPage < _urls.length) {
        setState(() => _curPage = widget.initialPage);
        if (_horizontal) {
          final c = PageController(
              initialPage: viewOfPage(widget.initialPage, _readerMode));
          _pageCtrl = c;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _pageCtrl?.jumpToPage(viewOfPage(widget.initialPage, _readerMode));
          });
        } else {
          // 纵向滚动：优先用精确滚动偏移续读（像素级进度），
          // 无偏移时退回按页估算（未知高度前按 640 估算，布局后精修）。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final sc = _scrollCtrl;
            if (sc == null || !sc.hasClients) return;
            final target = widget.initialOffset > 0
                ? widget.initialOffset
                : (_indexOffsetCache[widget.initialPage] ??
                    widget.initialPage * 640.0);
            sc.jumpTo(target.clamp(0, sc.position.maxScrollExtent));
          });
        }
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

  /// 预取后续页字节到缓存（本地已下载 / JM 解扰图跳过）。
  /// 深度按网络类型自适应：Wi-Fi 5 页、蜂窝 2 页、无网/未知 0 页。
  /// 注意：headers 必须与 _ImageView 一致（部分 CDN 无 Referer 返回 404，
  /// 若 preload 用无头请求启动 in-flight，后续正式加载会复用该失败 future）。
  void _prefetch(int from) {
    _prefetchRange(_urls, from, null);
  }

  /// 预取 [urls] 中 [from, from+count) 区间（count 为 null 时按网络自适应）。
  /// 共享 JM 解扰/本地已下载跳过逻辑，供当前章与下一章预取复用。
  void _prefetchRange(List<String> urls, int from, int? count) {
    final depth =
        (count ?? SmartPrefetch.chapterDepth(SmartPrefetch.cachedNetwork()))
            .clamp(0, 12);
    for (var k = from; k < from + depth && k < urls.length; k++) {
      _preloadOne(urls[k]);
    }
  }

  /// 预载单张图片字节到缓存（重复逻辑内聚，JM 解扰走 fetch 回调）。
  void _preloadOne(String u) {
    if (u.startsWith('/')) return;
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
    DownloadManager.resetCancel();
    setState(() => _downloading = true);
    try {
      final quality = await LocalStore.downloadQuality();
      final ok = await DownloadManager.downloadChapter(
        book: _book,
        chapterId: _activeChapterId,
        chapterTitle: _activeChapterTitle,
        urls: _urls,
        quality: quality == 1
            ? DownloadQuality.compact
            : DownloadQuality.original,
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
        // Listener 放在 Stack 顶层：纵向模式下采集原始指针事件（不参与手势
        // 竞技场）驱动双指缩放，横向模式不启用（已有 InteractiveViewer）。
        child: !_horizontal
            ? Listener(
                onPointerDown: _onPinchPointerDown,
                onPointerMove: _onPinchPointerMove,
                onPointerUp: _onPinchPointerUp,
                onPointerCancel: _onPinchPointerUp,
                child: _buildReaderStack(),
              )
            : _buildReaderStack(),
      ),
    ),
    );
  }

  /// 阅读器主体 Stack：正文 + 缩放遮罩 + 亮度遮罩 + 顶部/底部工具栏。
  Widget _buildReaderStack() {
    return Stack(
      children: [
        Positioned.fill(child: _buildBody()),
        // 纵向模式双指缩放遮罩（放大当前页，覆盖在正文上方）
        if (!_horizontal)
          _buildVerticalZoomOverlay(Theme.of(context).colorScheme),
        // 放大镜（长按激活，2.2x 放大触点区域）
        if (!_horizontal) _buildLoupe(),
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
        // 底部页码（横向翻页时显示当前视图/总视图，双页显示页范围）
        _ReaderPageIndicator(
          visible: _overlay && _horizontal,
          label: _downloading && _downloadTotal > 0
              ? '下载 $_downloadDone/$_downloadTotal'
              : _doublePage
                  ? '${_curPage + 1}-${(_curPage + 2).clamp(1, _urls.length)} / ${_urls.length}'
                  : '${_curPage + 1} / ${_urls.length}',
        ),
        // 底部悬浮玻璃工具栏
        _ReaderToolbar(
          visible: _overlay,
          downloaded: _downloaded,
          horizontal: _horizontal,
          doublePage: _doublePage,
          onBrightness: () => _showReaderSettings(),
          onCatalog: () => _showCatalog(),
          onLayout: () => _cycleReaderMode(),
          onDownload: _downloading ? null : _download,
          // 底部新增「下一章」：直接跳下一话，无需翻到章节末尾。
          // 最后一章时传 null，按钮自动隐藏。
          onNextChapter: _canContinue ? _continueToNextChapter : null,
        ),
      ],
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

  // ─── 纵向模式双指缩放（raw pointer，不走手势竞技场）──────────────────────

  /// 当前视口内正在展示的图片 url（纵向模式缩放对象）。
  String _visibleImageUrl() {
    if (_urls.isEmpty) return '';
    final idx = _curPage.clamp(0, _urls.length - 1);
    return _urls[idx];
  }

  void _onPinchPointerDown(PointerDownEvent e) {
    // 只处理触屏/触控笔主按钮；鼠标右键菜单不受影响。
    if (e.kind != PointerDeviceKind.touch &&
        e.kind != PointerDeviceKind.stylus) {
      return;
    }
    _pinchPointers[e.pointer] = e.localPosition;
    if (_pinchPointers.length == 2) {
      _cancelLoupe();
      _pinching = true;
      final pts = _pinchPointers.values.toList();
      _pinchStartDist = (pts[0] - pts[1]).distance;
      _pinchFocal = (pts[0] + pts[1]) / 2;
      if (_pinchUrl.isEmpty) {
        _pinchUrl = _visibleImageUrl();
        // 两指间距 / 屏宽 ≈ 当前等效缩放：从该基线继续捏合
        _pinchBaseScale = (_pinchStartDist /
                max(MediaQuery.sizeOf(context).width, 1.0))
            .clamp(1.0, 4.0);
      } else {
        _pinchBaseScale = _pinchScale <= 1.01 ? 1.0 : _pinchScale;
      }
    } else if (_pinchPointers.length == 1 && _pinchActive) {
      _cancelLoupe();
      // 放大态下重新落下单指 → 准备平移
      _panId = e.pointer;
      _panStartPos = e.localPosition;
      _panStartOffset = _pinchOffset;
      _pinchMoved = false;
    } else if (_pinchPointers.length == 1 && !_pinchActive) {
      // 单指按下（未放大）：记录触点位置。长按激活由 GestureDetector 的
      // LongPress 识别器负责（竞技场胜出会取消本次 tap，长按不误翻页）。
      if (e.pointer != _loupePointer) {
        _loupePointer = e.pointer;
        _loupeAnchorPos = e.localPosition;
      }
    }
  }

  void _onPinchPointerMove(PointerMoveEvent e) {
    if (!_pinchPointers.containsKey(e.pointer)) return;
    _pinchPointers[e.pointer] = e.localPosition;
    if (_pinching && _pinchPointers.length == 2) {
      final pts = _pinchPointers.values.toList();
      final dist = (pts[0] - pts[1]).distance;
      if (dist > 0 && _pinchStartDist > 0) {
        setState(() {
          _pinchScale = (_pinchBaseScale * dist / _pinchStartDist).clamp(1.0, 4.0);
          _pinchFocal = (pts[0] + pts[1]) / 2;
          _pinchOffset = _clampPinchOffset(_pinchOffset);
        });
      }
    } else if (_pinchActive && e.pointer == _panId) {
      final d = e.localPosition - _panStartPos;
      if (d.distance > 8) _pinchMoved = true;
      setState(() => _pinchOffset = _clampPinchOffset(_panStartOffset + d));
    } else if (_loupeVisible && e.pointer == _loupePointer) {
      // 放大镜跟随手指（长按激活后持续移动也保持显示，模拟拖动查看）
      setState(() => _loupePos = e.localPosition);
    }
  }

  /// 放大态下限制平移范围：图片以 fitWidth 撑满宽度并等比缩放后，
  /// 横向/纵向最多把多出的部分拖到边缘，不允许把内容拖出屏幕外。
  Offset _clampPinchOffset(Offset o) {
    final vw = MediaQuery.sizeOf(context).width;
    final vh = MediaQuery.sizeOf(context).height;
    // 缩放后内容尺寸（宽恒为视口宽，高按比例超出）
    final s = _pinchScale;
    final cw = vw * s;
    final ch = vh * s; // fitWidth 下高也等比放大（近似，页高≈屏高时准确）
    final maxX = (cw - vw) / 2;
    final maxY = (ch - vh) / 2;
    return Offset(
      o.dx.clamp(-maxX, maxX),
      o.dy.clamp(-maxY, maxY),
    );
  }

  void _onPinchPointerUp(PointerEvent e) {
    _pinchPointers.remove(e.pointer);
    if (e.pointer == _panId) _panId = null;
    if (_pinchPointers.length < 2) _pinching = false;
    // 抬起即取消放大镜（长按结束由 LongPress 识别器再兜底一次，幂等）
    _cancelLoupe();
    // 两指捏合中抬起一根：剩余单指接管平移（放大态下）
    if (_pinchPointers.length == 1 && _pinchActive && _panId == null) {
      _panId = _pinchPointers.keys.first;
      _panStartPos = _pinchPointers.values.first;
      _panStartOffset = _pinchOffset;
      _pinchMoved = false;
    }
    // 轻点复位：放大态下单指按下后几乎未移动就抬起
    if (_pinchPointers.isEmpty && _pinchActive) {
      if (!_pinchMoved) _resetPinch();
    } else if (_pinchPointers.isEmpty) {
      // 全部手指抬起且未放大：清空状态，恢复列表滚动。
      _pinchUrl = '';
      _pinchOffset = Offset.zero;
      _pinchFocal = Offset.zero;
      setState(() {});
    }
  }

  /// 复位缩放（轻点 / 切章时调用）。
  void _resetPinch() {
    _cancelLoupe();
    setState(() {
      _pinchScale = 1.0;
      _pinchOffset = Offset.zero;
      _pinchUrl = '';
      _pinching = false;
      _pinchMoved = false;
    });
  }

  // ─── 点击局部放大（放大镜）──────────────────────────────────────────────

  /// GestureDetector 长按识别器激活放大镜。长按在竞技场胜出会取消本次 tap，
  /// 因此长按不会误翻页/误切菜单；触点位置用按下时 raw Listener 采集的栈坐标
  /// （长按回调的 localPosition 是 body 坐标系，居中留白时会与浮层错位）。
  void _onLongPressStart(LongPressStartDetails d) {
    if (_loading || _pageAnimating || _touchLocked || _overlay) return;
    // 触点位置优先用按下时顶层 Listener 采集的栈坐标（与浮层 Positioned 对齐）。
    // 兜底：把全局坐标换算到当前 State 的 RenderBox（Stack 坐标系）。
    final anchor = _loupeAnchorPos;
    final box = context.findRenderObject() as RenderBox?;
    final Offset pos;
    if (anchor != null) {
      pos = anchor;
    } else if (box != null && box.hasSize) {
      pos = box.globalToLocal(d.globalPosition);
    } else {
      return;
    }
    final url = _visibleImageUrl();
    if (url.isEmpty) return;
    setState(() {
      _loupePos = pos;
      _loupeUrl = url;
      _loupeVisible = true;
    });
    HapticFeedback.selectionClick();
  }

  /// 取消放大镜（长按结束/手指抬起/切章时）。幂等，可在 dispose 后安全调用。
  void _cancelLoupe() {
    _loupePointer = null;
    _loupeAnchorPos = null;
    if (!_loupeVisible) return;
    _loupeVisible = false;
    _loupeUrl = '';
    if (mounted) setState(() {});
  }

  /// 放大镜浮层：长按激活，2.2x 放大触点区域并跟随手指，松开消失（纵向模式）。
  /// 复用 _ImageView 渲染当前页，Transform 把触点映射到镜片中心后 ClipOval 裁剪。
  Widget _buildLoupe() {
    if (!_loupeVisible || _loupeUrl.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final r = _loupeRadius;
    final vw = MediaQuery.sizeOf(context).width;
    final vh = MediaQuery.sizeOf(context).height;
    // 镜片中心放在手指上方，避免手指遮挡内容；贴边时收拢保持完整。
    final center = Offset(
      _loupePos.dx.clamp(r, vw - r),
      (_loupePos.dy - r - 24).clamp(r, vh - r),
    );
    return Positioned(
      left: center.dx - r,
      top: center.dy - r,
      child: IgnorePointer(
        child: Container(
          width: r * 2,
          height: r * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: scheme.primary, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: ClipOval(
            child: Transform(
              alignment: Alignment.topLeft,
              // 变换：先缩放再位移。屏上点 P → P*zoom + (中心 - pos*zoom)，
              // 触点 pos 恰好落在镜片中心，以中心为原点放大，焦点不飘移。
              transform: Matrix4.identity()
                ..translateByDouble(
                    center.dx - _loupePos.dx * _loupeZoom,
                    center.dy - _loupePos.dy * _loupeZoom,
                    0,
                    1)
                ..scaleByDouble(_loupeZoom, _loupeZoom, _loupeZoom, 1.0),
              child: SizedBox(
                width: vw,
                height: vh,
                child: ColoredBox(
                  color: Colors.black,
                  child: _ImageView(
                    _loupeUrl,
                    pageIndex: 0,
                    totalPages: 1,
                    resLevel: _resLevel,
                    sourceId: widget.sourceId,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 纵向模式缩放遮罩：放大当前页（纯视觉，手势由顶层 Listener 采集）。
  Widget _buildVerticalZoomOverlay(ColorScheme scheme) {
    if (!_pinchActive) return const SizedBox.shrink();
    return Positioned.fill(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Transform(
              transform: Matrix4.identity()
                ..translateByDouble(_pinchOffset.dx, _pinchOffset.dy, 0.0, 1.0)
                ..translateByDouble(_pinchFocal.dx, _pinchFocal.dy, 0.0, 1.0)
                ..scaleByDouble(_pinchScale, _pinchScale, _pinchScale, 1.0)
                ..translateByDouble(-_pinchFocal.dx, -_pinchFocal.dy, 0.0, 1.0),
              child: SizedBox(
                width: MediaQuery.sizeOf(context).width,
                height: MediaQuery.sizeOf(context).height,
                child: ColoredBox(
                  color: Colors.black,
                  child: _ImageView(
                    _pinchUrl,
                    pageIndex: 0,
                    totalPages: 1,
                    resLevel: _resLevel,
                    sourceId: widget.sourceId,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 桌面右键菜单：目录 / 切换章节 / 设置 / 下载当前话。
  /// 在阅读区任意位置右键弹出（onSecondaryTapDown 触发）。
  void _showReaderMenu(Offset globalPos) {    _hideTimer?.cancel();
    final scheme = Theme.of(context).colorScheme;
    showMenu<_ReaderMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
          globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy),
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      items: [
        PopupMenuItem(
          value: _ReaderMenuAction.catalog,
          child: ListTile(
            leading: Icon(Icons.list_alt_rounded, size: 20),
            title: const Text('目录', style: TextStyle(fontSize: 13.5)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (widget.chapters.isNotEmpty)
          PopupMenuItem(
            value: _ReaderMenuAction.chapters,
            child: ListTile(
              leading: Icon(Icons.swap_horiz_rounded, size: 20),
              title: const Text('切换章节', style: TextStyle(fontSize: 13.5)),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        PopupMenuItem(
          value: _ReaderMenuAction.settings,
          child: ListTile(
            leading: Icon(Icons.tune_rounded, size: 20),
            title: const Text('阅读设置', style: TextStyle(fontSize: 13.5)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (!_downloading)
          PopupMenuItem(
            value: _ReaderMenuAction.download,
            child: ListTile(
              leading: Icon(Icons.download_rounded, size: 20),
              title: Text(_downloaded ? '已下载' : '下载当前话',
                  style: const TextStyle(fontSize: 13.5)),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        PopupMenuItem(
          value: _ReaderMenuAction.bookmark,
          child: ListTile(
            leading: Icon(_bookmarked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                size: 20, color: _bookmarked ? Colors.amber : null),
            title: Text(_bookmarked ? '取消书签' : '书签当前页',
                style: const TextStyle(fontSize: 13.5)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    ).then((action) {
      if (action == null || !mounted) return;
      switch (action) {
        case _ReaderMenuAction.catalog:
          _showCatalog();
        case _ReaderMenuAction.chapters:
          _showChapterList();
        case _ReaderMenuAction.settings:
          _showReaderSettings();
        case _ReaderMenuAction.download:
          if (!_downloading) _download();
        case _ReaderMenuAction.bookmark:
          _toggleBookmark();
      }
    });
  }

  /// 书签当前页（或取消）。仅横向模式有"当前页"概念；纵向模式标记当前章节。
  bool _bookmarked = false;
  void _toggleBookmark() async {
    final s = widget.sourceId;
    final c = widget.comicId;
    final ch = _activeChapterId;
    final page = _horizontal ? _curPage : 0; // 纵向整章标记，页固定 0
    final all = await LocalStore.bookmarks();
    final key = '$s::$c::$ch::$page';
    if (_horizontal) {
      if (all.any((b) => b.key == key)) {
        await LocalStore.removeBookmark(s, c, ch, page);
      } else {
        await LocalStore.addBookmark(ComicBookmark(
          book: _book, chapterId: ch, chapterTitle: _activeChapterTitle,
          pageIndex: page, timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } else {
      // 纵向：章节级书签——该章已有任意页书签则整体取消
      final match = all.where((b) => b.book.key == '$s::$c' && b.chapterId == ch).toList();
      if (match.isEmpty) {
        await LocalStore.addBookmark(ComicBookmark(
          book: _book, chapterId: ch, chapterTitle: _activeChapterTitle,
          pageIndex: 0, timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
      } else {
        for (final b in match) {
          await LocalStore.removeBookmark(s, c, b.chapterId, b.pageIndex);
        }
      }
    }
    if (!mounted) return;
    setState(() => _bookmarked = !_bookmarked);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_bookmarked ? '已添加书签' : '已取消书签'),
      behavior: SnackBarBehavior.floating,
      width: 180,
      duration: const Duration(milliseconds: 900),
    ));
  }

/// 工具栏切换翻页模式：纵向滚动 → 单页横向 → 双页并排 → 纵向滚动。
  /// 进入/退出横向时保留当前阅读位置（页/视图换算），重建 PageController。
  void _cycleReaderMode() {
    final next = switch (_readerMode) {
      ReaderMode.vertical => ReaderMode.single,
      ReaderMode.single => ReaderMode.double,
      ReaderMode.double => ReaderMode.vertical,
    };
    // 以当前页为锚点换算新模式的初始视图，避免切换后跳回第 0 页。
    final anchorPage = _curPage.clamp(0, _urls.length - 1);
    final nextView = viewOfPage(anchorPage, next);
    _pageCtrl?.dispose();
    _pageCtrl = null;
    setState(() {
      _readerMode = next;
      _doublePage = next == ReaderMode.double;
    });
    if (next != ReaderMode.vertical) {
      // 横向：切模式后重建 controller，帧回调跳转到对应视图。
      _pageCtrl = PageController(initialPage: nextView);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pageCtrl?.jumpToPage(nextView);
      });
    } else {
      // 纵向：滚动到该页对应偏移。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToIndex(anchorPage);
      });
    }
    LocalStore.setReaderMode(next.value);
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
        readerMode: _readerMode,
        dim: _dim,
        resLevel: _resLevel,
        autoPage: _autoPage,
        onDimChanged: (v) {
          _setBrightness(v);
        },
        onModeChanged: (m) {
          // 保持当前阅读页不跳变
          final anchorPage = _curPage.clamp(0, _urls.length - 1);
          _pageCtrl?.dispose();
          _pageCtrl = null;
          setState(() {
            _readerMode = m;
            _doublePage = m == ReaderMode.double;
          });
          if (m != ReaderMode.vertical) {
            final v = viewOfPage(anchorPage, m);
            _pageCtrl = PageController(initialPage: v);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _pageCtrl?.jumpToPage(v);
            });
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToIndex(anchorPage);
            });
          }
          LocalStore.setReaderMode(m.value);
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
            // 双页模式下 PageView 的"页"是视图（两页一屏），按视图跳转。
            final target = viewOfPage(i, _readerMode);
            // controller 可能刚重建尚未 attach（切章节后立即开目录），
            // 无 clients 时 jumpToPage 会抛异常，此时仅更新 _curPage。
            if (_pageCtrl!.hasClients) {
              _pageCtrl!.jumpToPage(target);
            }
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
      // 放大态下双击 = 复位缩放（纵向模式）
      if (_pinchActive) {
        _resetPinch();
        _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);
        _lastTapPos = null;
        return;
      }
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

  /// 执行翻页动画并在完成后复位 _pageAnimating。
  /// 动画被中断（如切章节 dispose controller）时 Future 会抛异常，
  /// try/catch 保证标志一定能复位，避免后续翻页/点击被永久拒绝。
  Future<void> _runPageAnim(Future<void> anim) async {
    try {
      await anim;
    } catch (_) {
      // 动画中断：不处理，兜底定时器会复位
    }
    _pageAnimating = false;
  }

  void _prevPage() {
    _pageAnimating = true;
    if (_horizontal) {
      final c = _pageCtrl;
      if (c != null && c.hasClients) {
        final i = c.page?.round() ?? 0;
        if (i > 0) {
          _runPageAnim(c.animateToPage(i - 1,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut));
        } else {
          _pageAnimating = false;
        }
      } else {
        _pageAnimating = false;
      }
    } else {
      final c = _scrollCtrl;
      if (c != null && c.hasClients) {
        _runPageAnim(c.animateTo(
            (c.offset - 400).clamp(0, c.position.maxScrollExtent),
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut));
      } else {
        _pageAnimating = false;
      }
    }
    // 动画被中断（如切章节 dispose controller）时兜底复位，
    // 避免 _pageAnimating 永久为 true 导致翻页/点击被拒绝。
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _pageAnimating = false;
    });
  }

  void _nextPage() {
    _pageAnimating = true;
    if (_horizontal) {
      final c = _pageCtrl;
      if (c != null && c.hasClients) {
        final i = c.page?.round() ?? 0;
        final maxView = viewCountOf(_urls.length, _readerMode) - 1;
        if (i < maxView) {
          _runPageAnim(c.nextPage(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut));
        } else if (_canContinue) {
          _pageAnimating = false;
          _continueToNextChapter();
        } else {
          _pageAnimating = false;
        }
      } else {
        _pageAnimating = false;
      }
    } else {
      final c = _scrollCtrl;
      if (c != null && c.hasClients) {
        if ((_curPage >= _urls.length - 1) && _canContinue) {
          _pageAnimating = false;
          _continueToNextChapter();
          return;
        }
        _runPageAnim(c.animateTo(
            (c.offset + 400).clamp(0, c.position.maxScrollExtent),
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut));
      } else {
        _pageAnimating = false;
      }
    }
    // 动画被中断（如切章节 dispose controller）时兜底复位，
    // 避免 _pageAnimating 永久为 true 导致翻页/点击被拒绝。
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _pageAnimating = false;
    });
  }

  @override
  void dispose() {
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.removeHandler(_keyHandler);
    }
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
    _cancelLoupe(); // 幂等：清放大镜状态，mounted 为 false 时仅复位字段不 setState
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
    _pageCtrl = null;
    _scrollCtrl?.dispose();
    _scrollCtrl = null;
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
      // PageController 只在首次/切章节时重建，避免每次 setState 重建
      // 导致 PageView 重挂、翻页动画中断、页码跳变。
      if (_pageCtrl == null) {
        // 从纵向切到横向时以当前阅读页为初始页，避免被重置回第 0 页。
        final startPage = widget.initialPage > 0
            ? widget.initialPage.clamp(0, _urls.length - 1)
            : _curPage.clamp(0, _urls.length - 1);
        _pageCtrl = PageController(initialPage: viewOfPage(startPage, _readerMode));
      }
      // 双页模式：视图数 = ceil(页数/2)；末视图为单页时占位右侧。
      final views = viewCountOf(_urls.length, _readerMode);
      return Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: Responsive.readerMaxWidth(context)),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (d) => _onReaderTap(d.localPosition),
            onSecondaryTapDown: (d) => _showReaderMenu(d.globalPosition),
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: views + (_canContinue ? 1 : 0),
              // 翻页时预先保留前后页，避免滑动中销毁重建闪烁。
              // keepAlive 已关闭（防 OOM），靠 cacheExtent 控制保留数量。
              allowImplicitScrolling: true,
          onPageChanged: (view) {
            _markScrolling();
            final page = pageOfView(view, _readerMode);
            if (_doublePage) {
              // 双页：记录左页（lead）作为当前进度页；末视图单页时右页越界。
              setState(() => _curPage = page.clamp(0, _urls.length - 1));
            } else {
              setState(() => _curPage = view.clamp(0, _urls.length - 1));
            }
            _recordHistory();
            if (view >= views && _canContinue) {
              // 读到"下一话"尾页 → 触发连读
              _continueToNextChapter();
              return;
            }
            _prefetch(page + 1);
            _prefetchNextChapter(); // 临近章末时预取下一话
          },
          itemBuilder: (c, view) {
            if (view >= views && _canContinue) {
              return _NextChapterFooter(
                title: _nextChapterTitle ?? _nextChapter()?.title ?? '',
                onTap: _continueToNextChapter,
              );
            }
            if (_doublePage) {
              // 双页视图：左右两页并排，共用视口高度（各占一半宽）。
              final left = view * 2;
              final right = left + 1;
              return Row(
                children: [
                  Expanded(
                    child: _ImageView(_urls[left],
                        pageIndex: left, totalPages: _urls.length,
                        resLevel: _resLevel, horizontal: true,
                        sourceId: widget.sourceId),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: right < _urls.length
                        ? _ImageView(_urls[right],
                            pageIndex: right, totalPages: _urls.length,
                            resLevel: _resLevel, horizontal: true,
                            sourceId: widget.sourceId)
                        : const ColoredBox(color: Colors.black),
                  ),
                ],
              );
            }
            return _ImageView(_urls[view],
                pageIndex: view, totalPages: _urls.length, resLevel: _resLevel,
                horizontal: true, sourceId: widget.sourceId);
          },
        ),
      ),
    ),
  );
  }
    // 纵向滚动：controller 同样只在首次/切章节时创建，避免位置丢失。
    if (_scrollCtrl == null) {
      final sctrl = ScrollController();
      _scrollCtrl = sctrl;
    }
    // 点击空白切换工具栏显隐。GestureDetector 放在 body 内层而非 Stack 顶层，
    // 否则会遮蔽顶部返回/底部工具栏按钮（hit test 自顶向下、命中即止）。
    // 双指缩放由 Stack 顶层 Listener 采集原始指针事件驱动（不参与手势竞技场）。
    return Center(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: Responsive.readerMaxWidth(context)),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (d) => _onReaderTap(d.localPosition),
          onSecondaryTapDown: (d) => _showReaderMenu(d.globalPosition),
          onLongPressStart: _onLongPressStart,
          child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification) {
                  _markScrolling();
                } else if (n is ScrollEndNotification) {
                  _markScrollEnd();
                } else if (n is ScrollUpdateNotification) {
                  // 纵向模式：随滚动更新当前页索引（用于双指缩放的页面定位）
                  final off = _scrollCtrl?.offset ?? 0.0;
                  final visH = MediaQuery.sizeOf(context).height;
                  var acc = 0.0;
                  for (var k = 0; k < _layoutHeights.length; k++) {
                    final h = _layoutHeights[k] ?? 0.0;
                    acc += h;
                    // 页顶已滚出视口且本页底仍可见 → 当前页
                    if (off < acc && off + visH * 0.5 > acc - h) {
                      final target = k;
                      if (target != _curPage) {
                        _curPage = target;
                        _recordHistory();
                        _prefetchNextChapter(); // 临近章末时预取下一话
                        // 视口预载：滚动时按需预取当前页之后若干页字节，
                        // 与首屏预取互补，长章节持续滚动不断流。
                        _prefetch(_curPage + 1);
                      }
                      break;
                    }
                  }
                }
                return false;
              },
              child: ListView.builder(
                controller: _scrollCtrl,
                padding: EdgeInsets.zero,
                // 缓存前后各 900 逻辑像素高度的页面，保证快速回翻不重建。
                scrollCacheExtent: const ScrollCacheExtent.pixels(900),
                itemCount: _urls.length + (_canContinue ? 1 : 0),
                itemBuilder: (c, i) {
                  if (i >= _urls.length && _canContinue) {
                    return _NextChapterFooter(
                      title: _nextChapterTitle ?? _nextChapter()?.title ?? '',
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

  /// 横向翻页：必须关闭 keepAlive——JM 长条图解码后单张可达数十 MB，
  /// PageView 若把已读页全部保留在 Element 树中，翻十几页就 OOM 闪退。
  /// 关闭后由 PageView 的 cacheExtent 保留前后有限页，翻走即销毁释放。
  /// 纵向滚动：保留 keepAlive 但同样要防止无限累积——ListView 的
  /// keepAlive 页面数受 cacheExtent(900px) 限制，超出即销毁，不会无限累积。
  @override
  bool get wantKeepAlive => !widget.horizontal;

  bool get _isJm => widget.sourceId == 'jm';

  /// 是否启用超分。规则：
  /// - 横向翻页禁用（每页提交到串行 Isolate 队列让低端机卡死，且 contain 视角放大有限）；
  /// - JM 源禁用（图床已压缩，Lanczos-3 放大纯增开销、无观感收益，居中文本/网点反而更糊）。
  bool get _superResEnabled =>
      !widget.horizontal && !_isJm && widget.resLevel >= 2;

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
          horizontal: widget.horizontal,
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
          horizontal: widget.horizontal,
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
                minScale: 1.0,
                maxScale: 4.0,
                panEnabled: true,
                scaleEnabled: true,
                // 放大后可在页面内平移查看细节；缩放小于 1 无意义（横向本来就是 contain 适配）。
                boundaryMargin: const EdgeInsets.all(80),
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
  final bool horizontal;
  final VoidCallback onError;
  const _CachedReaderImage({
    required this.url,
    required this.fit,
    required this.filterQuality,
    required this.sourceId,
    required this.superRes,
    this.horizontal = false,
    required this.onError,
  });

  @override
  State<_CachedReaderImage> createState() => _CachedReaderImageState();
}

class _CachedReaderImageState extends State<_CachedReaderImage>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _bytes;
  bool _failed = false;

  /// 与 _ImageView 一致：横向翻页关闭 keepAlive，翻走即销毁释放内存，
  /// 避免长条图在 PageView 中累积导致 OOM。
  @override
  bool get wantKeepAlive => !widget.horizontal;

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

/// 底部悬浮玻璃工具栏（S5：亮度 / 目录 / 翻页模式 / 下载 / 下一章）。
class _ReaderToolbar extends StatelessWidget {
  final bool visible;
  final bool downloaded;
  final bool horizontal;
  final bool doublePage;
  final VoidCallback? onBrightness;
  final VoidCallback onCatalog;
  final VoidCallback onLayout;
  final VoidCallback? onDownload;
  /// 下一章回调；null = 已到最后一章（按钮置灰禁用）。
  final VoidCallback? onNextChapter;
  const _ReaderToolbar({
    required this.visible,
    required this.downloaded,
    required this.horizontal,
    required this.doublePage,
    this.onBrightness,
    required this.onCatalog,
    required this.onLayout,
    this.onDownload,
    this.onNextChapter,
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
                        icon: doublePage
                            ? Icons.view_module_outlined
                            : (horizontal
                                ? Icons.view_carousel_outlined
                                : Icons.view_stream_outlined),
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
                      if (onNextChapter != null) ...[
                        _sep(),
                        _ToolBtn(
                          icon: Icons.skip_next_rounded,
                          onTap: onNextChapter,
                        ),
                      ],
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
  final ReaderMode readerMode;
  final double dim;
  final int resLevel;
  final int autoPage;
  final ValueChanged<double> onDimChanged;
  final ValueChanged<ReaderMode> onModeChanged;
  final ValueChanged<int> onResLevelChanged;
  final ValueChanged<int> onAutoPageChanged;
  final VoidCallback onCatalog;

  /// 章内切换章节（章节列表非空时才可用）。
  final VoidCallback? onSelectChapter;
  final VoidCallback? onDownload;
  const _ReaderSettingsSheet({
    required this.readerMode,
    required this.dim,
    required this.resLevel,
    required this.autoPage,
    required this.onDimChanged,
    required this.onModeChanged,
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
  late ReaderMode _localMode;
  late int _localAutoPage;

  @override
  void initState() {
    super.initState();
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localMode = widget.readerMode;
    _localAutoPage = widget.autoPage;
  }

  @override
  void didUpdateWidget(covariant _ReaderSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localMode = widget.readerMode;
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
              _layoutOption('纵向滚动', _localMode == ReaderMode.vertical, () {
                setState(() => _localMode = ReaderMode.vertical);
                widget.onModeChanged(ReaderMode.vertical);
              }),
              const SizedBox(width: 8),
              _layoutOption('单页横向', _localMode == ReaderMode.single, () {
                setState(() => _localMode = ReaderMode.single);
                widget.onModeChanged(ReaderMode.single);
              }),
              const SizedBox(width: 8),
              _layoutOption('双页并排', _localMode == ReaderMode.double, () {
                setState(() => _localMode = ReaderMode.double);
                widget.onModeChanged(ReaderMode.double);
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