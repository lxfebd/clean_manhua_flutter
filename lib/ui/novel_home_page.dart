import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'novel_detail_page.dart';
import 'novel_import_page.dart';
import 'responsive.dart';

import '../models/comic_item.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../sources/local_novel_source.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../net/novel_shelf_store.dart';
import '../ui/style_scope.dart';
import '../ui/style_tokens.dart';
import '../ui/tokens.dart';
import '../ui/widgets/cached_image.dart';
import '../ui/widgets/frosted_glass.dart';
import '../ui/widgets/motion.dart';
import '../ui/widgets/squircle.dart';

/// 小说首页：与漫画/动漫并列的第三种内容模式（首页模式切换的 type==2）。
class NovelHomePage extends StatefulWidget {
  final int type;
  final ValueChanged<int>? onTypeChanged;
  const NovelHomePage({super.key, this.type = 2, this.onTypeChanged});

  @override
  State<NovelHomePage> createState() => NovelHomePageState();
}

/// 公开 State：主壳经 GlobalKey 调 [refresh]（Ctrl+R 分发）。
class NovelHomePageState extends State<NovelHomePage> {
  List<NovelSource> _sources = [];
  bool _sourcesLoaded = false; // 源列表加载完成前不给空态，防「小说源即将接入」闪变
  String? _sourceId;
  final _scrollCtrl = ScrollController();
  bool _loading = false;
  String? _error;
  List<ComicItem> _items = [];
  List<NovelDetail> _shelf = [];
  List<Map<String, dynamic>> _localBooks = [];

  /// 书架卡的续读信息：book.key → 最近一条历史（上次读到哪章）。
  /// 一次性拉全量历史建映射，避免每张卡各自读盘。
  Map<String, HistoryEntry> _historyByKey = const {};

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 拉全量阅读历史，按书 key 建续读映射（详情页/阅读器返回后重刷）。
  Future<void> _loadHistory() async {
    try {
      final hist = await LocalStore.history();
      if (!mounted) return;
      final byKey = <String, HistoryEntry>{};
      // history() 已按时间倒序：同一本书多条记录时，先到先写即最新。
      for (final h in hist) {
        byKey.putIfAbsent(h.book.key, () => h);
      }
      setState(() => _historyByKey = byKey);
    } catch (e) {
      // 历史读取失败不阻塞书架：卡面无续读信息，仍可点进详情。
      ErrorLogger.instance.warn('novel shelf history failed: $e');
    }
  }

  Future<void> _loadSources() async {
    final srcs = await SourceManager.enabledNovelSources();
    if (!mounted) return;
    setState(() {
      _sources = srcs;
      _sourcesLoaded = true;
      _sourceId = srcs.isNotEmpty ? srcs.first.id : null;
      _shelf = NovelShelfStore.listAll();
      // 本地导入书目在启动时读一次缓存，build 不再扫盘（listAll 走目录遍历，
      // 书架稍大或目录在慢速磁盘上时会卡首帧）。
      _localBooks = LocalNovelSource.store.listAll();
    });
    if (_sourceId != null) _loadNovels();
    _loadHistory();
  }

  /// 刷新书架缓存（在线收藏 + 本地导入），供详情页/导入页返回后调用，
  /// 避免用户"加书架"成功后回来看不到、"删除本地书"回来还残留的错觉。
  void _refreshShelf() {
    if (!mounted) return;
    setState(() {
      _shelf = NovelShelfStore.listAll();
      _localBooks = LocalNovelSource.store.listAll();
    });
    _loadHistory();
  }

  /// 主壳 Ctrl+R 刷新入口。
  void refresh() {
    if (_sourceId != null) _loadNovels();
  }

  /// 请求代际：切源/刷新时自增，作废在途旧请求，防止慢响应覆盖新列表/提前清 loading。
  int _loadGen = 0;

  /// 站内搜索关键词（非空 = 搜索模式，显示当前源搜索结果而非榜单）。
  String _keyword = '';
  final TextEditingController _searchCtrl = TextEditingController();

