import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../net/download_manager.dart';
import '../net/image_cache.dart';
import '../net/local_store.dart';
import '../sources/source_manager.dart';
import 'widgets/jm_scramble_image.dart';

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
      final urls = await SourceManager.current.chapterPics(widget.chapterId);
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
  void _prefetch(int from) {
    for (var k = from; k < from + 3 && k < _urls.length; k++) {
      final u = _urls[k];
      if (u.startsWith('/') || u.contains('@')) continue;
      ImageCacheManager.preload(u);
    }
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
    final _ = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        actions: [
          if (_horizontal)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Text('${_curPage + 1} / ${_urls.length}',
                    style: const TextStyle(fontSize: 13, color: Colors.white70)),
              ),
            ),
          IconButton(
            icon: Icon(_downloaded ? Icons.download_done : Icons.download),
            tooltip: _downloaded ? '已下载' : '下载本话',
            onPressed: _downloading ? null : _download,
          ),
          IconButton(
            icon: Icon(
                _horizontal ? Icons.view_column_rounded : Icons.view_stream_rounded),
            tooltip: _horizontal ? '切到纵向滚动' : '切到横向翻页',
            onPressed: () {
              setState(() => _horizontal = !_horizontal);
              LocalStore.setHorizontalReader(_horizontal);
            },
          ),
          IconButton(
            icon: Icon(
                _resLevel == 2 ? Icons.hd_rounded : _resLevel == 1 ? Icons.hd_outlined : Icons.auto_awesome),
            tooltip: _resLevel == 2 ? '超清·质量（可能卡）' : _resLevel == 1 ? '超清·性能' : '关',
            color: _resLevel > 0 ? Theme.of(context).colorScheme.primary : null,
            onPressed: () => setState(() => _resLevel = (_resLevel + 1) % 3),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (_urls.isEmpty) {
      return const Center(
          child: Text('暂不支持该源阅读（图片解析接入中），请切换源或换章节',
              style: TextStyle(color: Colors.white54)));
    }
    if (_horizontal) {
      return PageView.builder(
        itemCount: _urls.length,
        onPageChanged: (idx) {
          setState(() => _curPage = idx);
          _prefetch(idx + 1);
        },
        itemBuilder: (c, i) => _ImageView(_urls[i],
            pageIndex: i, totalPages: _urls.length, resLevel: _resLevel,
            horizontal: true, sourceId: widget.sourceId),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _urls.length,
      itemBuilder: (c, i) => _ImageView(_urls[i],
          pageIndex: i, totalPages: _urls.length, resLevel: _resLevel,
          sourceId: widget.sourceId),
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
      // 禁漫图片：部分带 @scramble 标记；且 aid ≥ 220980 的图做过分块倒序混淆，
      // 需下载后按 JMComic 算法还原（JmScramble.descramble 内部从 URL 解析 aid，
      // 无 aid 时原样显示，安全回退）。
      img = JmScrambleImageWidget(
        url: widget.url,
        fit: fit,
        filterQuality: _filterLevel(),
      );
    } else {
      // 普通网络图：走内存+磁盘缓存，首次加载后秒开/离线可看
      img = _CachedReaderImage(
        url: widget.url,
        fit: fit,
        filterQuality: _filterLevel(),
        onError: () {
          Future.microtask(() {
            if (mounted) setState(() => _error = true);
          });
        },
      );
    }

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
        widget.horizontal
            ? Expanded(child: img)
            : img,
      ],
    );
  }
}

/// 阅读页普通网络图：走 ImageCacheManager（内存+磁盘），带进度与错误回调。
class _CachedReaderImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final VoidCallback onError;
  const _CachedReaderImage({
    required this.url,
    required this.fit,
    required this.filterQuality,
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

  Future<void> _load() async {
    setState(() {
      _bytes = null;
      _failed = false;
    });
    try {
      final b = await ImageCacheManager.load(widget.url);
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