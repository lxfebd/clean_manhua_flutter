import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/error_logger.dart';
import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import '../sources/video_source.dart';
import 'episode_list_page.dart';
import 'responsive.dart';
import 'style_scope.dart';
import 'style_tokens.dart';
import 'tokens.dart';
import 'widgets/app_toast.dart';
import 'widgets/cached_image.dart';
import 'widgets/frosted_glass.dart';
import 'widgets/motion.dart';
import 'widgets/skeleton.dart';
import 'widgets/squircle.dart';
import 'widgets/tap_target.dart';

/// 动漫首页：搜索 + 分类胶囊 + 番剧网格。
class AnimeHomePage extends StatefulWidget {
  /// 0=漫画 1=动漫（由外层 MangaAnimeTabs 驱动）
  final int type;
  final ValueChanged<int>? onTypeChanged;
  const AnimeHomePage({super.key, this.type = 1, this.onTypeChanged});

  @override
  State<AnimeHomePage> createState() => AnimeHomePageState();
}

/// 公开 State：主壳经 GlobalKey 调 [refresh]（Ctrl+R 分发）。
class AnimeHomePageState extends State<AnimeHomePage> {
  final _items = <ComicItem>[];
  int _page = 1;
  bool _loading = false;
  bool _noMore = false;
  bool _loadMoreError = false; // 分页失败（列表非空时显示重试条）
  String _mode = 'rank';
  String _categoryId = '';
  String _keyword = '';
  String? _error;

  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  late VideoSource _source;
  List<VideoSource> _sources = [];
  List<Category> _sourceCats = _cats;

  static final _cats = [
    Category('all-all-all-all-all-time-1', '推荐'),
    Category('all-all-all-all-jp-time-1', '日本'),
    Category('all-all-all-all-cn-time-1', '国创'),
    Category('all-all-all-all-us-time-1', '欧美'),
  ];

  @override
  void initState() {
    super.initState();
    // 同步初值：全量列表第一个（与改造前一致），保证首帧渲染不依赖异步加载。
    // _loadSources() 完成后若启用源不同会切换默认源并刷新列表。
    _sources = SourceManager.videoSources;
    _source = _sources.first;
    _scrollCtrl.addListener(_onScroll);
    _loadSourceCats();
    _refresh();
    _loadSources();
  }

  /// 异步加载启用中的视频源（配置优先），首个作为默认源。
  /// 全禁用时回退到全量列表第一个，保证页面可用。
  Future<void> _loadSources() async {
    final enabled = await SourceManager.enabledVideoSources();
    if (!mounted) return;
    setState(() {
      _sources = enabled.isNotEmpty ? enabled : SourceManager.videoSources;
      if (!_sources.any((s) => s.id == _source.id)) {
        _source = _sources.first;
      }
    });
    _loadSourceCats();
  }