  Future<void> _loadNovels() async {
    if (_sourceId == null) return;
    final src = SourceManager.novelById(_sourceId!);
    if (src == null) return;
    final gen = ++_loadGen;
    if (mounted) setState(() => _loading = true);
    try {
      final kw = _keyword.trim();
      final list = kw.isEmpty
          ? await src.rank(1).timeout(const Duration(seconds: 15))
          : await src.search(kw, 1).timeout(const Duration(seconds: 15));
      if (mounted && gen == _loadGen) {
        _items = list;
        _error = null;
      }
    } catch (e) {
      ErrorLogger.instance.warn('novel home load failed: $e');
      if (mounted && gen == _loadGen) _error = '加载失败，请检查网络';
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: RefreshIndicator(
        // 下拉刷新与漫画/动漫首页对齐；AlwaysScrollable 保证内容不满
        // 一屏时也可下拉触发。
        onRefresh: () async {
          if (_sourceId != null) await _loadNovels();
          _refreshShelf();
        },
        child: CustomScrollView(
          controller: _scrollCtrl,
          physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            pinned: true,
            // 苹果：pinned 顶栏是固定悬浮层，用真毛玻璃（内容从它下方滚过
            // 时被模糊）；极简/小米保持该调用点原纯色底（scheme.surface）。
            backgroundColor: context.uiStyle == UIStyle.apple
                ? Colors.transparent
                : scheme.surface,
            flexibleSpace: FlexibleSpaceBar(
              background: FrostedGlass(
                fallbackColor: scheme.surface,
                child: const SizedBox.expand(),
              ),
            ),
            // 桌面端侧栏已区分漫画/动漫/小说，顶栏不再重复 TypeSegment，
            // 改为显示当前栏目标题（桌面应用标准顶栏）。
            title: DesktopUi.isDesktopPlatform
                ? Text('小说',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface))
                : TypeSegment(type: widget.type, onChanged: widget.onTypeChanged),
            // 大屏（≥840dp）内容已被限宽但 SliverAppBar 仍占满全宽：
            // 小段若靠左会留大片空白，居中与页面其它元素更协调。
            centerTitle: Responsive.isExpanded(context),
            titleSpacing: Responsive.pagePadding(context),
            actions: const [],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pagePadding(context), vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('我的小说书架',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      // await 返回后再刷新：导入完成后 _localBooks 需立刻同步，
                      // 否则用户以为"导入没成功"。
                      await Navigator.push(
                          context, MaterialPageRoute(builder: (_) => const NovelImportPage()));
                      _refreshShelf();
                    },
                    icon: const Icon(Icons.file_open_outlined, size: 17),
                    label: const Text('本地导入'),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.primary,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _shelfGrid(scheme),
          if (!_sourcesLoaded)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            )
          else if (_sources.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: Responsive.pagePadding(context), vertical: 8),
                child: _sourceChips(scheme),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: Responsive.pagePadding(context), vertical: 4),
                child: _searchField(scheme),
              ),
            ),
            _novelGrid(scheme),
          ] else
            SliverToBoxAdapter(
              child: _EmptySource(),
            ),
        ],
      ),
      ),
    );
  }

  Widget _shelfGrid(scheme) {
    // 本地导入的书架（独立于在线收藏 NovelShelfStore）
    final localBooks = _localBooks;
    final hasLocal = localBooks.isNotEmpty;
    final shelfEmpty = _shelf.isEmpty && !hasLocal;
    if (shelfEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pagePadding(context), vertical: 8),
          child: EmptyStateView(
            icon: Icons.menu_book_outlined,
            title: '书架还是空的',
            subtitle: '去添加喜欢的小说，或导入本地 TXT/EPUB 吧～',
            action: OutlinedButton.icon(
              onPressed: () async {
                // 导入完成返回后立刻刷新，避免"导入成功但书架不显示"的错觉。
                await Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const NovelImportPage()));
                _refreshShelf();
              },
              icon: const Icon(Icons.file_open_outlined, size: 18),
              label: const Text('本地导入'),
            ),
          ),
        ),
      );
    }
    // 本地导入书 + 在线收藏合并展示（本地在前）。
    final cards = <Widget>[
      for (final b in localBooks)
        _LocalShelfCard(meta: b, scheme: scheme),
      for (final d in _shelf)
        FadeSlideIn(
          delay: const Duration(milliseconds: 40),
          offset: 16,
          child: _ShelfCard(
            d: d,
            scheme: scheme,
            history: _historyByKey[
                Bookmark(sourceId: d.sourceId ?? '', comicId: d.id, name: '', pic: '').key],
            onReturned: _refreshShelf,
          ),
        ),
    ];
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: Responsive.pagePadding(context)),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: Responsive.novelGridColumns(context),
          mainAxisSpacing: Responsive.gridSpacing(context),
          crossAxisSpacing: Responsive.gridSpacing(context),
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate(
          (ctx, i) => cards[i],
          childCount: cards.length,
        ),
      ),
    );
  }

  Widget _novelGrid(scheme) {
    if (_loading) {
      return const SliverToBoxAdapter(
          child: Center(
              child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(strokeWidth: 2))));
    }
    if (_error != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ErrorStateView(
            message: _error!,
            onRetry: () {
              setState(() => _loading = true);
              _loadNovels();
            },
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      // 搜索模式空态提示关键词，榜单空态保持「暂无内容」。
      final kw = _keyword.trim();
      return SliverToBoxAdapter(
        child: kw.isEmpty
            ? const EmptyStateView(
                icon: Icons.article_outlined,
                title: '暂无内容',
              )
            : EmptyStateView(
                icon: Icons.search_off_rounded,
                title: '没有找到「$kw」',
                subtitle: '换个关键词，或点击下方源标签切换站点搜索',
              ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pagePadding(context), vertical: 8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: Responsive.novelGridColumns(context),
          mainAxisSpacing: Responsive.gridSpacing(context),
          crossAxisSpacing: Responsive.gridSpacing(context),
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate(
          (ctx, i) {
            final it = _items[i];
            return FadeSlideIn(
              delay: Duration(milliseconds: 40 * (i % 12)),
              offset: 16,
              child: _NovelCard(
                item: it,
                scheme: scheme,
                onTap: () async {
                  HapticFeedback.lightImpact();
                  // 详情页可能触发加/移书架；返回后刷新避免"以为加失败"。
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => NovelDetailPage(
                        sourceId: _sourceId!,
                        novelId: it.id,
                        name: it.name,
                        pic: it.pic,
                      ),
                    ),
                  );
                  _refreshShelf();
                },
              ),
            );
          },
          childCount: _items.length,
        ),
      ),
    );
  }

  Widget _sourceChips(scheme) => Wrap(
        spacing: 8,
        children: _sources
            .map((s) => ChoiceChip(
                  label: Text(s.name),
                  selected: s.id == _sourceId,
                  onSelected: (_) {
                    // 切源后清空搜索词回到榜单（搜索词属于具体源）。
                    if (_keyword.isNotEmpty) {
                      _keyword = '';
                      _searchCtrl.clear();
                    }
                    setState(() => _sourceId = s.id);
                    _loadNovels();
                  },
                ))
            .toList(),
      );

  /// 站内小说搜索框：输入回车即搜当前源（与漫画/动漫首页同交互）。
  /// 非空关键词或提交后 = 搜索模式，网格显示当前源搜索结果；清空回榜单。
  Widget _searchField(ColorScheme scheme) {
    return TextField(
      controller: _searchCtrl,
      textInputAction: TextInputAction.search,
      onSubmitted: (v) {
        final kw = v.trim();
        if (kw == _keyword) return;
        _keyword = kw;
        _loadNovels();
      },
      onChanged: (v) {
        // 清空即退出搜索模式回榜单（输入中不实时搜，避免每键打源）。
        if (v.trim().isEmpty && _keyword.isNotEmpty) {
          _keyword = '';
          _loadNovels();
        }
      },
      style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索当前源小说…',
        hintStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurface.withValues(alpha: 0.4),
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 18,
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
        suffixIcon: _searchCtrl.text.isNotEmpty
            ? IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: () {
                  _searchCtrl.clear();
                  _keyword = '';
                  _loadNovels();
                },
              )
            : null,
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// _TypeSegment 已移至 responsive.dart 作为共享组件 TypeSegment

/// 封面卡三风格分支（推荐网格 / 书架 / 本地导入共用）：
/// - 极简：沿用既有圆角 8（回归面为零，逐字节等同现状）；
/// - 小米：[StyleTokens.cardRadius] + 超椭圆剪裁 + 品牌渐变底；
/// - 苹果：[StyleTokens.cardRadius] + [StyleTokens.cardBorder] 细分隔线。
/// 布局/热区/字体不动，只切装饰。
abstract final class _CoverCardStyle {
  /// 极简封面既有圆角（StyleTokens 极简档为 R.card=12，直接套用会改既有观感，
  /// 故极简分支锁定原值以保证回归面为零）。
  static const double radiusMinimalist = 8;

  /// 封面圆角：按风格取档。
  static double cardRadius(BuildContext context) =>
      switch (context.uiStyle) {
        UIStyle.minimalist => radiusMinimalist,
        UIStyle.xiaomi || UIStyle.apple =>
          R.of(R.card, style: context.uiStyle),
      };

  /// 仅苹果风格启用细分隔线。[StyleTokens.cardBorder] 在极简下也返回 hairline，
  /// 直接套用会破坏「极简逐字节等同现状」，故按风格显式开关。
  static BorderSide? boxBorder(BuildContext context) =>
      context.uiStyle == UIStyle.apple ? StyleTokens.cardBorder(context) : null;

  /// 封面卡外壳（图片封面）：三风格分支只改剪裁/底色/描边。
  static Widget imageCover(BuildContext context, String url) {
    final style = context.uiStyle;
    final r = cardRadius(context);
    if (style == UIStyle.xiaomi) {
      // 超椭圆剪裁 + 品牌渐变底；内层图片不再单独裁剪（避免双层软边）。
      return ClipPath(
        clipper: SquircleClipper(radius: r),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: StyleTokens.cardGradient(context),
            borderRadius: BorderRadius.circular(r),
          ),
          child: CachedImage(url, fit: BoxFit.cover),
        ),
      );
    }
    final border = boxBorder(context);
    if (border != null) {
      // 苹果：细描边内衬（inset grouped 观感）。
      return ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(r),
            border: Border.all(color: border.color, width: border.width),
          ),
          child: CachedImage(url, fit: BoxFit.cover),
        ),
      );
    }
    // 极简：与既有 ClipRRect(8) + CachedImage(radius: 8) 逐字节等同。
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: CachedImage(url, fit: BoxFit.cover, radius: r),
    );
  }

  /// 纯色占位封面（本地导入书无封面）：三风格分支只改圆角/底色/描边。
  /// 不加品牌渐变 —— 卡内是主色图标 + 半透明文字，渐变底会直接吃掉对比度。
  static Widget placeholderCover(BuildContext context, {required Widget child}) {
    final style = context.uiStyle;
    final r = cardRadius(context);
    final fill = Theme.of(context).colorScheme.primary.withValues(alpha: 0.1);
    if (style == UIStyle.xiaomi) {
      return ClipPath(
        clipper: SquircleClipper(radius: r),
        child: DecoratedBox(
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(r)),
          child: child,
        ),
      );
    }
    final border = boxBorder(context);
    if (border != null) {
      // 苹果：细描边内衬。
      return ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(r),
            border: Border.all(color: border.color, width: border.width),
          ),
          child: child,
        ),
      );
    }
    // 极简：与既有 Container(color + circular(8)) 逐字节等同。
    return Container(
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(r)),
      child: child,
    );
  }
}

