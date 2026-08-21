import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/download_manager.dart';
import '../net/image_cache.dart';
import '../net/local_store.dart';
import '../sources/source_manager.dart';
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

  const ReaderPage({
    super.key,
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.title,
    required this.comicName,
    required this.comicPic,
    this.comicAuthor = '',
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  List<String> _urls = [];
  bool _loading = true;
  bool _horizontal = false;
  bool _downloaded = false;
  bool _downloading = false;
  int _curPage = 0;
  int _resLevel = 0; // 0=无, 1=性能, 2=质量
  bool _overlay = true; // 顶部/底部工具栏是否显示
  double _dim = 0.0; // 亮度（暗化模拟），0.0~1.0
  Timer? _hideTimer;

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
    _init();
  }

  Future<void> _init() async {
    _horizontal = await LocalStore.horizontalReader();
    _resLevel = await LocalStore.resLevel();
    _downloaded = await DownloadManager.isDownloaded(_book.key, widget.chapterId);
    _recordHistory();
    _load();
  }

  Future<void> _recordHistory() async {
    await LocalStore.recordHistory(HistoryEntry(
      book: _book,
      chapterId: widget.chapterId,
      chapterTitle: widget.title,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> _load() async {
    try {
      final urls = await SourceManager.byId(widget.sourceId)
          .chapterPics(widget.chapterId);
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
          _loading = false;
        });
      }
      _prefetch(0);
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
      if (u.startsWith('/') || u.contains('@')) continue;
      ImageCacheManager.preload(u, headers: _headersForUrl(u));
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

  Future<void> _download() async {
    if (_downloading || _urls.isEmpty) return;
    setState(() => _downloading = true);
    try {
      final ok = await DownloadManager.downloadChapter(
        book: _book,
        chapterId: widget.chapterId,
        chapterTitle: widget.title,
        urls: _urls,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() {});
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
    return Scaffold(
      backgroundColor: Colors.black,
      // 注意：Scaffold body 给的是宽松约束，Stack 会按非 positioned 子节点
      // （顶部栏）收缩到极矮，导致 ListView 只有顶部一条、底部工具栏跑到顶部。
      // 用 SizedBox.expand 强制 Stack 铺满全屏。
      body: SizedBox.expand(
        child: Stack(
          children: [
          Positioned.fill(child: _buildBody()),
          // 亮度（暗化）层
          AnimatedOpacity(
            duration: const Duration(milliseconds: 220),
            opacity: _dim * 0.45,
            child: const ColoredBox(color: Colors.black),
          ),
          // 顶部工具栏（返回/标题/菜单）
          _ReaderTopBar(
            visible: _overlay,
            title: widget.title,
            onBack: () {
              HapticFeedback.selectionClick();
              Navigator.maybePop(context);
            },
            onMenu: () => _showReaderSettings(),
          ),
          // 底部页码（横向翻页时显示 x / N，纵向整体显示 N 页）
          _ReaderPageIndicator(
            visible: _overlay && _horizontal,
            label: '${_curPage + 1} / ${_urls.length}',
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.6),
      barrierColor: Colors.transparent,
      builder: (_) => _ReaderSettingsSheet(
        horizontal: _horizontal,
        dim: _dim,
        resLevel: _resLevel,
        onDimChanged: (v) {
          setState(() => _dim = v);
        },
        onLayoutChanged: (h) {
          setState(() => _horizontal = h);
          LocalStore.setHorizontalReader(h);
        },
        onResLevelChanged: (v) {
          setState(() => _resLevel = v);
          LocalStore.setResLevel(v);
        },
        onCatalog: () {
          Navigator.pop(context);
          _showCatalog();
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

  /// 目录：章节内页目录（横向翻页时切换页面）。
  void _showCatalog() {
    _hideTimer?.cancel();
    setState(() => _overlay = true);
    showModalBottomSheet<void>(
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

  void _scrollToIndex(int i) {
    _scrollCtrl?.animateTo(
      i * 560.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
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
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleOverlay,
        child: PageView.builder(
          controller: ctrl,
          itemCount: _urls.length,
          onPageChanged: (idx) {
            setState(() => _curPage = idx);
            _prefetch(idx + 1);
          },
          itemBuilder: (c, i) => _ImageView(_urls[i],
              pageIndex: i, totalPages: _urls.length, resLevel: _resLevel,
              horizontal: true, sourceId: widget.sourceId),
        ),
      );
    }
    _scrollCtrl?.dispose();
    final sctrl = ScrollController();
    _scrollCtrl = sctrl;
    // 点击空白切换工具栏显隐。GestureDetector 放在 body 内层而非 Stack 顶层，
    // 否则会遮蔽顶部返回/底部工具栏按钮（hit test 自顶向下、命中即止）。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _toggleOverlay,
      child: ListView.builder(
        controller: sctrl,
        padding: EdgeInsets.zero,
        itemCount: _urls.length,
        itemBuilder: (c, i) => _ImageView(_urls[i],
            pageIndex: i, totalPages: _urls.length, resLevel: _resLevel,
            sourceId: widget.sourceId),
      ),
    );
  }
}

class _ImageView extends StatefulWidget {
  final String url;
  final int pageIndex;
  final int totalPages;
  final int resLevel;
  final bool horizontal;
  final String sourceId;
  const _ImageView(this.url,
      {required this.pageIndex, required this.totalPages, required this.resLevel,
      this.horizontal = false, this.sourceId = ''});

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView> {
  bool _error = false;

  bool get _isJm => widget.sourceId == 'jm';

  FilterQuality _filterLevel() {
    switch (widget.resLevel) {
      case 0:
        return FilterQuality.none;
      case 1:
        return FilterQuality.low;
      case 2:
        return FilterQuality.high;
      default:
        return FilterQuality.none;
    }
  }

  @override
  Widget build(BuildContext context) {
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
      img = Image.file(
          File(widget.url),
          width: double.infinity,
          fit: fit,
          filterQuality: _filterLevel(),
          errorBuilder: (c, e, s) {
            Future.microtask(() {
              if (mounted) setState(() => _error = true);
            });
            return const SizedBox();
          },
        );
    } else if (widget.url.contains('@') || _isJm) {
      img = JmScrambleImageWidget(
        url: widget.url,
        fit: fit,
        filterQuality: _filterLevel(),
      );
    } else {
      img = _CachedReaderImage(
        url: widget.url,
        fit: fit,
        filterQuality: _filterLevel(),
        sourceId: widget.sourceId,
        onError: () {
          Future.microtask(() {
            if (mounted) setState(() => _error = true);
          });
        },
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
          Expanded(child: img),
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
  final VoidCallback onError;
  const _CachedReaderImage({
    required this.url,
    required this.fit,
    required this.filterQuality,
    required this.sourceId,
    required this.onError,
  });

  @override
  State<_CachedReaderImage> createState() => _CachedReaderImageState();
}

class _CachedReaderImageState extends State<_CachedReaderImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 部分图源 CDN 需要 Referer 头才返回图片（如 dm5 的 cdndm5.com），
  /// 否则返回 403/404 导致「图片加载失败」。与 _prefetch 保持一致的 headers。
  Map<String, String>? _headers() => _ReaderPageState._headersForUrl(widget.url);

  Future<void> _load() async {
    setState(() {
      _bytes = null;
      _failed = false;
    });
    try {
      final b =
          await ImageCacheManager.load(widget.url, headers: _headers());
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
        widget.onError();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const SizedBox(
        width: double.infinity,
        height: 200,
        child: Center(
          child: Text('加载失败', style: TextStyle(color: Colors.white38)),
        ),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(
        width: double.infinity,
        height: 240,
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }
    return Image.memory(
      bytes,
      width: double.infinity,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
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
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
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
        margin: const EdgeInsets.symmetric(horizontal: 14),
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

/// 阅读设置抽屉（S6）：亮度滑块 + 翻页模式 + 目录/下载。
class _ReaderSettingsSheet extends StatefulWidget {
  final bool horizontal;
  final double dim;
  final int resLevel;
  final ValueChanged<double> onDimChanged;
  final ValueChanged<bool> onLayoutChanged;
  final ValueChanged<int> onResLevelChanged;
  final VoidCallback onCatalog;
  final VoidCallback? onDownload;
  const _ReaderSettingsSheet({
    required this.horizontal,
    required this.dim,
    required this.resLevel,
    required this.onDimChanged,
    required this.onLayoutChanged,
    required this.onResLevelChanged,
    required this.onCatalog,
    this.onDownload,
  });

  @override
  State<_ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<_ReaderSettingsSheet> {
  late double _localDim;
  late int _localResLevel;
  late bool _localHorizontal;

  @override
  void initState() {
    super.initState();
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localHorizontal = widget.horizontal;
  }

  @override
  void didUpdateWidget(covariant _ReaderSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localHorizontal = widget.horizontal;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
      decoration: const BoxDecoration(
        color: Color(0xFF0F1013),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
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
          Text('阅读设置',
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: 18),
          // 亮度
          Row(
            children: [
              const Icon(Icons.light_mode_rounded,
                  size: 16, color: Colors.white70),
              const SizedBox(width: 10),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: const Color(0xFF3A6EA5),
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
          // 画质（超分辨率）
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
              _resOption('高清', 2, _localResLevel, () {
                setState(() => _localResLevel = 2);
                widget.onResLevelChanged(2);
              }),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '提升放大后的线条锐度，可在线/离线切换',
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
              if (widget.onDownload != null)
                Expanded(
                  child: _ghostBtn('下载本话', Icons.download_outlined,
                      () => widget.onDownload!()),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _layoutOption(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF3A6EA5)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? const Color(0xFF3A6EA5)
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
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF3A6EA5)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? const Color(0xFF3A6EA5)
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
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        decoration: const BoxDecoration(
          color: Color(0xFF14161B),
          borderRadius: BorderRadius.all(Radius.circular(24)),
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
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
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
                            ? const Color(0xFF3A6EA5)
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