  /// 弹出视频源选择底部弹窗。
  void _pickSource() {
    showResponsiveBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('切换番剧源',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Theme.of(ctx).colorScheme.onSurface)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final s in _sources)
                    ListTile(
                      leading: Icon(
                        s.id == _source.id ? Icons.radio_button_checked : Icons.radio_button_off,
                        size: 20,
                        color: s.id == _source.id
                            ? Theme.of(ctx).colorScheme.primary
                            : Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                      title: Text(s.name, style: const TextStyle(fontSize: 14)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _switchSource(s);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _loadSourceCats() async {
    try {
      final cats = await _source.categories();
      if (mounted && cats.isNotEmpty) setState(() => _sourceCats = cats);
    } catch (e) {
      ErrorLogger.instance.warn('loadSourceCats failed: $e');
    }
  }

  /// 切换视频源后刷新列表与分类。
  void _switchSource(VideoSource source) {
    if (source.id == _source.id) return;
    setState(() => _source = source);
    _mode = 'rank';
    _categoryId = '';
    _sourceCats = _cats;
    _loadSourceCats();
    _refresh();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_noMore) return;
    if (_scrollCtrl.position.pixels >
        _scrollCtrl.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _noMore) return;
    _loading = true;
    _loadMoreError = false;
    final source = _source;
    final token = _loadToken; // 本次请求的代际：响应到达时代际不符则丢弃
    final next = _page;
    try {
      List<ComicItem> r;
      final cats = _sourceCats;
      final defaultCat = cats.isEmpty ? '' : cats.first.id;
      final catId = _mode == 'category' ? _categoryId : defaultCat;
      switch (_mode) {
        case 'category':
          r = await source.listByCategory(catId, next);
          break;
        case 'search':
          r = await source.search(_keyword, next);
          break;
        default:
          r = await source.listByCategory(defaultCat, next);
      }
      if (!mounted || token != _loadToken) return; // 期间已切源/刷新：丢弃旧结果
      setState(() {
        if (r.isEmpty) {
          _noMore = true;
        } else {
          // 源站分页会漂移（同一作品跨页重复，如 tvtfun 的 331164 半妖的夜叉姬）；
          // 合并后按 id 去重，避免往下拉时重复出现上面的动漫。
          // 注意：必须先构造合并结果再一次性替换 —— 若先 clear() 再合并，
          // 展开的 _items 已是空列表，后加载的页会把之前所有页"顶掉"，
          // 表现为滚动到底后整页重刷（列表只剩加载页数据、滚动位置丢失）。
          final merged = _dedup([..._items, ...r]);
          _items
            ..clear()
            ..addAll(merged);
          _page++;
        }
      });
      _maybeAutoLoadMore();
    } catch (e) {
      ErrorLogger.instance.warn('anime home loadMore failed: $e');
      if (mounted && token == _loadToken) {
        if (_items.isEmpty) {
          setState(() => _error = '加载失败，请检查网络');
        } else {
          setState(() => _loadMoreError = true);
        }
      }
    } finally {
      _loading = false;
    }
  }

  void _switchMode(String mode, {String? categoryId}) {
    _mode = mode;
    if (categoryId != null) _categoryId = categoryId;
    _refresh();
  }

  /// 源站分页偶发返回重复条目（同一作品跨页重复）：按 id 去重后渲染。
  static List<ComicItem> _dedup(List<ComicItem> items) {
    final seen = <String>{};
    return [for (final it in items) if (it.id.isNotEmpty && seen.add(it.id)) it];
  }

  /// 内容不满一屏时自动续页，避免首屏太短时滚动分页不触发导致"很快到底"的错觉。
  /// 最多续 3 页：封面加载慢/失败导致网格高度不足时，避免无限循环狂拉分页
  /// 把请求队列打满（每页 20 张图并发加载 + 源站限流会明显卡顿）。
  int _autoLoadCount = 0;
  void _maybeAutoLoadMore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _noMore) return;
      if (_scrollCtrl.hasClients &&
          _scrollCtrl.position.maxScrollExtent <= 0) {
        if (_autoLoadCount >= 3) return;
        _autoLoadCount++;
        _loadMore();
      }
    });
  }

  /// 加载代际：切源/切分类/刷新时自增，使在途旧请求的结果作废，
  /// 避免「加载中切源 → 旧请求完成停空态、新列表永不加载」的竞态。
  int _loadToken = 0;

  /// 主壳 Ctrl+R 刷新入口。
  void refresh() => _refresh();

  /// 主动刷新：清空列表重启首屏加载，返回的 Future 供下拉指示器等待。
  Future<void> _refresh() {
    _loadToken++; // 作废在途请求（旧响应到达后按 token 丢弃）
    _loading = false; // 放行新请求（旧请求 finally 复位无害）
    _page = 1;
    _items.clear();
    _error = null;
    _noMore = false;
    _loadMoreError = false;
    _autoLoadCount = 0;
    setState(() {});
    return _loadMore();
  }

  /// 下拉刷新入口（RefreshIndicator 要求 RefreshCallback）。
  Future<void> _onRefresh() => _refresh();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: _buildScrollArea(theme),
    );
  }

  /// 统一滚动区：头部 [SliverPersistentHeader]（随滚动收起）+ 内容 slivers。
  /// 手机/平板保留下拉刷新；桌面保持 clamping + 滚动条。
  Widget _buildScrollArea(ThemeData theme) {
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
        _buildHeaderSliver(theme),
        ..._buildContentSlivers(theme),
      ],
    );
    if (!isDesktop) {
      return RefreshIndicator(
        onRefresh: _onRefresh,
        color: theme.colorScheme.primary,
        child: scrollView,
      );
    }
    return scrollView;
  }

  /// 整屏区块 sliver（错误/空态/加载骨架）。
  ///
  /// 不能直接把 [HomeGridSkeleton](内部是 CustomScrollView/Viewport)交给
  /// [SliverFillRemaining]：它会对 child 求 intrinsic 高度，Viewport 不支持
  /// → 崩溃。改为包一层按视口高度定高的 SizedBox，intrinsic 直接取定值、
  /// 不再递归进嵌套滚动视图。
  Widget _fillRemaining(Widget child) {
    final h = MediaQuery.sizeOf(context).height;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: SizedBox(height: h, child: child),
    );
  }

  /// 内容区 slivers：错误/空态/加载为整屏区块，正常态为分区头 + 网格。
  List<Widget> _buildContentSlivers(ThemeData theme) {
    if (_error != null) {
      return [
        _fillRemaining(_ErrorView(message: _error!, onRetry: _refresh)),
      ];
    }
    if (_items.isEmpty) {
      // 加载态与空态分离：正在拉取首屏时显示骨架屏；加载完成但源没返回内容时
      // 显示明确的空态引导，避免用户误以为"永远转圈"。
      return [
        _fillRemaining(_loading
            ? const HomeGridSkeleton()
            : _EmptyView(onRetry: _refresh)),
      ];
    }
    final isDesktop = DesktopUi.isDesktopPlatform;
    return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context), 4,
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
              // 桌面端卡片更方正，充分利用桌面宽度
              childAspectRatio: isDesktop ? 0.72 : 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (c, i) => FadeSlideIn(
                // 首屏前几行做入场动画；后续翻页加载的卡片不再逐张延迟，
                // 避免追加新页时前 12 张又重播动画 + 定时器风暴造成卡顿。
                delay: _items.length <= 24
                    ? Duration(milliseconds: 50 * (i % 12))
                    : Duration.zero,
                offset: 16,
                child: ContextMenuWrapper(
                  items: () => _cardMenu(_items[i]),
                  child: _AnimeCard(
                    item: _items[i],
                    loading: _openingId == _items[i].id,
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
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        if (_loadMoreError)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: TextButton.icon(
                  onPressed: _loadMore,
                  icon: Icon(Icons.refresh_rounded,
                      size: 16, color: Theme.of(context).colorScheme.primary),
                  label: Text('加载失败，点此重试',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.primary)),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ];
  }

  String _modeTitle() {
    switch (_mode) {
      case 'category':
        return _sourceCats.firstWhere(
          (c) => c.id == _categoryId,
          orElse: () => Category('', '分类'),
        ).name;
      case 'search':
        return '搜索：$_keyword';
      default:
        return '本周番剧';
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

  /// 滚动收起头部 sliver：展开为完整头部（logo/星漫匣/双源切换/搜索/类型/胶囊），
  /// 收起为单行精简栏（搜索 + 类型切换；桌面为完整工具栏）。
  ///
  /// 与 home_page 同构：自绘 delegate 精确控制展开/收起两态与滚动过渡，
  /// 动画随 shrinkOffset 连续映射（SliverAppBar 的 toolbar 区放不下两套布局）。
  Widget _buildHeaderSliver(ThemeData theme) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    final isTablet = Responsive.isTablet(context);
    final topPad = MediaQuery.paddingOf(context).top;
    // 展开高度 = 完整头自然高度（含 TapTargetMin 44 强制热区）+ 余量，
    // 溢出会触发 RenderFlex 黄条断言。logo 行收敛为单行（源切换只保留右侧
    // 胶囊）后与 home 同高：
    // 手机 6+44+8+48搜索行+4+44胶囊+4 = 158 → 168；平板 6+44+8+52+4+48+4
    // = 166 → 176；桌面工具栏行被 44 热区撑到约 50：10+50+10+44+10 = 124
    // → 138（实测 128 时溢出 2dp）。
    // 44 热区行不随文字长，但搜索/标题行会随系统文字缩放长高
    // （1.5×/2.0× 实测会溢），故按缩放补余量（与 home 同公式）。
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final textSlack = (textScale - 1.0).clamp(0.0, 1.0) * 60;
    final expanded =
        (isDesktop ? 138.0 : (isTablet ? 176.0 : 168.0)) + textSlack + topPad;
    final collapsed = kToolbarHeight + topPad;
    return SliverPersistentHeader(
      pinned: true,
      delegate: _AnimeHeaderDelegate(
        minExtent: collapsed,
        maxExtent: expanded,
        builder: (context, shrinkOffset, overlapsContent) {
          final current = (expanded - shrinkOffset).clamp(collapsed, expanded);
          final t =
              ((expanded - current) / (expanded - collapsed)).clamp(0.0, 1.0);
          return _buildShrinkableHeader(theme, expanded, current, t);
        },
      ),
    );
  }

  /// 展开态完整头与收起态精简栏的过渡：完整头随收缩淡出并上移，
  /// 精简栏从底部淡入（带不透明底，遮住下层重叠的展开态内容）。
  Widget _buildShrinkableHeader(
      ThemeData theme, double expanded, double current, double t) {
    return ClipRect(
      child: SizedBox(
        height: current,
        child: Stack(
          fit: StackFit.loose,
          clipBehavior: Clip.none,
          children: [
            // 展开头随收缩淡出：透明度归零后必须同时 IgnorePointer，
            // 否则半收起时看不见的搜索框/胶囊仍在吃掉点击（收起层有
            // IgnorePointer、展开层原先没有，两态热区会重叠）。
            IgnorePointer(
              key: const ValueKey('anime-header-expanded-guard'),
              ignoring: t > 0.5,
              child: Opacity(
                opacity: (1.0 - t * 1.6).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, -t * 24),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: OverflowBox(
                      minHeight: 0,
                      maxHeight: expanded,
                      alignment: Alignment.topCenter,
                      child: _buildExpandedHeader(theme, expanded),
                    ),
                  ),
                ),
              ),
            ),
            if (t > 0.01)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Opacity(
                  opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0),
                  child: IgnorePointer(
                    key: const ValueKey('anime-header-collapsed-guard'),
                    ignoring: t < 0.5,
                    child: _buildCollapsedHeader(theme),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 展开态完整头：手机/平板为 Column（logo/标题/双源切换 + 搜索/类型 + 胶囊），
  /// 桌面为工具栏 + 胶囊。
  Widget _buildExpandedHeader(ThemeData theme, double height) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    return SizedBox(
      height: height,
      child: SafeArea(
        bottom: false,
        child: isDesktop
            ? Padding(
                padding: const EdgeInsets.fromLTRB(32, 10, 32, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildToolbarRow(theme),
                    const SizedBox(height: 10),
                    _buildChips(theme),
                  ],
                ),
              )
            : _buildMobileExpandedHeader(theme),
      ),
    );
  }

  /// 手机/平板展开态完整头：logo 行（标题 + 源切换胶囊）+ 搜索/类型 + 胶囊。
  Widget _buildMobileExpandedHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isTablet = Responsive.isTablet(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        6,
        Responsive.pagePadding(context),
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // logo 行与 home 同构（裸 Text 不包 Column，否则 Column 的基线
          // 参照点会让 logo 图标与文字纵向错位、换页即变位置）。
          Row(
            children: [
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
              // 源切换胶囊（点击切源）：移动端唯一源切换入口。
              // 样式与桌面工具栏胶囊、home _SourceSwitchButton 一致（primary 色调），
              // 避免换页时 logo 旁的胶囊样式跳变。
              GestureDetector(
                onTap: _pickSource,
                child: TapTargetMin(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.10),
                      // 源切换胶囊：极简锁原 999（胶囊全圆），小米/苹果走风格档位。
                      borderRadius: BorderRadius.circular(
                          context.uiStyle == UIStyle.minimalist
                              ? R.pill
                              : StyleTokens.controlRadius(context)),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.22),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.public_rounded,
                            size: 14, color: scheme.primary),
                        const SizedBox(width: 5),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: Text(
                            _source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        Icon(Icons.keyboard_arrow_down_rounded,
                            size: 15, color: scheme.primary),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 搜索栏 + 漫画/动漫切换（同一行）
          Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: Responsive.fieldMaxWidth(context)),
                  child: _animeSearch(theme),
                ),
              ),
              const SizedBox(width: 10),
              TypeSegment(
                type: widget.type,
                onChanged: widget.onTypeChanged,
              ),
            ],
          ),
          const SizedBox(height: 4),
          _buildChips(theme),
        ],
      ),
    );
  }

  /// 收起态头部：手机端为搜索 + 类型切换（保核心操作），桌面为完整工具栏。
  Widget _buildCollapsedHeader(ThemeData theme) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    final bar = Container(
      height: kToolbarHeight,
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 32 : Responsive.pagePadding(context),
        2,
        isDesktop ? 32 : Responsive.pagePadding(context),
        2,
      ),
      alignment: Alignment.center,
      child: isDesktop
          ? _buildToolbarRow(theme)
          : Row(
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: Responsive.fieldMaxWidth(context)),
                    child: _animeSearch(theme),
                  ),
                ),
                const SizedBox(width: 10),
                TypeSegment(
                  type: widget.type,
                  onChanged: widget.onTypeChanged,
                ),
              ],
            ),
    );
    // 苹果：固定悬浮头部用真毛玻璃；极简/小米保持原纯色底（原值 =
    // scaffoldBackgroundColor）。
    return context.uiStyle == UIStyle.apple
        ? FrostedGlass(child: bar)
        : Container(color: theme.scaffoldBackgroundColor, child: bar);
  }

  /// 桌面工具栏行（展开/收起两态共用）：搜索 + 番剧源切换 + 刷新 + 类型分段。
  /// 窄窗（逻辑宽 <600dp，桌面窗口拖成手机式竖条时）不进入本方法——头部走
  /// 手机式 Column（_buildMobileExpandedHeader），避免一行塞不下而拥挤/溢出。
  Widget _buildToolbarRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    final searchMaxWidth =
        Responsive.widthOf(context) * 0.5 <= 520.0
            ? Responsive.widthOf(context) * 0.5
            : 520.0;
    return Row(
      children: [
        Expanded(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: searchMaxWidth),
            child: _animeSearch(theme),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _pickSource,
          child: TapTargetMin(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.22),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.public_rounded,
                      size: 15, color: scheme.primary),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(
                      _source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  Icon(Icons.keyboard_arrow_down_rounded,
                      size: 16, color: scheme.primary),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: '刷新',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          color: scheme.onSurface.withValues(alpha: 0.7),
        ),
        const Spacer(),
        TypeSegment(
          type: widget.type,
          onChanged: widget.onTypeChanged,
        ),
      ],
    );
  }

  Widget _animeSearch(ThemeData theme) {
    final scheme = theme.colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.surface,
        // 搜索栏圆角：极简锁原 10（回归面为零）。
        borderRadius: BorderRadius.circular(
            context.uiStyle == UIStyle.minimalist
                ? 10
                : StyleTokens.controlRadius(context)),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.06),
          width: 0.6,
        ),
      ),
      child: TextField(
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onSubmitted: (v) {
          _keyword = v;
          _switchMode('search');
        },
        style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
        decoration: InputDecoration(
          hintText: '搜索番剧、剧场版…',
          hintStyle: TextStyle(
            fontSize: 13,
            color: T.color(scheme.onSurface, TextTier.low,
                brightness: scheme.brightness),
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 19,
            color: T.color(scheme.onSurface, TextTier.low,
                brightness: scheme.brightness),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: InputBorder.none,
        ),
      ),
    );
  }

  // _typeSegment 已移至 responsive.dart 作为共享组件 TypeSegment

  Widget _buildChips(ThemeData theme) {
    final primary = theme.colorScheme.secondary;
    // 分类 chip 圆角：极简锁原 10（回归面为零），小米/苹果走风格档位。
    final chipRadius = context.uiStyle == UIStyle.minimalist
        ? 10.0
        : StyleTokens.controlRadius(context);
    return SizedBox(
      height: Responsive.isTablet(context) ? 48 : 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: Responsive.pagePadding(context)),
        children: [
          for (final c in _sourceCats)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: PressableScale(
                onTap: () => _switchMode('category', categoryId: c.id),
                scale: 0.94,
                focusable: true, // TV 遥控器 D-pad 焦点导航
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: _categoryId == c.id && _mode == 'category'
                        ? primary
                        : theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(chipRadius),
                    border: Border.all(
                      color: _categoryId == c.id && _mode == 'category'
                          ? primary
                          : theme.colorScheme.outline,
                    ),
                    // Minimalist：选中态仅以填充 + 描边区分，不使用辉光。
                    boxShadow: const [],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (c.id == 'all-all-all-all-all-time-1')
                        Icon(
                          Icons.local_fire_department_rounded,
                          size: 14,
                          color: _categoryId == c.id && _mode == 'category'
                              ? Colors.white
                              : theme.colorScheme.onSurface.withValues(alpha: 0.65),
                        ),
                      if (c.id == 'all-all-all-all-all-time-1')
                        const SizedBox(width: 4),
                      Text(
                        c.name,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: _categoryId == c.id && _mode == 'category'
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: _categoryId == c.id && _mode == 'category'
                              ? Colors.white
                              : theme.colorScheme.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 正在打开详情（防止 detail 请求期间重复点击并发 push 多个选集页）。
  String? _openingId;

  void _openDetail(ComicItem it) async {
    if (_openingId != null) return;
    setState(() => _openingId = it.id);
    HapticFeedback.selectionClick();
    final source = _source;
    try {
      final detail = await source.detail(it.id);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => EpisodeListPage(source: source, detail: detail)),
      );
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '打开失败，请检查网络后重试');
      }
      ErrorLogger.instance.warn('anime open detail failed: $e');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
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
            AppToast.info(context, '已复制「${it.name}」',
                duration: const Duration(seconds: 2));
          },
        ),
      ];
}

