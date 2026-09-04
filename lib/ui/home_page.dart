import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'detail_page.dart';
import 'responsive.dart';
import 'tokens.dart';
import 'unified_search_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';
import 'widgets/state_view.dart';

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
    } catch (e) {
      debugPrint('loadCategories failed: $e');
    }
  }

  /// 下拉刷新：清空并重拉首页数据（页数重置）
  Future<void> _refresh() async {
    _page = 1;
    _items.clear();
    _error = null;
    _done = false;
    setState(() {});
    _loadCategories();
    await _loadMore();
    // 若当前源在源管理里被禁用，回退到第一个启用源
    await SourceManager.ensureEnabledCurrent().then((_) {
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
    final isDesktop = DesktopUi.isDesktopPlatform;
    final scrollView = CustomScrollView(
      controller: _scrollCtrl,
      physics: isDesktop
          ? const ScrollPhysics(parent: ClampingScrollPhysics())
          : const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
      scrollBehavior: isDesktop
          ? ScrollConfiguration.of(context).copyWith(
              scrollbars: true,
              overscroll: false,
            )
          : null,
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
          padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context), 8,
              Responsive.pagePadding(context), 4),
          sliver: SliverToBoxAdapter(
            child: SectionHeader(
              icon: _modeIcon(),
              title: _modeTitle(),
              count: _items.isNotEmpty ? _items.length : null,
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            Responsive.pagePadding(context),
            6,
            Responsive.pagePadding(context),
            12,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: Responsive.comicGridColumns(context),
              mainAxisSpacing: Responsive.gridSpacing(context),
              crossAxisSpacing: Responsive.gridSpacing(context),
              // 桌面端卡片更方正（0.72），充分利用桌面宽度而非手机竖卡放大
              childAspectRatio: isDesktop ? 0.72 : 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
            (c, i) => RepaintBoundary(
              child: FadeSlideIn(
                delay: Duration(milliseconds: 50 * (i % 12)),
                offset: 16,
                child: ContextMenuWrapper(
                  items: () => _cardMenu(_items[i]),
                  child: _ComicCard(
                    item: _items[i],
                    sourceId: SourceManager.current.id,
                    onTap: () => _openDetail(_items[i]),
                  ),
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
    if (!isDesktop) {
      return RefreshIndicator(
        onRefresh: _refresh,
        color: theme.colorScheme.primary,
        child: scrollView,
      );
    }
    return scrollView;
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

  IconData _modeIcon() {
    switch (_mode) {
      case 'category':
        return Icons.grid_view_rounded;
      case 'search':
        return Icons.search_rounded;
      default:
        return Icons.local_fire_department_rounded;
    }
  }

  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isTablet = Responsive.isTablet(context);
    // 桌面端（Windows/macOS/Linux）：工具栏形态——不重复 Logo 与标题（侧栏已有），
    // 一行内放 搜索框 + 源切换 + 刷新 + 类型分段，与桌面应用（YouTube/Spotify PC）一致。
    if (DesktopUi.isDesktopPlatform) {
      return SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 12),
          child: Row(
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
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
              ),
              const SizedBox(width: 10),
              _SourceSwitchButton(
                sourceName: SourceManager.current.name,
                onTap: _showSourceSheet,
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '刷新',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                color: T.color(scheme.onSurface, TextTier.mid,
                    brightness: scheme.brightness),
              ),
              const Spacer(),
              TypeSegment(
                type: widget.type,
                onChanged: widget.onTypeChanged,
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      bottom: false,
      child: Padding(
        // SafeArea 已计入状态栏高度，不再叠加 56（否则手机首屏顶部被双重下推、
        // 出现大段空洞）。与 anime_home 修复保持一致，统一为 16。
        padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context),
          16,
          Responsive.pagePadding(context),
          isTablet ? 8 : 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // logo（漫画收纳箱图标）
                ClipRRect(
                  borderRadius: BorderRadius.circular(isTablet ? 8 : 9),
                  child: Image.asset(
                    'ui_assets/icon-logo.png',
                    width: isTablet ? 28 : 32,
                    height: isTablet ? 28 : 32,
                    fit: BoxFit.cover,
                  ),
                ),
                SizedBox(width: isTablet ? 8 : 10),
                Text(
                  '星漫匣',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isTablet ? 18 : 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 10),
                // 源切换按钮紧贴标题：当前站点一目了然，点击切换。
                // 避免被 Spacer/Flexible 推到右上角孤悬、与搜索区脱节。
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
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: Responsive.fieldMaxWidth(context)),
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
                ),
                const SizedBox(width: 10),
                TypeSegment(
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
    await showResponsiveBottomSheet<void>(
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
            // 与内容区 pagePadding 对齐，避免大屏下胶囊栏与正文左缘不齐。
            padding:
                EdgeInsets.symmetric(horizontal: Responsive.pagePadding(context)),
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

  /// 桌面右键菜单：查看详情 / 复制标题（Fluent ContextMenu 惯例）。
  List<CtxMenuItem> _cardMenu(ComicItem it) => [
        CtxMenuItem(
          label: '查看详情',
          icon: Icons.open_in_new_rounded,
          onTap: () => _openDetail(it),
        ),
        const CtxMenuItem.separator(),
        CtxMenuItem(
          label: '复制标题',
          icon: Icons.copy_rounded,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: it.name));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('已复制「${it.name}」'),
              behavior: SnackBarBehavior.floating,
              width: 260,
              duration: const Duration(seconds: 2),
            ));
          },
        ),
      ];
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
    return HoverEffect(
      onTap: onTap,
      opacity: 0.92,
      child: PressableScale(
        onTap: onTap,
        scale: 0.95,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(R.pill),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.22),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(R.control),
                ),
                child: Icon(Icons.public_rounded,
                    size: 14, color: scheme.onPrimary),
              ),
              const SizedBox(width: 6),
              Text(
                sourceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.keyboard_arrow_down_rounded,
                  size: 16, color: scheme.primary),
            ],
          ),
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
        borderRadius: BorderRadius.circular(R.card),
        border: Border.all(
          color: _focused
              ? T.color(scheme.onSurface, TextTier.low,
                  brightness: scheme.brightness)
              : scheme.outline,
          width: 1,
        ),
      ),
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        child: TextField(
          controller: widget.controller,
          textInputAction: TextInputAction.search,
          onSubmitted: widget.onSubmit,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
              ),
          decoration: InputDecoration(
            hintText: '搜索漫画、动漫、小说…',
            hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness),
                ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 20,
              color: _focused
                  ? scheme.primary
                  : T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
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
                        icon: Icon(Icons.close_rounded,
                            size: 18,
                            color: T.color(scheme.onSurface, TextTier.low,
                                brightness: scheme.brightness)),
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
            // 选中态用 primary 底 + onPrimary 字：明暗两套主题都自动满足对比度。
            // （旧实现 onSurface 底 + 写死 Colors.white 字，暗色下对比度仅 1.20）
            color: active ? scheme.primary : scheme.surface,
            borderRadius: BorderRadius.circular(R.pill),
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
                Icon(
                  icon,
                  size: 13,
                  color: active
                      ? scheme.onPrimary
                      : T.color(scheme.onSurface, TextTier.low,
                          brightness: scheme.brightness),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.w500,
                      color: active
                          ? scheme.onPrimary
                          : T.color(scheme.onSurface, TextTier.mid,
                              brightness: scheme.brightness),
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
  PageController? _ctrl;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    // 注意：不能在 initState 里读 MediaQuery/Responsive（dependOnInheritedWidget
    // 在 initState 未完成前调用会抛异常 → 真机首页红屏）。在 didChangeDependencies
    // 里初始化并按尺寸类重建控制器。
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 平板视口更宽，横幅更大更有冲击力
    final fraction = Responsive.isTablet(context) ? 0.7 : 0.86;
    if (_ctrl == null) {
      _ctrl = PageController(viewportFraction: fraction);
    } else if (_ctrl!.viewportFraction != fraction) {
      // 尺寸类变化（如横屏/竖屏切换）时重建，避免 viewportFraction 失效
      _ctrl!.dispose();
      _ctrl = PageController(viewportFraction: fraction);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context), 6,
              Responsive.pagePadding(context), 10),
          child: SectionHeader(
            icon: Icons.auto_awesome_rounded,
            title: '本周精选',
            trailing: Text(
              '${_page + 1}/${widget.items.length}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: T.color(scheme.onSurface, TextTier.disabled,
                        brightness: scheme.brightness),
                  ),
            ),
          ),
        ),
        SizedBox(
          // 横幅高度随断点阶梯化：单张卡宽随 viewportFraction 放大后，
          // 若高度固定 240 会在 1600dp+ 屏上过于扁平、封面裁切严重。
          // 桌面端保持 240，不抢屏（浏览器首页横幅普遍 220~260）。
          height: DesktopUi.isDesktopPlatform
              ? 240
              : (Responsive.isLarge(context)
                  ? 300
                  : (Responsive.isExpanded(context)
                      ? 260
                      : (Responsive.isTablet(context) ? 240 : 176))),
          child: PageView.builder(
            controller: _ctrl!,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) {
              final it = widget.items[i];
              return AnimatedBuilder(
                animation: _ctrl!,
                builder: (c, child) {
                  double scale = 1.0;
                  double opacity = 1.0;
                  if (_ctrl!.position.haveDimensions) {
                    final cur = _ctrl!.page ?? 0;
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
          borderRadius: BorderRadius.circular(R.card),
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
              // 暗色渐变：对角 + 底部两道，保证标题永远落在深色衬上，
              // 避免亮色封面把白字"吃掉"（底部渐变到 55% 处仍保留 0.72 黑度）。
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
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.78),
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.28, 0.55],
                    ),
                  ),
                ),
              ),
              // 信息
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
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
                      child: Text(
                        '精选',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 1,
                            ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            height: 1.25,
                            color: Colors.white,
                            shadows: const [
                              Shadow(blurRadius: 8, color: Colors.black54),
                            ],
                          ),
                    ),
                    if ((item.author ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.author!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: Colors.white70),
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
          transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(R.card),
            // Minimalist：卡片不使用投影，悬停仅以微位移反馈。
            boxShadow: const [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(R.card),
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
                            right: 6,
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 100),
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                widget.item.author!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
          borderRadius: BorderRadius.circular(R.sheet),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              '切换数据源',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < sources.length; i++) ...[
              FadeSlideIn(
                delay: Duration(milliseconds: 40 * i),
                offset: 8,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelected(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: i == currentIndex
                          ? scheme.primary.withValues(alpha: 0.10)
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: i == currentIndex
                            ? scheme.primary.withValues(alpha: 0.5)
                            : T.color(scheme.onSurface, TextTier.hairline,
                                brightness: scheme.brightness),
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
                            style:
                                Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: T.color(scheme.onSurface, TextTier.disabled,
                          brightness: scheme.brightness),
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
    return StateView(
      kind: StateViewKind.error,
      message: message,
      onRetry: onRetry,
      icon: Icons.cloud_off_outlined,
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
    final isSearch = mode == 'search';
    final text = isSearch ? '没有找到相关结果' : '该分类暂时没有内容';
    final subtitle = isSearch ? '换个关键词试试，或点击右侧搜索全源内容' : '换个分类看看，精彩内容持续更新中';
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
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness),
                ),
          ),
        ],
      ),
    );
  }
}

// _TypeSegment 已移至 responsive.dart 作为共享组件 TypeSegment
