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
  List<HistoryEntry> _recent = [];
  List<VideoRecord> _videos = [];
  int _tab = 0; // 0=最近在读 1=全部收藏 2=动画记录
  bool _loading = true;
  bool _refreshing = false;
  bool _editing = false; // 收藏网格的编辑（删除）模式

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
        else if (_tab == 1)
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
                  final item = _items[i];
                  return FadeSlideIn(
                    delay: Duration(milliseconds: 50 * (i % 12)),
                    offset: 16,
                    child: _ShelfCard(
                      item: item,
                      editing: _editing,
                      onTap: () => _editing ? _remove(item) : _open(item),
                    ),
                  );
                },
                childCount: _items.length,
              ),
            ),
          )
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

  /// 由书架 chapters 计算最近在读进度（读到第?/共?话 → 百分比）。
  double _progressOf(HistoryEntry h) {
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
