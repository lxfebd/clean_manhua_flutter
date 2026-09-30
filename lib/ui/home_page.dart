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
import 'responsive.dart';
import 'style_scope.dart';
import 'style_tokens.dart';
import 'tokens.dart';
import 'unified_search_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/app_toast.dart';
import 'widgets/frosted_glass.dart';
import 'widgets/motion.dart';
import 'widgets/skeleton.dart';
import 'widgets/squircle.dart';
import 'widgets/state_view.dart';
import 'widgets/tap_target.dart';

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
        final items = _dedup(raw
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
  /// 去重后渲染，避免网格内多个同 tag Hero 触发「multiple heroes」崩溃。
  static List<ComicItem> _dedup(List<ComicItem> items) {
    final seen = <String>{};
    return [for (final it in items) if (it.id.isNotEmpty && seen.add(it.id)) it];
  }

  /// 网络拉取成功后将首页数据落盘，供下次启动打底。
  Future<void> _saveSnapshot(List<ComicItem> items) async {
    try {
      await LocalStore.writeJson(
          _snapshotKey, _dedup(items).map((e) => e.toMap()).toList());
    } catch (e) {
      // 写快照失败不影响主流程
      ErrorLogger.instance.warn('saveSnapshot failed: $e');
    }
  }

  /// 首页榜单快照文件名：按模式+关键字区分，避免切换污染。
  String get _snapshotKey {
    switch (_mode) {
      case 'category':
        return 'home_snapshot_category_$_categoryId';
      case 'search':
        return 'home_snapshot_search_$_keyword';
      default:
        return 'home_snapshot_rank_${SourceManager.current.id}';
    }
  }

  void _onScroll() {
    if (_noMore || _loading) return;
    if (_scrollCtrl.position.pixels >
        _scrollCtrl.position.maxScrollExtent - 400) {
      _loadMore();
    }
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
            ..addAll(_dedup(r));
          _page = 2;
          _error = null;
          _loadMoreFailed = false;
        });
      } else {
        setState(() {
          // 源站榜单粘页时同一作品可能跨页重复，合并后整体去重。
          // 必须先构造合并结果再一次性替换——先 clear() 再展开 _items
          // 得到的是空列表，会把之前所有页顶掉（整页重刷、滚动位置丢失）。
          final merged = _dedup([..._items, ...r]);
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
                      style: TextStyle(
                          fontSize: 12.5, color: theme.colorScheme.primary)),
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
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.35))),
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
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final textSlack = (textScale - 1.0).clamp(0.0, 1.0) * 60;
    final expanded =
        (isDesktop ? 128.0 : (isTablet ? 176.0 : 168.0)) + textSlack + topPad;
    final collapsed = kToolbarHeight + topPad;
    return SliverPersistentHeader(
      pinned: true,
      delegate: _HomeHeaderDelegate(
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
  /// 精简栏从底部淡入（极简/小米带不透明底，遮住下层重叠的展开态内容；
  /// 苹果是半透明毛玻璃，靠 pinned 头部画在滚过它的内容之上）。
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
                    key: const ValueKey('home-header-collapsed-guard'),
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
        // 命中区 ≥44×44：内容高度约 36，TapTargetMin 放手势组件内部，
        // 把手势盒子撑到 44（HoverEffect 热区跟随 child）。
        child: TapTargetMin(
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
    // 风格化：搜索框圆角走 controlRadius 语义槽；极简锁原 R.card=12（回归面为零）。
    final searchRadius = context.uiStyle == UIStyle.minimalist
        ? R.card
        : StyleTokens.controlRadius(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(searchRadius),
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
                  color: T.color(scheme.onSurface, TextTier.low,
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
                        tooltip: '清空',
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
      padding: const EdgeInsets.symmetric(horizontal: 4),
      // 命中区 ≥44×44：胶囊视觉高度 32，TapTargetMin 放手势组件内部作 child，
      // 才能把手势盒子撑到 44（外层 Padding 只负责胶囊间横向间距）。
      child: PressableScale(
        onTap: onTap,
        scale: 0.94,
        focusable: true, // TV 遥控器 D-pad 焦点导航
        child: TapTargetMin(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // 选中态用 primary 底 + onPrimary 字：明暗两套主题都自动满足对比度。
              // （旧实现 onSurface 底 + 写死 Colors.white 字，暗色下对比度仅 1.20）
              // 分类胶囊圆角：极简锁原 R.pill（胶囊全圆），小米/苹果走风格档位。
              // 尺寸/padding 44dp 热区完全不动。
              color: active ? scheme.primary : scheme.surface,
              borderRadius: BorderRadius.circular(
                  context.uiStyle == UIStyle.minimalist
                      ? R.pill
                      : StyleTokens.controlRadius(context)),
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
  /// 详情页 push 防连点锁（独立于网格卡的锁：Banner 无原生 Navigator 流程，
  /// 手推 MaterialPageRoute，返回后释放）。
  bool _openingDetail = false;

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
                    if (_openingDetail) return; // 防连点：push 动画期间忽略重复点击
                    _openingDetail = true;
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
                    ).whenComplete(() {
                      _openingDetail = false; // 返回后释放锁
                    });
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
        focusable: true, // TV 遥控器 D-pad 焦点导航（轮播大卡）
        child: ClipRRect(
          // 全宽大图只改圆角（视觉风险小），渐变/Squircle 改造成本高不动。
          // 轮播是全宽大卡 → hero 槽位：极简锁原值 12，小米 28 / 苹果 16。
          borderRadius: BorderRadius.circular(StyleTokens.heroRadius(context, 12)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 轮播卡不用 Hero：同一作品也会出现在下方热榜网格里，
              // 共用 tag 会触发「multiple heroes share the same tag」。
              CachedImage(
                item.pic,
                fit: BoxFit.cover,
                radius: 0,
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
    final style = context.uiStyle;
    final cardR = StyleTokens.cardRadius(context);
    // 三套风格差异化（仅在装饰层按风格分支，尺寸/padding/热区一律不动）：
    //   minimalist：与既有实现逐字节一致（surface 底 + 圆角 + 无阴影）。
    //   xiaomi：内容底改品牌渐变 + SquircleClipper 剪裁（HyperOS 特征）。
    //   apple：surface 底 + StyleTokens.cardBorder 细分隔线。
    // hover 位移 -4 三风格通用保留（交互语义，非风格视觉）。
    final Widget cardContent;
    if (style == UIStyle.xiaomi) {
      // 小米：内容底改品牌渐变 + SquircleClipper 剪裁（decoration.gradient
      // 承接 Gradient 类型；不用 color 走 Color 通道，避免类型冲突）。
      cardContent = ClipPath(
        clipper: SquircleClipper(radius: cardR),
        child: Container(
          color: scheme.surface,
          decoration: BoxDecoration(
            gradient: StyleTokens.cardGradient(context),
          ),
          child: _body(context),
        ),
      );
    } else if (style == UIStyle.apple) {
      cardContent = ClipRRect(
        borderRadius: BorderRadius.circular(cardR),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border.fromBorderSide(StyleTokens.cardBorder(context)!),
          ),
          child: _body(context),
        ),
      );
    } else {
      // minimalist：保持原实现（外层装饰圆角 + 内层 ClipRRect + surface 底）。
      cardContent = ClipRRect(
        borderRadius: BorderRadius.circular(cardR),
        child: Container(
          color: scheme.surface,
          child: _body(context),
        ),
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        focusable: true, // TV 遥控器 D-pad 焦点导航（热榜网格卡）
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(cardR),
            // Minimalist：卡片不使用投影，悬停仅以微位移反馈。
            boxShadow: const [],
          ),
          child: cardContent,
        ),
      ),
    );
  }

  /// 卡片内容体（封面 + 作者/更新角标 + 标题）：三风格共用，仅装饰层分支。
  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                // 网格卡不用 Hero：同一作品会出现在多个 tab 的同款列表中
                // （首页/漫画 tab 都是 HomePage 实例，IndexedStack 同时保活
                // 所有 tab），同 tag 会触发「multiple heroes share the same tag」。
                child: CachedImage(
                  widget.item.pic,
                  fit: BoxFit.cover,
                  radius: 0,
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
            Flexible(
              // 源数量多时在弹窗内滚动，保证底部源不被导航手势区裁剪。
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: sources.length,
                itemBuilder: (context, i) => FadeSlideIn(
                  delay: Duration(milliseconds: 40 * i),
                  offset: 8,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(
                        StyleTokens.cardRadiusOr(context, 12)),
                    onTap: () => onSelected(i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: i == currentIndex
                            ? scheme.primary.withValues(alpha: 0.10)
                            : scheme.surfaceContainerHighest
                                .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(
                            StyleTokens.cardRadiusOr(context, 12)),
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
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
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
              ),
            ),
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
// 首页滚动收起头部 delegate
// ─────────────────────────────────────────────────────────────────────────────

/// 首页头部的 SliverPersistentHeader delegate：展开为完整头部，收起为单行
/// 精简栏。shrinkOffset 由滚动位置驱动，build 返回随收缩变化的过渡层，
/// 动画连续跟随滚动（对比 SliverAppBar：其 toolbar 区被不透明背景占用且
/// title 常显，放不下展开/收起两套布局）。
class _HomeHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HomeHeaderDelegate({
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
  bool shouldRebuild(covariant _HomeHeaderDelegate oldDelegate) {
    return oldDelegate._minExtent != _minExtent ||
        oldDelegate._maxExtent != _maxExtent ||
        oldDelegate.builder != builder;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 加载 & 错误态
// ─────────────────────────────────────────────────────────────────────────────

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

  /// 本次搜索关键词：空态进入全源搜索时沿用（可为空则用原关键词）。
  final String keyword;

  /// 刷新回调（rank/分类空态的主行动按钮）。
  final VoidCallback onRefresh;

  /// 跨源全量搜索回调（仅搜索空态展示，为 null 时隐藏）。
  final ValueChanged<String>? onSearchAll;

  const _EmptyState({
    required this.mode,
    this.keyword = '',
    required this.onRefresh,
    this.onSearchAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSearch = mode == 'search';
    final isRank = mode == 'rank';
    final text = isSearch
        ? '没有找到相关结果'
        : isRank
            ? '排行榜暂无内容'
            : '该分类暂时没有内容';
    final subtitle = isSearch
        ? '换个关键词试试，也可以直接去全源搜索'
        : isRank
            ? '下拉刷新试试，精彩内容持续更新中'
            : '换个分类看看，精彩内容持续更新中';
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
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              if (isSearch && onSearchAll != null) {
                onSearchAll!(keyword.trim());
              } else {
                onRefresh();
              }
            },
            icon: Icon(isSearch ? Icons.public_rounded : Icons.refresh_rounded,
                size: 18),
            label: Text(isSearch ? '全源搜索' : '刷新'),
          ),
        ],
      ),
    );
  }
}
// _TypeSegment 已移至 responsive.dart 作为共享组件 TypeSegment

/// 猜你喜欢：横向滑动封面列表（自「我的」页迁移至首页推荐流）。
class _RecommendCard extends StatelessWidget {
  final List<RecommendItem> items;
  final ValueChanged<RecommendItem> onOpen;
  const _RecommendCard({required this.items, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) return const SizedBox.shrink();
    // 风格化（横向大卡内的小封面卡）：
    //   minimalist：直接 StyleTokens.cardRadius，无渐变无描边。
    //   xiaomi：SquircleClipper + 渐变底（超椭圆剪裁 + 品牌渐变）。
    //   apple：surface 底 + cardBorder 细分隔线。
    // 布局尺寸（96x128 封面、10 间距、156 行高）保持原值不变。
    final style = context.uiStyle;
    final cardR = StyleTokens.cardRadius(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '猜你喜欢',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            '基于本地阅读历史的纯本地推荐，不上传任何数据',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
          ),
          const SizedBox(height: 10),
          // 128 封面 + 4 间距 + 1 行标题：148 会差 1px 溢出黄条，留足行高。
          SizedBox(
            height: 156,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final r = items[i];
                final Widget coverImage;
                if (style == UIStyle.xiaomi) {
                  coverImage = ClipPath(
                    clipper: SquircleClipper(radius: cardR),
                    child: Container(
                      color: scheme.surface,
                      decoration: BoxDecoration(
                        gradient: StyleTokens.cardGradient(context),
                      ),
                      child: CachedImage(
                        r.item.pic,
                        width: 96,
                        height: 128,
                        fit: BoxFit.cover,
                        radius: 0,
                      ),
                    ),
                  );
                } else if (style == UIStyle.apple) {
                  coverImage = ClipRRect(
                    borderRadius: BorderRadius.circular(cardR),
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        border:
                            Border.fromBorderSide(StyleTokens.cardBorder(context)!),
                      ),
                      child: CachedImage(
                        r.item.pic,
                        width: 96,
                        height: 128,
                        fit: BoxFit.cover,
                        radius: 0,
                      ),
                    ),
                  );
                } else {
                  coverImage = ClipRRect(
                    borderRadius: BorderRadius.circular(cardR),
                    child: CachedImage(
                      r.item.pic,
                      width: 96,
                      height: 128,
                      fit: BoxFit.cover,
                      radius: 0,
                    ),
                  );
                }
                return SizedBox(
                  width: 96,
                  child: GestureDetector(
                    onTap: () => onOpen(r),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        coverImage,
                        const SizedBox(height: 4),
                        Text(
                          r.item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurface,
                              ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
