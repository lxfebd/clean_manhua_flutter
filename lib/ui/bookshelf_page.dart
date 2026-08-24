import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/bookshelf_store.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'anime_player_page.dart';
import 'detail_page.dart';
import 'native_player_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

/// 书架页：跨源聚合，按时间倒序。错峰入场。
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => BookshelfPageState();
}

class BookshelfPageState extends State<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  List<ComicDetail> _items = [];
  List<ComicDetail> _filtered = [];
  List<HistoryEntry> _recent = [];
  List<VideoRecord> _videos = [];
  int _tab = 0;
  bool _loading = true;
  bool _refreshing = false;
  bool _editing = false;
  String? _tagFilter;
  List<String> _allTags = [];
  int _updateCount = 0;
  bool _checkingUpdate = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    if (mounted) {
      setState(() =>
          _loading = _items.isEmpty && _recent.isEmpty && _videos.isEmpty);
    }
    try {
      final list = BookshelfStore.listAll();
      final hist = await LocalStore.history();
      final videos = await LocalStore.videoRecords();
      if (mounted) {
        setState(() {
          _items = list;
          _filtered = _tagFilter == null
              ? list
              : list.where((d) {
                  final sid = BookshelfStore.sourceIdOf(d.id) ?? '';
                  return BookshelfStore.tagsOf(sid, d.id).contains(_tagFilter);
                }).toList();
          _allTags = BookshelfStore.allTags();
          _recent = hist;
          _videos = videos;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _refreshing = true);
    await reload();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Row(
                children: [
                  Text(
                    '书架',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_items.length} 部',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                  if (_updateCount > 0)
                    GestureDetector(
                      onTap: _checkUpdates,
                      child: Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$_updateCount 更新',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: scheme.error,
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (_items.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => _editing = !_editing),
                      child: Text(
                        _editing ? '完成' : '编辑',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: _editing
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: _editing
                              ? scheme.primary
                              : scheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _refreshing ? null : _onRefresh,
                    icon: AnimatedRotation(
                      turns: _refreshing ? 1 : 0,
                      duration: const Duration(milliseconds: 900),
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 22,
                        color: scheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(child: _tabBar()),
        if (_tab == 0)
          if (_recent.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: _TabEmpty(
                  icon: Icons.history_rounded,
                  text: '最近还没有阅读记录',
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
              sliver: SliverList.separated(
                itemCount: _recent.length > 6 ? 6 : _recent.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (c, i) => _ReadingCard(
                  history: _recent[i],
                  progress: _progressOf(_recent[i]),
                  onTap: () => _openFromHistory(_recent[i]),
                ),
              ),
            )
        else if (_tab == 1) ...[
          if (_items.isNotEmpty && _allTags.isNotEmpty)
            SliverToBoxAdapter(child: _tagChips()),
          if (_items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: _TabEmpty(
                  icon: Icons.bookmark_outline_rounded,
                  text: '书架还是空的，去首页收藏几部吧',
                ),
              ),
            )
          else if (_filtered.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 80),
                child: _TabEmpty(
                  icon: Icons.filter_alt_off_rounded,
                  text: '没有匹配「$_tagFilter」标签的作品',
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 110),
              sliver: SliverGrid(
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 112,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.6,
                ),
                delegate: SliverChildBuilderDelegate(
                  (c, i) {
                    final item = _filtered[i];
                    return RepaintBoundary(
                      child: FadeSlideIn(
                        delay: Duration(milliseconds: 50 * (i % 12)),
                        offset: 16,
                        child: _ShelfCard(
                          item: item,
                          editing: _editing,
                          onTap: () => _editing
                              ? _showCardAction(item)
                              : _open(item),
                        ),
                      ),
                    );
                  },
                  childCount: _filtered.length,
                ),
              ),
            ),
        ]
        else if (_videos.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 80),
              child: _TabEmpty(
                icon: Icons.ondemand_video_rounded,
                text: '还没有动画观看记录',
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 110),
            sliver: SliverList.separated(
              itemCount: _videos.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (c, i) => _VideoRecordCard(
                record: _videos[i],
                onTap: () => _openVideoRecord(_videos[i]),
                onDelete: () => _deleteVideoRecord(_videos[i]),
              ),
            ),
          ),
      ],
    );
  }

  /// 由书架 chapters + 历史页码计算阅读进度：优先精确页码比例。
  double _progressOf(HistoryEntry h) {
    // 有精确页码：pageIndex / chapterTotalPages
    if (h.hasPage && h.chapterTotalPages > 0 && h.pageIndex >= 0) {
      return ((h.pageIndex + 1) / h.chapterTotalPages).clamp(0.0, 1.0);
    }
    for (final d in _items) {
      if (d.id != h.book.comicId) continue;
      if (d.chapters.isEmpty) return 0;
      final idx = d.chapters.indexWhere((c) => c.id == h.chapterId);
      if (idx < 0) {
        // 找不到章节，按最近在读的第 30% 估算，避免 0 显得突兀
        return 0.3;
      }
      return ((idx + 1) / d.chapters.length).clamp(0.0, 1.0);
    }
    return 0.3;
  }

  Future<void> _remove(ComicDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('移出书架'),
        content: Text('确定将「${d.name}」移出书架吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final sid = BookshelfStore.sourceIdOf(d.id);
    if (sid == null) {
      await reload();
      return;
    }
    BookshelfStore.remove(sid, d.id);
    await reload();
  }

  Widget _tagChips() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
        children: [
          _tagChip('全部', _tagFilter == null, () {
            setState(() => _tagFilter = null);
            _refilter();
          }, scheme),
          const SizedBox(width: 8),
          for (final t in _allTags) ...[
            _tagChip(t, _tagFilter == t, () {
              setState(() => _tagFilter = t);
              _refilter();
            }, scheme),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _tagChip(String label, bool active, VoidCallback onTap, ColorScheme scheme) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? Colors.white : scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  void _refilter() {
    setState(() {
      _filtered = _tagFilter == null
          ? _items
          : _items.where((d) {
              final sid = BookshelfStore.sourceIdOf(d.id) ?? '';
              return BookshelfStore.tagsOf(sid, d.id).contains(_tagFilter);
            }).toList();
    });
  }

  /// 检查所有收藏漫画是否有新章节更新。
  Future<void> _checkUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    var newCount = 0;
    for (final d in _items) {
      final sid = BookshelfStore.sourceIdOf(d.id) ?? SourceManager.current.id;
      final source = SourceManager.byId(sid);
      try {
        final detail = await source.detail(d.id).timeout(const Duration(seconds: 10));
        final cur = detail.chapters.length;
        final hadNew = BookshelfStore.hasUpdate(sid, d.id, cur);
        BookshelfStore.setLastSeenChapters(sid, d.id, cur);
        if (hadNew) newCount++;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _updateCount = newCount;
        _checkingUpdate = false;
      });
      if (newCount == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('所有收藏已是最新')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发现 $newCount 部作品有更新')),
        );
      }
    }
  }

  /// 编辑模式下点卡片：弹「设置标签 / 移出书架」操作。
  Future<void> _showCardAction(ComicDetail d) async {
    final sid = BookshelfStore.sourceIdOf(d.id) ?? '';
    final current = List<String>.from(BookshelfStore.tagsOf(sid, d.id));
    final updated = await showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: const Color(0xFF0F1013),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _TagEditorSheet(
        title: d.name,
        current: current,
        allTags: BookshelfStore.allTags(),
      ),
    );
    if (updated == null) return;
    if (!mounted) return;
    if (updated.length == 1 && updated.first == '__delete__') {
      _remove(d);
      return;
    }
    BookshelfStore.setTags(sid, d.id, updated);
    setState(() => _allTags = BookshelfStore.allTags());
    _refilter();
    if (current.isEmpty && updated.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已为「${d.name}」添加标签：${updated.join('、')}'),
          duration: const Duration(milliseconds: 1500),
        ),
      );
    }
  }

  Widget _tabBar() {
    final scheme = Theme.of(context).colorScheme;
    Widget tab(String label, int i) {
      final active = _tab == i;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab = i),
        child: Container(
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      child: Row(
        children: [
          tab('最近在读', 0),
          const SizedBox(width: 22),
          tab('全部收藏', 1),
          const SizedBox(width: 22),
          tab('动画记录', 2),
        ],
      ),
    );
  }

  void _openFromHistory(HistoryEntry h) {
    ComicDetail? match;
    for (final d in _items) {
      if (d.id == h.book.comicId) {
        match = d;
        break;
      }
    }
    if (match != null) {
      _open(match);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该漫画未在书架，请到首页搜索进入')),
      );
    }
  }

  /// 从「动画记录」续播：按源 id + 番剧 id 重新解析播放链，
  /// 直链进原生播放器（Anime4K 超分），iframe 页先进 WebView 捕获直链。
  Future<void> _openVideoRecord(VideoRecord r) async {
    final source = SourceManager.videoById(r.sourceId);
    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该播放源已下线，无法续播')),
      );
      return;
    }
    HapticFeedback.selectionClick();
    try {
      final url = await source.playUrl(r.videoId, r.season, r.episode);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => isDirectMediaUrl(url)
              ? NativePlayerPage(
                  url: url,
                  title: r.title,
                  cover: r.cover,
                  episodes: const [],
                  season: r.season,
                  episode: r.episode,
                  resolveUrl: (s, e) => source.playUrl(r.videoId, s, e),
                  sourceId: r.sourceId,
                  videoId: r.videoId,
                  historyKey: r.key,
                )
              : AnimePlayerPage(
                  url: url,
                  title: r.title,
                  cover: r.cover,
                  episodes: const [],
                  initialSeason: r.season,
                  initialEpisode: r.episode,
                  resolveUrl: (s, e) => source.playUrl(r.videoId, s, e),
                  sourceId: r.sourceId,
                  videoId: r.videoId,
                ),
        ),
      );
      reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('续播失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteVideoRecord(VideoRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('删除记录'),
        content: Text('移除「${r.title}」的观看记录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LocalStore.removeVideoRecord(r.key);
    await reload();
  }

  void _open(ComicDetail d) {
    HapticFeedback.selectionClick();
    final sid = BookshelfStore.sourceIdOf(d.id) ?? SourceManager.current.id;
    final source = SourceManager.byId(sid);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: source.id,
          comicId: d.id,
          name: d.name,
          pic: d.pic,
        ),
      ),
    ).then((_) => reload());
  }
}