class _AnimeCard extends StatefulWidget {
  final ComicItem item;
  final VoidCallback onTap;
  /// 详情请求期间置 true：卡片覆盖半透明 spinner，提供点击反馈。
  final bool loading;
  const _AnimeCard({
    required this.item,
    required this.onTap,
    this.loading = false,
  });

  @override
  State<_AnimeCard> createState() => _AnimeCardState();
}

class _AnimeCardState extends State<_AnimeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    final cardR = StyleTokens.cardRadius(context);
    // 极简锁原值：原版本无描边；仅小米/苹果走 StyleTokens（小米无、苹果细分隔线）。
    final cardBorder = style == UIStyle.minimalist
        ? null
        : StyleTokens.cardBorder(context);
    final cardShadows = StyleTokens.cardShadow(context);
    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
      decoration: BoxDecoration(
        borderRadius: style == UIStyle.xiaomi ? null : BorderRadius.circular(cardR),
        // Minimalist：卡片无投影，悬停仅微位移反馈。
        border: cardBorder == null
            ? null
            : Border.all(color: cardBorder.color, width: cardBorder.width),
        boxShadow: cardShadows ?? const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cardR),
        child: Container(
          // 小米渐变底色由外层 ClipPath 包裹提供，此处透明以免盖住渐变。
          color: style == UIStyle.xiaomi ? Colors.transparent : scheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      // 无封面源（如 Anime1 纯文本站）用首字占位封面，避免千篇一律的空占位图
                      child: widget.item.pic.isEmpty
                          ? _LetterCover(
                              title: widget.item.name,
                              scheme: scheme,
                              remark: widget.item.remarks)
                          : CachedImage(widget.item.pic,
                              fit: BoxFit.cover,
                              radius: 0,
                              fallbackUrls: [
                                if (widget.item.picFallback?.isNotEmpty ?? false)
                                  widget.item.picFallback!,
                              ]),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 32,
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
                          color: scheme.secondary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '动漫',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    if (widget.item.score != null &&
                        widget.item.score!.isNotEmpty &&
                        widget.item.score != '0')
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star_rounded,
                                  size: 10, color: Colors.amber),
                              const SizedBox(width: 2),
                              Text(
                                widget.item.score!,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.amber,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (widget.item.remarks != null &&
                        widget.item.remarks!.isNotEmpty)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.78),
                                Colors.transparent,
                              ],
                            ),
                          ),
                          child: Text(
                            widget.item.remarks!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: _hover ? 48 : 36,
                        height: _hover ? 48 : 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.secondary.withValues(alpha: _hover ? 0.9 : 0.7),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                    if (widget.loading)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.45),
                          child: const Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
                child: Text(
                  widget.item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 小米：超椭圆剪裁 + 品牌渐变底色包（渐变铺在底色之下，内容照常叠放）。
    if (style == UIStyle.xiaomi) {
      final gradient = StyleTokens.cardGradient(context);
      if (gradient != null) {
        card = ClipPath(
          clipper: SquircleClipper(radius: cardR),
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: gradient),
            child: card,
          ),
        );
      }
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        focusable: true, // TV 遥控器 D-pad 焦点导航（动漫网格卡）
        child: card,
      ),
    );
  }
}

