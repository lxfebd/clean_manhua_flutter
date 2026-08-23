import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import '../net/download_manager.dart';
import '../net/local_store.dart';
import 'reader_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

/// 漫画详情页：沉浸式 Hero 头 + 信息卡 + 章节网格。
class DetailPage extends StatefulWidget {
  final String sourceId;
  final String comicId;
  final String? name;
  final String? pic;
  const DetailPage({
    super.key,
    required this.sourceId,
    required this.comicId,
    this.name,
    this.pic,
  });

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  ComicDetail? _detail;
  bool _loading = true;
  String? _error;
  final _scrollCtrl = ScrollController();
  bool _saved = false;
  double _scrollOffset = 0;
  bool _descending = false; // 章节倒序（最新在顶部）

  static const double _heroHeight = 260;

  @override
  void initState() {
    super.initState();
    _checkSaved();
    _load();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.hasClients) {
      final v = _scrollCtrl.offset.clamp(0.0, _heroHeight);
      if (v != _scrollOffset) setState(() => _scrollOffset = v);
    }
  }

  Future<void> _checkSaved() async {
    final v = await SourceManager.byId(widget.sourceId)
        .isInBookshelf(widget.comicId);
    if (mounted) setState(() => _saved = v);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await SourceManager.byId(widget.sourceId)
          .detail(widget.comicId)
          .timeout(const Duration(seconds: 30));
      if (mounted) {
        setState(() {
          _detail = d;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败：$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mq = MediaQuery.of(context);
    final name = _detail?.name ?? widget.name ?? '加载中…';
    final pic = _detail?.pic ?? widget.pic;
    final topPad = mq.padding.top;
    final heroH = _heroHeight + topPad;
    final collapseProgress = (_scrollOffset / _heroHeight).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          // ── 可滚动内容 ────────────────────────────────────────
          CustomScrollView(
            controller: _scrollCtrl,
            physics: const BouncingScrollPhysics(),
            slivers: [
              // 给 Hero 留出空间
              SliverToBoxAdapter(
                child: SizedBox(height: heroH),
              ),

              // ── 加载态 ──────────────────────────────────────
              if (_loading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: 60),
                    child: _LoadingView(),
                  ),
                )
              else if (_error != null)
                SliverToBoxAdapter(
                  child: _ErrorView(error: _error!, onRetry: _load),
                )
              else if (_detail != null) ...[
                // 信息区（封面 + 标题 + 徽章 + 操作按钮）
                SliverToBoxAdapter(
                  child: FadeSlideIn(
                    delay: const Duration(milliseconds: 100),
                    offset: 14,
                    child: _MetaSection(
                      detail: _detail!,
                      saved: _saved,
                      onRead: _detail!.chapters.isEmpty
                          ? null
                          : () => _openChapter(_detail!.chapters.first),
                      onShelf: _toggleSave,
                    ),
                  ),
                ),
                // 简介
                if ((_detail!.description ?? '').isNotEmpty)
                  SliverToBoxAdapter(
                    child: FadeSlideIn(
                      delay: const Duration(milliseconds: 180),
                      offset: 14,
                      child: _DescCard(detail: _detail!),
                    ),
                  ),
                // 章节标题
                SliverToBoxAdapter(
                  child: FadeSlideIn(
                    delay: const Duration(milliseconds: 260),
                    child: _ChapterHeader(
                    count: _detail!.chapters.length,
                    descending: _descending,
                    onToggleDescending: () =>
                        setState(() => _descending = !_descending),
                    onTapAll: _showAllChapters,
                  ),
                  ),
                ),
                // 章节列表（卡片行）
                SliverToBoxAdapter(
                  child: FadeSlideIn(
                    delay: const Duration(milliseconds: 300),
                    offset: 14,
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: scheme.onSurface.withValues(alpha: 0.06)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var i = 0; i < _detail!.chapters.length &&
                              i < 6; i++) ...[
                            if (i > 0)
                              Divider(
                                  height: 0.5,
                                  indent: 16,
                                  endIndent: 16,
                                  color: scheme.onSurface
                                      .withValues(alpha: 0.06)),
                            _ChapterTile(
                              index: i,
                              chapter:
                                  _sortedChapters()[i],
                              onTap: () =>
                                  _openChapter(_sortedChapters()[i]),
                            ),
                          ],
                          Divider(
                              height: 0.5,
                              indent: 16,
                              endIndent: 16,
                              color:
                                  scheme.onSurface.withValues(alpha: 0.06)),
                          InkWell(
                            onTap: _showAllChapters,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '查看全部 ${_detail!.chapters.length} 话',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: scheme.onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                                  ),
                                  Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    size: 16,
                                    color: scheme.onSurface
                                        .withValues(alpha: 0.4),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 底部安全距离
                SliverToBoxAdapter(
                  child: SizedBox(height: mq.padding.bottom + 40),
                ),
              ],
            ],
          ),

          // ── Hero 图片区（固定在顶部，随滚动淡出） ──────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: heroH,
            child: Opacity(
              opacity: 1.0 - collapseProgress,
              child: _Hero(
                sourceId: widget.sourceId,
                comicId: widget.comicId,
                name: name,
                pic: pic,
                status: _detail?.status,
              ),
            ),
          ),

          // ── 顶部渐变蒙版（随滚动消失） ────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topPad + 56,
            child: Opacity(
              opacity: (1.0 - collapseProgress * 3).clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.35),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── 顶部 AppBar 区域 ──────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topPad + 56,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    const _BackButton(),
                    const Spacer(),
                    // 标题（滚动后显示）
                    if (collapseProgress > 0.6)
                      Expanded(
                        child: Opacity(
                          opacity: ((collapseProgress - 0.6) / 0.4)
                              .clamp(0.0, 1.0),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    IconButton(
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        transitionBuilder: (c, a) =>
                            ScaleTransition(scale: a, child: c),
                        child: _saved
                            ? const Icon(Icons.bookmark_rounded,
                                key: ValueKey(true))
                            : const Icon(Icons.bookmark_border_rounded,
                                key: ValueKey(false)),
                      ),
                      color: scheme.primary,
                      onPressed: _toggleSave,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleSave() async {
    if (_detail == null) return;
    HapticFeedback.lightImpact();
    final source = SourceManager.byId(widget.sourceId);
    await source.toggleBookshelf(_detail!);
    if (mounted) setState(() => _saved = !_saved);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_saved ? '已加入书架' : '已移出书架'),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  /// 按当前排序返回章节列表。
  List<Chapter> _sortedChapters() {
    final list = _detail!.chapters;
    if (_descending) return list.reversed.toList();
    return list;
  }

  /// 完整章节列表底部弹窗。
  void _showAllChapters() {
    _loadCachedChapters().then((_) {
      if (!mounted) return;
      _showAllChaptersSheet();
    });
  }

  /// 预加载所有章节的缓存状态（用于章节列表显示 ✓）。
  Future<void> _loadCachedChapters() async {
    final bookKey = DownloadManager.bookKeyOf(widget.sourceId, _detail!.id);
    final set = <String>{};
    for (final ch in _detail!.chapters) {
      final ok = await DownloadManager.isDownloaded(bookKey, ch.id);
      if (ok) set.add(ch.id);
    }
    if (mounted) setState(() => _cachedChapters = set);
  }

  Set<String> _cachedChapters = {};

  void _showAllChaptersSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Text(
                      '全部章节 · ${_detail!.chapters.length} 话',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Theme.of(ctx).colorScheme.onSurface,
                      ),
                    ),
                    if (_cachedChapters.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '已缓存 ${_cachedChapters.length} 话',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                        ),
                      ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _descending = !_descending);
                      },
                      icon: Icon(
                        _descending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 16,
                      ),
                      label: Text(_descending ? '倒序' : '正序'),
                    ),
                  ],
                ),
              ),
              Divider(height: 0.5),
              Expanded(
                child: ListView.builder(
                  itemCount: _sortedChapters().length,
                  itemBuilder: (_, i) {
                    final ch = _sortedChapters()[i];
                    final cached = _cachedChapters.contains(ch.id);
                    return ListTile(
                      title: Row(
                        children: [
                          if (cached)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(Icons.download_done_rounded,
                                  size: 14,
                                  color: Theme.of(ctx).colorScheme.primary),
                            ),
                          Flexible(
                            child: Text(
                              ch.title.isEmpty ? '第${i + 1}话' : ch.title,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                          ),
                        ],
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: Theme.of(ctx)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.3),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openChapter(ch);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openChapter(Chapter ch) async {
    final historyMatch = await _historyForChapter(ch);
    if (!mounted) return;
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ReaderPage(
          sourceId: widget.sourceId,
          comicId: _detail!.id,
          chapterId: ch.id,
          title: ch.title,
          comicName: _detail!.name,
          comicPic: _detail!.pic ?? '',
          comicAuthor: _detail!.author ?? '',
          chapters: _detail!.chapters,
          initialPage: historyMatch,
        ),
        transitionDuration: const Duration(milliseconds: 320),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: child,
            ),
          );
        },
      ),
    );
  }

  /// 从历史记录里查当前章节最后读到的页码（无则 -1 从第一页开始）。
  Future<int> _historyForChapter(Chapter ch) async {
    final hist = await LocalStore.history();
    final key = Bookmark(sourceId: widget.sourceId, comicId: _detail!.id,
        name: '', pic: '').key;
    for (final h in hist) {
      if (h.book.key == key && h.chapterId == ch.id && h.hasPage) {
        return h.pageIndex;
      }
    }
    return -1;
  }
}