class _ShelfCard extends StatefulWidget {
  final ComicDetail item;
  final VoidCallback onTap;
  final bool editing;
  const _ShelfCard({
    required this.item,
    required this.onTap,
    this.editing = false,
  });

  @override
  State<_ShelfCard> createState() => _ShelfCardState();
}

class _ShelfCardState extends State<_ShelfCard> {
  bool _hover = false;

  /// 是否有更新角标。
  bool get _hasUpdate {
    // 需要 sourceId 和 comicId，但 widget.item 只有 id。
    // 通过 BookshelfStore 反向查找。
    final sid = BookshelfStore.sourceIdOf(widget.item.id);
    if (sid == null) return false;
    final cur = widget.item.chapters.length;
    return BookshelfStore.hasUpdate(sid, widget.item.id, cur);
  }

  Widget _updateBadge() {
    if (!_hasUpdate) return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 6,
      right: 6,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: scheme.error,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: scheme.error.withValues(alpha: 0.5),
              blurRadius: 4,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()..translate(0.0, _hover ? -4 : 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.22),
                      blurRadius: 18,
                      spreadRadius: -3,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : const [
                    BoxShadow(
                      color: Color(0x10000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Opacity(
              opacity: widget.editing ? 0.72 : 1,
              child: Container(
                color: scheme.surface,
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: CachedImage(
                                    widget.item.pic ?? '',
                                    fit: BoxFit.cover,
                                    radius: 0),
                              ),
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: Container(
                                  height: 30,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black
                                            .withValues(alpha: 0.55),
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 6,
                                left: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black
                                        .withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    widget.item.comic.author ?? '',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              _updateBadge(),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                          child: Text(
                            widget.item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: widget.editing
                                  ? scheme.onSurface.withValues(alpha: 0.55)
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (widget.editing)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: widget.onTap,
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.primary,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 4,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 15,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 正在读卡片（UI_v2 S7）：封面 60x84 + 标题 + 读到第N话 + 进度条 + 时间
class _ReadingCard extends StatelessWidget {
  final HistoryEntry history;
  final VoidCallback onTap;
  final double progress;
  const _ReadingCard({
    required this.history,
    required this.onTap,
    this.progress = 0.3,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = history.book;
    final ago = _ago(history.timestamp);
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 60,
                  height: 84,
                  child: (b.pic.isEmpty)
                      ? Container(color: scheme.surfaceContainerHighest)
                      : CachedImage(b.pic, fit: BoxFit.cover, radius: 0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (history.chapterTitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '读到 ${history.chapterTitle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 4,
                              color: scheme.primary,
                              backgroundColor: scheme.primary
                                  .withValues(alpha: 0.15),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(progress * 100).round()}%',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      ago,
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _ago(int ms) {
    if (ms == 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inDays > 30) return '很久以前';
    if (d.inDays >= 1) return '${d.inDays} 天前';
    if (d.inHours >= 1) return '${d.inHours} 小时前';
    if (d.inMinutes >= 1) return '${d.inMinutes} 分钟前';
    return '刚刚';
  }
}

/// 动画观看记录卡片：封面 16:9 + 标题 + 集数/进度 + 时间，支持长按删除。
class _VideoRecordCard extends StatelessWidget {
  final VideoRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _VideoRecordCard({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = record.duration > 0
        ? (record.seconds / record.duration).clamp(0.0, 1.0)
        : 0.0;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onDelete,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 72,
                  height: 90,
                  child: (record.cover == null || record.cover!.isEmpty)
                      ? Container(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(Icons.ondemand_video_rounded,
                              size: 28,
                              color: scheme.onSurface.withValues(alpha: 0.25)),
                        )
                      : CachedImage(record.cover!,
                          fit: BoxFit.cover, radius: 0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '第${record.episode}集',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 4,
                              color: scheme.primary,
                              backgroundColor:
                                  scheme.primary.withValues(alpha: 0.15),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(progress * 100).round()}%',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _ago(record.timestamp),
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(int ms) {
    if (ms == 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inDays > 30) return '很久以前';
    if (d.inDays >= 1) return '${d.inDays} 天前';
    if (d.inHours >= 1) return '${d.inHours} 小时前';
    if (d.inMinutes >= 1) return '${d.inMinutes} 分钟前';
    return '刚刚';
  }
}

/// tab 空态（用于"最近在读"无记录时）。
class _TabEmpty extends StatelessWidget {
  final IconData icon;
  final String text;
  const _TabEmpty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: scheme.onSurface.withValues(alpha: 0.1)),
            ),
            child: Icon(icon,
                size: 28, color: scheme.onSurface.withValues(alpha: 0.25)),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class AnimatedRotation extends StatefulWidget {
  final double turns;
  final Duration duration;
  final Widget child;
  const AnimatedRotation({
    super.key,
    required this.turns,
    required this.duration,
    required this.child,
  });

  @override
  State<AnimatedRotation> createState() => _AnimatedRotationState();
}

class _AnimatedRotationState extends State<AnimatedRotation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    if (widget.turns != 0) {
      _c.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedRotation old) {
    super.didUpdateWidget(old);
    if (widget.turns != old.turns) {
      if (widget.turns == 0) {
        _c.stop();
      } else {
        _c.repeat();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: Tween(begin: 0.0, end: widget.turns).animate(
        CurvedAnimation(parent: _c, curve: Curves.linear),
      ),
      child: widget.child,
    );
  }
}

/// 标签编辑底部抽屉：多选标签，底部固定「移出书架」。
class _TagEditorSheet extends StatefulWidget {
  final String title;
  final List<String> current;
  final List<String> allTags;
  const _TagEditorSheet({
    required this.title,
    required this.current,
    required this.allTags,
  });

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.current);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
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
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text('完成'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 10,
              children: List.generate(widget.allTags.length, (i) {
                final t = widget.allTags[i];
                final active = _selected.contains(t);
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (active) {
                        _selected.remove(t);
                      } else {
                        _selected.add(t);
                      }
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          t,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: active ? Colors.white : Colors.white70,
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.check_rounded,
                              size: 14, color: Colors.white.withValues(alpha: 0.8)),
                        ],
                      ],
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  side: BorderSide(color: scheme.error.withValues(alpha: 0.3)),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('移出书架'),
                onPressed: () => Navigator.pop(context, ['__delete__']),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