class _LetterCover extends StatelessWidget {
  final String title;
  final ColorScheme scheme;
  /// 更新/完结状态提示（如"更新至第19集"），无封面时展示更友好
  final String? remark;
  const _LetterCover({required this.title, required this.scheme, this.remark});

  @override
  Widget build(BuildContext context) {
    final t = title.trim();
    final letter = t.isEmpty ? '?' : t.characters.first.toUpperCase();
    const palette = [
      Color(0xFF5B7FFF), Color(0xFF4FC3A1), Color(0xFFEF6C6C),
      Color(0xFFF2A65A), Color(0xFF8E7CF5), Color(0xFF3FA7D6),
      Color(0xFFE06FB4), Color(0xFF6FA86F),
    ];
    var hash = 0;
    for (final c in t.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    final bg = palette[hash % palette.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bg.withValues(alpha: 0.95), bg.withValues(alpha: 0.6)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 大首字水印（轻透明白）
          Positioned(
            top: 6,
            left: 10,
            child: Text(
              letter,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: 0.22),
              ),
            ),
          ),
          // 底部：完整标题 + 更新备注，让无封面卡片也有作品标识
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 6),
                    ],
                  ),
                ),
                if (remark != null && remark!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      remark!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态引导：加载完成但源没有返回内容时展示，风格对齐 bookshelf 的 _TabEmpty
/// （渐变圆环图标 + 标题 + 引导副文案 + 行动按钮），自包含不依赖其它文件。
class _EmptyView extends StatelessWidget {
  final VoidCallback onRetry;
  const _EmptyView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: isDark ? 0.22 : 0.16),
                  scheme.primary.withValues(alpha: 0.03),
                ],
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: isDark ? 0.16 : 0.10),
              ),
              child: Icon(Icons.movie_filter_outlined,
                  size: 36, color: scheme.primary),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '暂无内容',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '源没有返回内容，试试换个分类或下拉刷新',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    height: 1.5,
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

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
              child: Icon(Icons.cloud_off_outlined,
                  size: 44, color: scheme.error),
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