class _NovelCard extends StatelessWidget {
  final ComicItem item;
  final ColorScheme scheme;
  final VoidCallback onTap;
  const _NovelCard({required this.item, required this.scheme, required this.onTap});
  @override
  Widget build(BuildContext context) {
    // HoverEffect 自带 hover 微缩放 + 点击（桌面悬停反馈，移动端无感知）。
    return HoverEffect(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _CoverCardStyle.imageCover(context, item.pic),
          ),
          const SizedBox(height: 6),
          Text(item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
        ],
      ),
    );
  }
}

class _ShelfCard extends StatelessWidget {
  final NovelDetail d;
  final ColorScheme scheme;
  final HistoryEntry? history; // 该书的最近阅读记录（无则卡面不显示续读）
  final VoidCallback? onReturned;
  const _ShelfCard({
    required this.d,
    required this.scheme,
    this.history,
    this.onReturned,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        // 用条目自带的 sourceId 定位源（listAll 返回解包后的纯 id，
        // 从 id 里拆复合 key 会解析成空串导致点不开书架）
        final sourceId = d.sourceId ?? '';
        if (sourceId.isEmpty) return;
        // await 详情页返回后回调：详情页可能触发移书架操作，
        // 首页在此重新拉一次缓存以同步"已移书架"状态。
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NovelDetailPage(
              sourceId: sourceId,
              novelId: d.id,
              name: d.name,
              pic: d.pic ?? '',
            ),
          ),
        );
        onReturned?.call();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _CoverCardStyle.imageCover(context, d.pic ?? ''),
          ),
          const SizedBox(height: 6),
          Text(d.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
          if (history != null) ...[
            const SizedBox(height: 3),
            Text(
              '上次读到：${history!.chapterTitle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.primary.withValues(alpha: 0.85),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptySource extends StatelessWidget {
  const _EmptySource();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: EmptyStateView(
        icon: Icons.menu_book_rounded,
        title: '小说源即将接入',
        subtitle: '具体小说源（笔趣阁类等）随后接入，书架已就绪。',
      ),
    );
  }
}

/// 本地导入书卡片：数据来自 LocalNovelStore（无封面图，用图标占位）。
class _LocalShelfCard extends StatelessWidget {
  final Map<String, dynamic> meta;
  final ColorScheme scheme;
  const _LocalShelfCard({required this.meta, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final name = (meta['name'] as String?) ?? '';
    final chapters = (meta['chapters'] as List? ?? []).length;
    return HoverEffect(
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NovelDetailPageLocal(bookId: meta['id'] as String),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _CoverCardStyle.placeholderCover(
              context,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.menu_book_rounded,
                        size: 36, color: scheme.primary),
                    const SizedBox(height: 6),
                    Text('$chapters 章',
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurface.withValues(alpha: 0.5))),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
        ],
      ),
    );
  }
}