// ─── 沉浸式 Hero ────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final String sourceId;
  final String comicId;
  final String name;
  final String? pic;
  final String? status;
  const _Hero({required this.sourceId, required this.comicId, required this.name, required this.pic, this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (pic != null && pic!.isNotEmpty)
          Hero(
            tag: 'cover_${sourceId}_$comicId',
            child: CachedImage(
              pic!,
              fit: BoxFit.cover,
              radius: 0,
            ),
          )
        else
          Container(color: scheme.surfaceContainerHighest),
        // 三段式渐变蒙版
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.18),
                Colors.black.withValues(alpha: 0.38),
                theme.scaffoldBackgroundColor.withValues(alpha: 0.0),
                theme.scaffoldBackgroundColor,
              ],
              stops: const [0, 0.35, 0.78, 1.0],
            ),
          ),
        ),
        // 标题区
        Positioned(
          left: 18,
          right: 18,
          bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeSlideIn(
                delay: const Duration(milliseconds: 80),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: scheme.secondary,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.secondary.withValues(alpha: 0.35),
                            blurRadius: 10,
                            spreadRadius: -2,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Text(
                        (status?.isNotEmpty == true) ? status! : '连载中',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3),
                          width: 0.5,
                        ),
                      ),
                      child: const Text(
                        'COMIC',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              FadeSlideIn(
                delay: const Duration(milliseconds: 160),
                offset: 16,
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.white, Color(0xFFE8EAF0)],
                  ).createShader(rect),
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      height: 1.18,
                      letterSpacing: 0.3,
                      shadows: [
                        Shadow(blurRadius: 12, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.maybePop(context),
          child: const SizedBox(
            width: 40,
            height: 40,
            child: Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

// ─── 元数据条 ────────────────────────────────────────────────────────────────

class _MetaSection extends StatelessWidget {
  final ComicDetail detail;
  final bool saved;
  final VoidCallback? onRead;
  final VoidCallback onShelf;
  const _MetaSection({
    required this.detail,
    required this.saved,
    this.onRead,
    required this.onShelf,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = detail;
    final metaParts = <String>[
      if ((d.author ?? '').isNotEmpty) '${d.author} 著',
      if ((d.type ?? '').isNotEmpty) d.type!,
      if ((d.area ?? '').isNotEmpty) d.area!,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 104,
                  height: 148,
                  color: scheme.surfaceContainerHighest,
                  child: (d.pic == null || d.pic!.isEmpty)
                      ? Icon(Icons.image_outlined,
                          size: 32,
                          color: scheme.onSurface.withValues(alpha: 0.2))
                      : CachedImage(d.pic!, fit: BoxFit.cover, radius: 0),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    if (metaParts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          metaParts.join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if ((d.status ?? '').isNotEmpty)
                          _StatusPill(label: d.status!),
                        _CountPill(label: '${d.chapters.length} 话'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onRead,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('开始阅读'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onShelf,
                  icon: Icon(
                    saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_outline_rounded,
                    size: 18,
                  ),
                  label: Text(saved ? '已在书架' : '加入书架'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 状态徽章（墨蓝底白字，如"连载中"）。
class _StatusPill extends StatelessWidget {
  final String label;
  const _StatusPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Colors.white),
      ),
    );
  }
}

/// 计数徽章（黑 6% 底，黑 60% 字）。
class _CountPill extends StatelessWidget {
  final String label;
  const _CountPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

// ─── 简介卡 ──────────────────────────────────────────────────────────────────

class _DescCard extends StatelessWidget {
  final ComicDetail detail;
  const _DescCard({required this.detail});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Text(
        detail.description!,
        style: TextStyle(
          fontSize: 13,
          height: 1.75,
          color: scheme.onSurface.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}

// ─── 章节标题 ────────────────────────────────────────────────────────────────

class _ChapterHeader extends StatelessWidget {
  final int count;
  final bool descending;
  final VoidCallback onToggleDescending;
  final VoidCallback onTapAll;
  const _ChapterHeader({
    required this.count,
    this.descending = false,
    required this.onToggleDescending,
    required this.onTapAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '章节',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onTapAll,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: onToggleDescending,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Text(
                  descending ? '倒序' : '正序',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  descending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 14,
                  color: scheme.primary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 章节项 ──────────────────────────────────────────────────────────────────

class _ChapterTile extends StatefulWidget {
  final int index;
  final Chapter chapter;
  final VoidCallback onTap;
  const _ChapterTile({
    required this.index,
    required this.chapter,
    required this.onTap,
  });

  @override
  State<_ChapterTile> createState() => _ChapterTileState();
}

class _ChapterTileState extends State<_ChapterTile> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.chapter.title.isEmpty
                    ? '第${widget.index + 1}话'
                    : widget.chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 加载 & 错误态 ───────────────────────────────────────────────────────────

class _LoadingView extends StatefulWidget {
  const _LoadingView();

  @override
  State<_LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<_LoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final t = ((_c.value + i / 3) % 1.0);
              final opacity = (1.0 - (t - 0.5).abs() * 2).clamp(0.2, 1.0);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: opacity),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutBack,
              builder: (_, v, child) =>
                  Transform.scale(scale: v, child: child),
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.error.withValues(alpha: 0.10),
                ),
                child: Icon(Icons.cloud_off_outlined,
                    size: 44, color: scheme.error),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 自定义动画组件 ──────────────────────────────────────────────────────────

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
    value: widget.turns,
  );

  @override
  void didUpdateWidget(covariant AnimatedRotation old) {
    super.didUpdateWidget(old);
    if (widget.turns != old.turns) {
      _c.animateTo(widget.turns, curve: Curves.easeOutCubic);
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
      turns: _c,
      child: widget.child,
    );
  }
}