// ─────────────────────────────────────────────────────────────────────────────
// 动漫页滚动收起头部 delegate
// ─────────────────────────────────────────────────────────────────────────────

/// 动漫页头部的 SliverPersistentHeader delegate：展开为完整头部，收起为单行
/// 精简栏。shrinkOffset 由滚动位置驱动，build 返回随收缩变化的过渡层，
/// 动画连续跟随滚动 —— 与 home_page 的 _HomeHeaderDelegate 同构。
class _AnimeHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _AnimeHeaderDelegate({
    required double minExtent,
    required double maxExtent,
    required this.builder,
  })  : _minExtent = minExtent,
        _maxExtent = maxExtent;

  final double _minExtent;
  final double _maxExtent;

  /// (context, shrinkOffset, overlapsContent) → 当前头部视图。
  final Widget Function(BuildContext, double, bool) builder;

  @override
  double get minExtent => _minExtent;

  @override
  double get maxExtent => _maxExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return builder(context, shrinkOffset, overlapsContent);
  }

  @override
  bool shouldRebuild(covariant _AnimeHeaderDelegate oldDelegate) {
    return oldDelegate._minExtent != _minExtent ||
        oldDelegate._maxExtent != _maxExtent ||
        oldDelegate.builder != builder;
  }
}
