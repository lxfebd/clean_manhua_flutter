import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'detail_page.dart';
import 'responsive.dart';
import 'unified_search_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

/// 首页：搜索 + 横向 Hero + 分类胶囊 + 漫画网格（错峰入场）
class HomePage extends StatefulWidget {
  /// 0=漫画 1=动漫（由外层 MangaAnimeTabs 驱动）
  final int type;
  final ValueChanged<int>? onTypeChanged;
  const HomePage({super.key, this.type = 0, this.onTypeChanged});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _items = <ComicItem>[];
  int _page = 1;
  bool _loading = false;
  String _mode = 'rank';
  String _categoryId = '';
  String _keyword = '';
  String? _error;
  bool _done = false; // 首屏请求是否已结束（区分加载中与空结果）
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<Category> _cats = [];

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadCategories();
    _refresh();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _loadCategories() async {
    try {
      final cats = await SourceManager.current.categories();
      if (mounted) setState(() => _cats = cats);
    } catch (_) {}
  }

  void _refresh() {
    _page = 1;
    _items.clear();
    _error = null;
    _done = false;
    setState(() {});
    _loadCategories();
    _loadMore();
    // 若当前源在源管理里被禁用，回退到第一个启用源
    SourceManager.ensureEnabledCurrent().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >
        _scrollCtrl.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    _loading = true;
    if (_items.isEmpty) setState(() => _error = null);
    final source = SourceManager.current;
    final next = _page;
    try {
      List<ComicItem> r;
      switch (_mode) {
        case 'category':
          r = await source.listByCategory(_categoryId, next);
          break;
        case 'search':
          r = await source.search(_keyword, next);
          break;
        default:
          r = await source.rank(next);
      }
      if (mounted) {
        setState(() {
          _items.addAll(r);
          _page++;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _items.isEmpty) {
        setState(() => _error = '加载失败，请检查网络\n$e');
      }
    } finally {
      _loading = false;
      _done = true;
    }
  }

  void _switchMode(String mode, {String? categoryId}) {
    _mode = mode;
    if (categoryId != null) _categoryId = categoryId;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          _buildHeader(theme),
          _buildChips(theme),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _refresh);
    }
    if (_items.isEmpty) {
      // 首屏请求已结束仍无内容 → 空态；否则显示加载动画
      return _done ? _EmptyState(mode: _mode) : _LoadingDots();
    }
    final theme = Theme.of(context);
    return CustomScrollView(
      controller: _scrollCtrl,
      physics: const BouncingScrollPhysics(),
      slivers: [
        // 顶部大封面横幅（仅推荐模式下展示前 5 张作为精选）
        if (_mode == 'rank' && _items.length >= 5)
          SliverToBoxAdapter(
            child: FadeSlideIn(
              delay: const Duration(milliseconds: 80),
              duration: const Duration(milliseconds: 540),
              child: _FeaturedBanner(items: _items.take(5).toList()),
            ),
          ),
        // 列表区
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _modeTitle(),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                if (_items.isNotEmpty)
                  Text(
                    '${_items.length} 部',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: Responsive.isTablet(context) ? 152 : 112,
              mainAxisSpacing: 14,
              crossAxisSpacing: Responsive.isTablet(context) ? 14 : 10,
              childAspectRatio: 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
            (c, i) => RepaintBoundary(
              child: FadeSlideIn(
                delay: Duration(milliseconds: 50 * (i % 12)),
                offset: 16,
                child: _ComicCard(
                  item: _items[i],
                  sourceId: SourceManager.current.id,
                  onTap: () => _openDetail(_items[i]),
                ),
              ),
            ),
            childCount: _items.length,
          ),
          ),
        ),
        if (_loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  String _modeTitle() {
    switch (_mode) {
      case 'category':
        final cat = _cats.firstWhere(
          (c) => c.id == _categoryId,
          orElse: () => Category('', '分类'),
        );
        return cat.name;
      case 'search':
        return '搜索：$_keyword';
      default:
        return '本周热榜';
    }
  }

  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            18, Responsive.isTablet(context) ? 24 : 56, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // logo（漫画收纳箱图标）
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Image.asset(
                    'ui_assets/icon-logo.png',
                    width: 32,
                    height: 32,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '星漫匣',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: scheme.onSurface,
                      ),
                    ),
                    Text(
                      SourceManager.current.name,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                _SourceSwitchButton(
                  sourceName: SourceManager.current.name,
                  onTap: _showSourceSheet,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 搜索栏 + 漫画/动漫切换（同一行，对齐 UI_v2）
            Row(
              children: [
                Expanded(
                  child: _SearchBar(
                    controller: _searchCtrl,
                    onSubmit: (v) {
                      _keyword = v;
                      _switchMode('search');
                    },
                    onSearchAll: (kw) {
                      HapticFeedback.selectionClick();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UnifiedSearchPage(keyword: kw),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                _TypeSegment(
                  type: widget.type,
                  onChanged: widget.onTypeChanged,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSourceSheet() async {
    final enabled = await SourceManager.enabledSources();
    if (!mounted || enabled.isEmpty) return;
    final curId = SourceManager.current.id;
    final curInList = enabled.indexWhere((s) => s.id == curId);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _SourceSwitchSheet(
        sources: enabled,
        currentIndex: curInList < 0 ? 0 : curInList,
        onSelected: (i) {
          final src = enabled[i];
          SourceManager.switchTo(SourceManager.sources.indexOf(src));
          Navigator.pop(context);
          _refresh();
        },
      ),
    );
  }

  Widget _buildChips(ThemeData theme) {
    return Stack(
      children: [
        SizedBox(
          height: Responsive.isTablet(context) ? 48 : 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              _Chip(
                label: '推荐',
                icon: Icons.local_fire_department_rounded,
                active: _mode == 'rank',
                onTap: () => _switchMode('rank'),
              ),
              for (final c in _cats)
                _Chip(
                  label: c.name,
                  active: _mode == 'category' && _categoryId == c.id,
                  onTap: () => _switchMode('category', categoryId: c.id),
                ),
            ],
          ),
        ),
        // 右侧渐隐，提示还有更多分类可横向滑动
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 36,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    theme.scaffoldBackgroundColor.withValues(alpha: 0),
                    theme.scaffoldBackgroundColor,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openDetail(ComicItem it) {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => DetailPage(
          sourceId: SourceManager.current.id,
          comicId: it.id,
          name: it.name,
          pic: it.pic,
        ),
        transitionDuration: const Duration(milliseconds: 360),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 头部组件
// ─────────────────────────────────────────────────────────────────────────────

class _SourceSwitchButton extends StatelessWidget {
  final String sourceName;
  final VoidCallback onTap;
  const _SourceSwitchButton({required this.sourceName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              scheme.primary.withValues(alpha: 0.16),
              scheme.primary.withValues(alpha: 0.06),
            ],
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.32),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 5),
            Text(
              '站点',
              style: TextStyle(
                fontSize: 11,
                color: scheme.primary.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              sourceName,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.unfold_more_rounded, size: 15, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSubmit;

  /// 跨源全量搜索（suffixIcon 入口）。
  final ValueChanged<String>? onSearchAll;
  const _SearchBar({required this.controller, required this.onSubmit, this.onSearchAll});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: _focused
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.onSurface.withValues(alpha: 0.06),
          width: _focused ? 1.4 : 0.6,
        ),
        boxShadow: [
          if (_focused)
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.18),
              blurRadius: 16,
              spreadRadius: -4,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        child: TextField(
          controller: widget.controller,
          textInputAction: TextInputAction.search,
          onSubmitted: widget.onSubmit,
          style: TextStyle(fontSize: 14, color: scheme.onSurface),
          decoration: InputDecoration(
            hintText: '搜索漫画、动漫、小说…',
            hintStyle: TextStyle(
              fontSize: 13.5,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 20,
              color: _focused ? scheme.primary : scheme.onSurface.withValues(alpha: 0.55),
            ),
            suffixIcon: widget.controller.text.isNotEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onSearchAll != null)
                        IconButton(
                          tooltip: '全源搜索',
                          icon: Icon(Icons.public_rounded, size: 17, color: scheme.primary),
                          onPressed: () {
                            final kw = widget.controller.text.trim();
                            if (kw.isNotEmpty) widget.onSearchAll!(kw);
                          },
                        ),
                      IconButton(
                        icon: Icon(Icons.close_rounded, size: 18, color: scheme.onSurface.withValues(alpha: 0.5)),
                        onPressed: () {
                          widget.controller.clear();
                          setState(() {});
                        },
                      ),
                    ],
                  )
                : null,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 分类胶囊
// ─────────────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: PressableScale(
        onTap: onTap,
        scale: 0.94,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? scheme.onSurface : scheme.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? Colors.transparent
                  : scheme.onSurface.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 13,
                    color: active
                        ? Colors.white
                        : scheme.onSurface.withValues(alpha: 0.65)),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active
                      ? Colors.white
                      : scheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 顶部精选横幅（横向轮播）
// ─────────────────────────────────────────────────────────────────────────────

class _FeaturedBanner extends StatefulWidget {
  final List<ComicItem> items;
  const _FeaturedBanner({required this.items});

  @override
  State<_FeaturedBanner> createState() => _FeaturedBannerState();
}

class _FeaturedBannerState extends State<_FeaturedBanner> {
  late final PageController _ctrl;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    // 平板视口更宽，横幅更大更有冲击力
    _ctrl = PageController(
        viewportFraction: Responsive.isTablet(context) ? 0.7 : 0.86);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
          child: Row(
            children: [
              Text(
                '本周精选',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '${_page + 1}/${widget.items.length}',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: Responsive.isTablet(context) ? 240 : 176,
          child: PageView.builder(
            controller: _ctrl,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) {
              final it = widget.items[i];
              return AnimatedBuilder(
                animation: _ctrl,
                builder: (c, child) {
                  double scale = 1.0;
                  double opacity = 1.0;
                  if (_ctrl.position.haveDimensions) {
                    final cur = _ctrl.page ?? 0;
                    final diff = (cur - i).abs();
                    scale = (1 - diff * 0.07).clamp(0.88, 1.0);
                    opacity = (1 - diff * 0.25).clamp(0.7, 1.0);
                  }
                  return Transform.scale(
                    scale: scale,
                    child: Opacity(opacity: opacity, child: child),
                  );
                },
                child: _FeaturedCard(
                  item: it,
                  sourceId: SourceManager.current.id,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DetailPage(
                          sourceId: SourceManager.current.id,
                          comicId: it.id,
                          name: it.name,
                          pic: it.pic,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // 分页指示
        Center(
          child: AnimatedSmoothIndicator(
            activeIndex: _page,
            count: widget.items.length,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  final ComicItem item;
  final String sourceId;
  final VoidCallback onTap;
  const _FeaturedCard({required this.item, required this.sourceId, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: PressableScale(
        onTap: onTap,
        scale: 0.98,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Hero(
                tag: 'cover_${sourceId}_${item.id}',
                child: CachedImage(
                  item.pic,
                  fit: BoxFit.cover,
                  radius: 0,
                ),
              ),
              // 暗色渐变
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomLeft,
                      end: Alignment.topRight,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.6],
                    ),
                  ),
                ),
              ),
              // 信息
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.secondary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '精选',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        shadows: [
                          Shadow(blurRadius: 8, color: Colors.black54),
                        ],
                      ),
                    ),
                    if ((item.author ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.author!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
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
}

/// 简洁分页指示器
class AnimatedSmoothIndicator extends StatelessWidget {
  final int activeIndex;
  final int count;
  final Color color;
  const AnimatedSmoothIndicator({
    super.key,
    required this.activeIndex,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            width: i == activeIndex ? 18 : 5,
            height: 5,
            decoration: BoxDecoration(
              color: i == activeIndex
                  ? color
                  : scheme.onSurface.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 漫画卡片（错峰入场）
// ─────────────────────────────────────────────────────────────────────────────

class _ComicCard extends StatefulWidget {
  final ComicItem item;
  final String sourceId;
  final VoidCallback onTap;
  const _ComicCard({required this.item, required this.sourceId, required this.onTap});

  @override
  State<_ComicCard> createState() => _ComicCardState();
}

class _ComicCardState extends State<_ComicCard> {
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
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()..translate(0.0, _hover ? -4 : 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.22),
                      blurRadius: 16,
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
                          child: Hero(
                            tag: 'cover_${widget.sourceId}_${widget.item.id}',
                            child: CachedImage(
                              widget.item.pic,
                              fit: BoxFit.cover,
                              radius: 0,
                            ),
                          ),
                        ),
                        if ((widget.item.author ?? '').isNotEmpty)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                widget.item.author!,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        // 更新/完结状态角标（如"更新至第19集"/"全12集"）
                        if ((widget.item.remarks ?? '').isNotEmpty)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 84),
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                widget.item.remarks!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 8.5,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
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

// ─────────────────────────────────────────────────────────────────────────────
// 数据源切换底部弹窗
// ─────────────────────────────────────────────────────────────────────────────

class _SourceSwitchSheet extends StatelessWidget {
  final List<ComicSource> sources;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  const _SourceSwitchSheet({
    required this.sources,
    required this.currentIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(28),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              '切换数据源',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 14),
            for (var i = 0; i < sources.length; i++) ...[
              FadeSlideIn(
                delay: Duration(milliseconds: 40 * i),
                offset: 8,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelected(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: i == currentIndex
                          ? scheme.primary.withValues(alpha: 0.10)
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: i == currentIndex
                            ? scheme.primary.withValues(alpha: 0.5)
                            : scheme.onSurface.withValues(alpha: 0.04),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          i == currentIndex
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 18,
                          color: i == currentIndex
                              ? scheme.primary
                              : scheme.onSurface.withValues(alpha: 0.4),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            sources[i].name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.public_rounded,
                          size: 13,
                          color: scheme.onSurface.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Center(
              child: Text(
                '可前往「工具 → 数据源管理」调整各源域名/启用状态',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 加载 & 错误态
// ─────────────────────────────────────────────────────────────────────────────

class _LoadingDots extends StatefulWidget {
  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
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

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

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
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.error.withValues(alpha: 0.10),
              ),
              child: Icon(Icons.cloud_off_outlined, size: 44, color: scheme.error),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
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
    );
  }
}

/// 无结果空态（搜索/分类无内容时展示，避免一直转圈）。
class _EmptyState extends StatelessWidget {
  final String mode;
  const _EmptyState({required this.mode});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = mode == 'search' ? '没有找到相关结果' : '该分类暂时没有内容';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.08),
            ),
            child: Icon(Icons.search_off_rounded, size: 44, color: scheme.primary),
          ),
          const SizedBox(height: 14),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 漫画 / 动漫 分段切换（黑底胶囊，对齐 UI_v2 顶部 segment）。
class _TypeSegment extends StatelessWidget {
  final int type;
  final ValueChanged<int>? onChanged;
  const _TypeSegment({required this.type, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.onSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(context, '漫画', 0),
          _seg(context, '动漫', 1),
          _seg(context, '小说', 2),
        ],
      ),
    );
  }

  Widget _seg(BuildContext context, String label, int v) {
    final scheme = Theme.of(context).colorScheme;
    final active = type == v;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? scheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active
                ? scheme.onSurface
                : scheme.surface.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}
