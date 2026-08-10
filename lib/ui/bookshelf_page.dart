import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/bookshelf_store.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'detail_page.dart';
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
  int _tab = 0; // 0=最近在读 1=全部收藏
  bool _loading = true;
  bool _refreshing = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    if (mounted) setState(() => _loading = _items.isEmpty && _recent.isEmpty);
    try {
      final list = BookshelfStore.listAll();
      final hist = await LocalStore.history();
      if (mounted) {
        setState(() {
          _items = list;
          _recent = hist;
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
    final isEmpty = _items.isEmpty && _recent.isEmpty;
    if (isEmpty) return _EmptyShelf();
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
                  onTap: () => _openFromHistory(_recent[i]),
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
                (c, i) => FadeSlideIn(
                  delay: Duration(milliseconds: 50 * (i % 12)),
                  offset: 16,
                  child: _ShelfCard(
                    item: _items[i],
                    onTap: () => _open(_items[i]),
                  ),
                ),
                childCount: _items.length,
              ),
            ),
          ),
      ],
    );
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
                color: active ? scheme.onSurface : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.45),
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

  void _open(ComicDetail d) {
    HapticFeedback.selectionClick();
    final source = SourceManager.byId(d.id);
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
  const _ShelfCard({required this.item, required this.onTap});

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
            child: Container(
              color: scheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CachedImage(widget.item.pic ?? '',
                              fit: BoxFit.cover, radius: 0),
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
                                  Colors.black.withValues(alpha: 0.55),
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
                              color: Colors.black.withValues(alpha: 0.6),
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
                        color: scheme.onSurface,
                      ),
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
}

class _EmptyShelf extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutBack,
            builder: (_, v, child) => Transform.scale(scale: v, child: child),
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: scheme.onSurface.withValues(alpha: 0.1)),
              ),
              child: Icon(
                Icons.bookmark_outline_rounded,
                size: 36,
                color: scheme.onSurface.withValues(alpha: 0.25),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '书架空空如也',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '打开任意漫画详情页，点击右上角收藏加入',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// 正在读卡片（UI_v2 S7）：封面 60x84 + 标题 + 读到第N话 + 时间
class _ReadingCard extends StatelessWidget {
  final HistoryEntry history;
  final VoidCallback onTap;
  const _ReadingCard({required this.history, required this.onTap});

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
