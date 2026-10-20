import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/comic_item.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import '../utils/local_recommender.dart';
import 'detail_page.dart';
import 'home_feed_paging.dart';
import 'responsive.dart';
import 'style_scope.dart';
import 'style_tokens.dart';
import 'tokens.dart';
import 'unified_search_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/app_toast.dart';
import 'widgets/frosted_glass.dart';
import 'widgets/home_header.dart';
import 'widgets/motion.dart';
import 'widgets/skeleton.dart';
import 'widgets/squircle.dart';
import 'widgets/state_view.dart';
import 'widgets/tap_target.dart';

part 'home_widgets.dart';

/// 首页：搜索 + 横向 Hero + 分类胶囊 + 漫画网格（错峰入场）
class HomePage extends StatefulWidget {
  /// 0=漫画 1=动漫（由外层 MangaAnimeTabs 驱动）
  final int type;
  final ValueChanged<int>? onTypeChanged;
  const HomePage({super.key, this.type = 0, this.onTypeChanged});

  @override
  State<HomePage> createState() => HomePageState();
}

/// 公开 State：主壳经 GlobalKey 调 [refresh]（Ctrl+R 分发）。
class HomePageState extends State<HomePage> {
  final _items = <ComicItem>[];
  int _page = 1;
  bool _loading = false;
  /// 请求代际：换源/切分类/刷新时自增，作废在途旧请求，防止慢响应覆盖新列表。
  int _loadGen = 0;
  String _mode = 'rank';
  String _categoryId = '';
  String _keyword = '';
  String? _error;
  bool _done = false; // 首屏请求是否已结束（区分加载中与空结果）
  bool _loadMoreFailed = false; // 分页加载失败（非空列表时仅影响尾部重试条）
  bool _noMore = false; // 源已返回空页：底部展示"没有更多了"，停止空转请求
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<Category> _cats = [];
  List<RecommendItem> _recommends = [];

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadCategories();
    _loadRecommends();
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
      ErrorLogger.instance.warn('loadCategories failed: $e');
      if (mounted) AppToast.info(context, '分类列表加载失败，请稍后重试');
    }
  }

  /// 猜你喜欢：基于本地阅读历史的纯本地推荐，失败静默（不给空态打扰）。
  Future<void> _loadRecommends() async {
    try {
      final history = await LocalStore.history();
      final recs = await LocalRecommender.recommend(history: history);
      final items =
          recs.isNotEmpty ? recs : await LocalRecommender.fallbackRanking();
      if (mounted && items.isNotEmpty) setState(() => _recommends = items);
    } catch (e) {
      ErrorLogger.instance.warn('loadRecommends failed: $e');
    }
  }

  void _openRecommend(RecommendItem r) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: r.sourceId,
          comicId: r.item.id,
          name: r.item.name,
          pic: r.item.pic,
        ),
      ),
    );
  }

  /// 主壳 Ctrl+R 刷新入口：保留当前列表与滚动位置重拉。
  void refresh() => _refresh();

  /// 刷新首页数据：默认保留现有条目做背景更新，成功后原地替换并尽力恢复
  /// 滚动位置，避免清屏重拉造成闪空/回顶。[keepItems=false] 用于首进等
  /// 明确需要全新列表的场景。
  Future<void> _refresh({bool keepItems = true}) async {
    _error = null;
    _done = false;
    _loadMoreFailed = false;
    _noMore = false;
    _autoLoad.reset(); // 新一轮续页额度重新计算
    _loadGen++; // 作废在途旧请求
    // 记录旧列表与滚动偏移：成功后替换数据并把滚动位置跳回原位。
    final restoreOffset =
        _items.isNotEmpty ? (_scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0) : null;
    if (!keepItems) _items.clear();
    setState(() {});
    _loadCategories();
    // 首屏本地快照打底：先渲染上次成功缓存的榜单，网络回来后覆盖。
    // 弱网/离线时首页不再空白，且首帧内容立即可见。
    if (_mode == 'rank') {
      await _loadCachedSnapshot();
    }
    await _loadMore(replaceFirst: keepItems, restoreOffset: restoreOffset);
    // 若当前源在源管理里被禁用，回退到第一个启用源
    await SourceManager.ensureEnabledCurrent().then((_) {
      if (mounted) setState(() {});
    });
  }

  /// 首页本地快照：上次成功拉取的榜单（仅 rank 模式全新列表页第一页时打底）。
  /// 读到即渲染；网络成功后由 [_saveSnapshot] 覆盖为新数据。
  Future<void> _loadCachedSnapshot() async {
    try {
      final key = _snapshotKey;
      final raw = await LocalStore.readJson(key);
      if (raw is List && raw.isNotEmpty) {
        final items = HomeFeedPaging.dedupById(raw
            .whereType<Map>()
            .map((m) => ComicItem.fromMap(Map<String, dynamic>.from(m)))
            .toList());
        if (mounted && _items.isEmpty) {
          setState(() {
            _items.addAll(items);
            _error = null;
            _done = true;
          });
        }
      }
    } catch (e) {
      // 快照损坏/缺失：静默忽略，走正常网络加载
      ErrorLogger.instance.warn('loadCachedSnapshot failed: $e');
    }
  }

  /// 源站榜单偶发返回重复条目（同一作品多次出现）：
  /// 去重逻辑已收敛为 [HomeFeedPaging.dedupById]（home/anime 同用一份）。

  /// 网络拉取成功后将首页数据落盘，供下次启动打底。
  Future<void> _saveSnapshot(List<ComicItem> items) async {
    try {
      await LocalStore.writeJson(
          _snapshotKey, HomeFeedPaging.dedupById(items).map((e) => e.toMap()).toList());
    } catch (e) {
      // 写快照失败不影响主流程
      ErrorLogger.instance.warn('saveSnapshot failed: $e');
    }
  }

  /// 首页榜单快照文件名：仅 rank 模式读写（_loadCachedSnapshot 在 _refresh
  /// 里 `if (_mode == 'rank')` 调用、_saveSnapshot 在 `next==1 && _mode=='rank'`
  /// 调用——category/search 分支从未触达，收敛掉死路径与连带路径注入面）。
  String get _snapshotKey =>
      'home_snapshot_rank_${SourceManager.current.id}';

  void _onScroll() {
    if (_noMore || _loading) return;
    if (HomeFeedPaging.nearBottom(_scrollCtrl)) {
      _loadMore();
    }
  }

  /// 内容不满一屏时自动续页（逻辑在 [AutoLoadMore]：额度 3 次，post-frame 判定）。
  final AutoLoadMore _autoLoad = AutoLoadMore();
  void _maybeAutoLoadMore() {
    _autoLoad.schedule(
      canLoad: () => mounted && !_loading && !_noMore,
      scrollCtrl: _scrollCtrl,
      onLoad: _loadMore,
    );
  }

  Future<void> _loadMore(
      {bool replaceFirst = false, double? restoreOffset}) async {
    if (_loading || _noMore) return;
    _loading = true;
    final gen = _loadGen;
    // 异步续体可能在组件被 dispose 后恢复（切 tab / 换源），
    // 此时必须带 mounted 保护，否则 setState 在 _element 为 null 时抛 Null check。
    if (mounted && _items.isEmpty) setState(() => _error = null);
    _loadMoreFailed = false;
    _noMore = false;
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
      // 换源/切分类后旧请求作废：不覆写新列表，也不更新滚动位置。
      if (!mounted || gen != _loadGen) return;
      // 空页 = 已到底：置标记停止后续空转请求，尾部展示"没有更多了"。
      if (r.isEmpty) {
        if (mounted) setState(() => _noMore = true);
      }
      if (replaceFirst) {
        // 刷新模式：用第一页结果整体替换旧列表
        setState(() {
          _items
            ..clear()
            ..addAll(HomeFeedPaging.dedupById(r));
          _page = 2;
          _error = null;
          _loadMoreFailed = false;
        });
      } else {
        setState(() {
          // 源站榜单粘页时同一作品可能跨页重复，合并后整体去重。
          // 必须先构造合并结果再一次性替换——先 clear() 再展开 _items
          // 得到的是空列表，会把之前所有页顶掉（整页重刷、滚动位置丢失）。
          final merged = HomeFeedPaging.dedupById([..._items, ...r]);
          _items
            ..clear()
            ..addAll(merged);
          _page++;
          _error = null;
          _loadMoreFailed = false;
        });
      }
      // 首页第一页成功后更新快照（不阻塞主流程）
      if (next == 1 && _mode == 'rank') {
        _saveSnapshot(r);
      }
      // 内容不满一屏时自动续页（最多 3 次），避免首屏太短"很快到底"
      _maybeAutoLoadMore();
      // 刷新模式替换数据后把滚动位置跳回原位，避免回顶闪空。
      if (replaceFirst && restoreOffset != null && _scrollCtrl.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(restoreOffset.clamp(
                0.0, _scrollCtrl.position.maxScrollExtent));
          }
        });
      }
    } catch (e) {
      ErrorLogger.instance.warn('home loadMore failed: $e');
      if (mounted && gen == _loadGen) {
        String msg;
        if (kIsWeb && (e.toString().contains('Failed to fetch') ||
            e.toString().contains('CORS'))) {
          msg = '该源不支持浏览器访问（CORS 限制），请换用支持跨域的源（如 MangaDex）';
        } else {
          msg = '加载失败，请检查网络';
        }
        setState(() {
          if (_items.isEmpty) {
            // 首屏失败：整页错误态
            _error = msg;
          } else {
            // 分页失败：保留已有内容，置分页失败标记供尾部重试条显示
            _loadMoreFailed = true;
          }
        });
      }
    } finally {
      _loading = false;
      _done = true;
    }
  }

  void _switchMode(String mode, {String? categoryId}) {
    _mode = mode;
    if (categoryId != null) _categoryId = categoryId;
    // 切分类/搜索：全新列表，不清屏重拉。
    _refresh(keepItems: false);
  }

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
      cacheExtent: HomeFeedPaging.prefetchCacheExtent,
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
        onRefresh: _refresh,
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

  /// 内容区 slivers：错误/空态/加载为整屏区块，正常态为横幅 + 推荐 + 网格。
  List<Widget> _buildContentSlivers(ThemeData theme) {
    if (_error != null) {
      return [
        _fillRemaining(_ErrorState(message: _error!, onRetry: _refresh)),
      ];
    }
    if (_items.isEmpty) {
      return [
        _fillRemaining(_done
            ? _EmptyState(
                mode: _mode,
                keyword: _keyword,
                onRefresh: _refresh,
                onSearchAll: _openUnifiedSearch,
              )
            : HomeGridSkeleton(showRankBanner: _mode == 'rank')),
      ];
    }
    final isDesktop = DesktopUi.isDesktopPlatform;
    return [
        // 顶部大封面横幅（仅推荐模式下展示前 5 张作为精选）
        if (_mode == 'rank' && _items.length >= 5)
          SliverToBoxAdapter(
            child: FadeSlideIn(
              delay: const Duration(milliseconds: 80),
              duration: const Duration(milliseconds: 540),
              child: _FeaturedBanner(items: _items.take(5).toList()),
            ),
          ),
        // 猜你喜欢：精选横幅之后、榜单网格之前（推荐属于浏览动线）。
        if (_mode == 'rank' && _recommends.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pagePadding(context)),
              child:
                  _RecommendCard(items: _recommends, onOpen: _openRecommend),
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
                // 只对首屏做入场动画：追加页若仍逐张延迟，新卡片会重播
                // 0~550ms 入场并掀起定时器风暴（与动漫首页同一处理）。
                delay: _items.length <= 24
                    ? Duration(milliseconds: 50 * (i % 12))
                    : Duration.zero,
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
        // 分页加载失败：尾部重试条（保留已加载内容，不做整页错误态）
        if (_loadMoreFailed && !_loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: TextButton.icon(
                  onPressed: _loadMore,
                  icon: Icon(Icons.refresh_rounded,
                      size: 18, color: theme.colorScheme.primary),
                  label: Text('加载失败，点击重试',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
              ),
            ),
          ),
        // 已到底：底部展示结束提示，避免列表戛然而止
        if (_noMore && _items.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('已经到底啦',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.35),
                    )),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
    ];
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

  /// 滚动收起头部 sliver：展开为完整头部（logo/搜索/源切换/类型/分类胶囊），
  /// 收起为单行精简栏（搜索 + 类型切换；桌面为完整工具栏）。
  ///
  /// 用 SliverPersistentHeader 而非 SliverAppBar：SliverAppBar 的 toolbar 区
  /// （56dp）被不透明背景占用且 small variant 的 title 常显，无法同时容纳
  /// "完整头 + 收起头"两套布局；自绘 delegate 可精确控制展开/收起两态与
  /// 滚动过渡，动画随 shrinkOffset 连续映射、天然流畅（无第三方包）。
  Widget _buildHeaderSliver(ThemeData theme) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    final isTablet = Responsive.isTablet(context);
    final topPad = MediaQuery.paddingOf(context).top;
    // 展开高度 = 完整头自然高度（含 TapTargetMin 44 强制热区）+ 余量，
    // 溢出会触发 RenderFlex 黄条断言（收缩过程出现黄条即此）：
    // 手机 6+44logo行+10+48搜索行+8+44胶囊+4 = 164 → 168；
    // 平板 6+44+10+52+8+48+4 = 172 → 176；桌面 10+48工具栏+10+48胶囊+10 = 126 → 128。
    // 44 热区行不随文字长，但搜索行/标题行会随系统文字缩放长高
    // （1.5× 实测溢 2dp、2.0× 溢 28dp），故按缩放补余量。
    // 默认 1.0 缩放并非零风险：真实字体（微软雅黑/Segoe UI）行高比 Ahem
    // 略高，桌面工具栏/胶囊在实测中 126 → 128 仍溢 2px（runlog 组件链
    // OverflowBox→SizedBox(128)→Padding(20)→Column h=108 溢 2），
    // 故各档再补 8dp 安全余量。
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final textSlack = (textScale - 1.0).clamp(0.0, 1.0) * 60;
    final expanded =
        (isDesktop ? 136.0 : (isTablet ? 184.0 : 176.0)) + textSlack + topPad;
    final collapsed = kToolbarHeight + topPad;
    // 两态头部实例在页面 build 里创建一次，delegate 每帧只重算 Opacity/Transform
    // 外壳（与动漫首页同一处理）：SliverPersistentHeader 的 delegate 每次
    // constraints 变化都会重跑 builder，此前每次都重建整块头部（搜索框 / 分类
    // 胶囊 / Apple 风格 BackdropFilter），是桌面端滚动掉帧的主要来源。
    final expandedHeader = _buildExpandedHeader(theme, expanded);
    final collapsedHeader = _buildCollapsedHeader(theme);
    return SliverPersistentHeader(
      pinned: true,
      delegate: HomeHeaderDelegate(
        minExtent: collapsed,
        maxExtent: expanded,
        builder: (context, shrinkOffset, overlapsContent) {
          final current = (expanded - shrinkOffset).clamp(collapsed, expanded);
          final t =
              ((expanded - current) / (expanded - collapsed)).clamp(0.0, 1.0);
          return _buildShrinkableHeader(
              expanded, current, t, expandedHeader, collapsedHeader);
        },
      ),
    );
  }

  /// 展开态完整头与收起态精简栏的过渡：完整头随收缩淡出并上移，
  /// 精简栏从底部淡入（极简/小米带不透明底，遮住下层重叠的展开态内容；
  /// 苹果是半透明毛玻璃，靠 pinned 头部画在滚过它的内容之上）。
  Widget _buildShrinkableHeader(
    double expanded,
    double current,
    double t,
    Widget expandedHeader,
    Widget collapsedHeader,
  ) {
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
              key: const ValueKey('home-header-expanded-guard'),
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
                      child: expandedHeader,
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
                    key: const ValueKey('home-header-collapsed-guard'),
                    ignoring: t < 0.5,
                    child: collapsedHeader,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 展开态完整头：手机/平板为 Column（logo/标题/源切换 + 搜索/类型 + 胶囊），
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
                style: (isTablet
                        ? Theme.of(context).textTheme.titleLarge
                        : Theme.of(context).textTheme.displaySmall)
                    ?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: scheme.onSurface),
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
          const SizedBox(height: 8),
          // 搜索栏 + 漫画/动漫切换（同一行，对齐 UI_v2）
          Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: Responsive.fieldMaxWidth(context)),
                  child: _buildSearchBar(),
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
        4,
        isDesktop ? 32 : Responsive.pagePadding(context),
        4,
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
                    child: _buildSearchBar(),
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
    // 苹果：固定悬浮头部用真毛玻璃（pinned 头部画在滚过它的内容之上，
    // BackdropFilter 模糊的是下层，不是本层）；极简/小米保持原纯色底。
    return context.uiStyle == UIStyle.apple
        ? FrostedGlass(child: bar)
        : Container(color: theme.scaffoldBackgroundColor, child: bar);
  }

  /// 桌面工具栏行（展开/收起两态共用）：搜索 + 源切换 + 刷新 + 类型分段。
  Widget _buildToolbarRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _buildSearchBar(),
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
    );
  }

  Widget _buildSearchBar() {
    return _SearchBar(
      controller: _searchCtrl,
      onSubmit: (v) {
        _keyword = v;
        _switchMode('search');
      },
      onSearchAll: _openUnifiedSearch,
    );
  }

  /// 跨源全量搜索入口：搜索框 suffix 与搜索空态「全源搜索」按钮共用。
  void _openUnifiedSearch(String kw) {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UnifiedSearchPage(keyword: kw),
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
      // 源多时列表可能撑过半屏，放开默认 9/16 高度上限，由内部滚动接管。
      isScrollControlled: true,
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
    if (_openingDetail) return; // 防连点：push 动画期间忽略重复点击
    _openingDetail = true;
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
        transitionDuration: context.uiStyle == UIStyle.minimalist
            ? const Duration(milliseconds: 360)
            : StyleTokens.transitionDuration(context),
        transitionsBuilder: (_, anim, __, child) {
          final isMinimalist = context.uiStyle == UIStyle.minimalist;
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: anim,
              curve: isMinimalist
                  ? Curves.easeOut
                  : StyleTokens.transitionCurve(context),
            ),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: anim,
                curve: isMinimalist
                    ? Curves.easeOutCubic
                    : StyleTokens.transitionCurve(context),
              )),
              child: child,
            ),
          );
        },
      ),
    ).then((_) {
      _openingDetail = false; // 返回后释放锁
    });
  }

  bool _openingDetail = false; // 详情页 push 防连点锁

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
            AppToast.info(context, '已复制「${it.name}」');
          },
        ),
      ];
}

