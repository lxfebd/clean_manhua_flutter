import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'novel_detail_page.dart';
import 'responsive.dart';

import '../models/comic_item.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../net/novel_shelf_store.dart';
import '../ui/widgets/cached_image.dart';
import '../ui/widgets/motion.dart';

/// 小说首页：与漫画/动漫并列的第三种内容模式（首页模式切换的 type==2）。
class NovelHomePage extends StatefulWidget {
  final int type;
  final ValueChanged<int>? onTypeChanged;
  const NovelHomePage({super.key, this.type = 2, this.onTypeChanged});

  @override
  State<NovelHomePage> createState() => _NovelHomePageState();
}

class _NovelHomePageState extends State<NovelHomePage> {
  List<NovelSource> _sources = [];
  String? _sourceId;
  final _scrollCtrl = ScrollController();
  bool _loading = false;
  String? _error;
  List<ComicItem> _items = [];
  List<NovelDetail> _shelf = [];

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    final srcs = await SourceManager.enabledNovelSources();
    if (!mounted) return;
    setState(() {
      _sources = srcs;
      _sourceId = srcs.isNotEmpty ? srcs.first.id : null;
      _shelf = NovelShelfStore.listAll();
    });
    if (_sourceId != null) _loadNovels();
  }

  Future<void> _loadNovels() async {
    if (_sourceId == null) return;
    final src = SourceManager.novelById(_sourceId!);
    if (src == null) return;
    if (mounted) setState(() => _loading = true);
    try {
      final list = await src.rank(1).timeout(const Duration(seconds: 15));
      if (mounted) {
        _items = list;
        _error = null;
      }
    } catch (e) {
      if (mounted) _error = '加载失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        controller: _scrollCtrl,
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: scheme.surface,
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
              child: Text('我的小说书架',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
            ),
          ),
          _shelfGrid(scheme),
          if (_sources.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: Responsive.pagePadding(context), vertical: 8),
                child: _sourceChips(scheme),
              ),
            ),
            _novelGrid(scheme),
          ] else
            SliverToBoxAdapter(
              child: _EmptySource(),
            ),
        ],
      ),
    );
  }

  Widget _shelfGrid(scheme) {
    if (_shelf.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pagePadding(context), vertical: 8),
          child: const EmptyStateView(
            icon: Icons.menu_book_outlined,
            title: '书架还是空的',
            subtitle: '去添加喜欢的小说吧～',
          ),
        ),
      );
    }
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
          (ctx, i) {
            final d = _shelf[i];
            return FadeSlideIn(
              delay: Duration(milliseconds: 40 * (i % 12)),
              offset: 16,
              child: _ShelfCard(d: d, scheme: scheme),
            );
          },
          childCount: _shelf.length,
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
      return const SliverToBoxAdapter(
          child: EmptyStateView(
            icon: Icons.article_outlined,
            title: '暂无内容',
          ));
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
                onTap: () {
                  HapticFeedback.lightImpact();
                  Navigator.push(
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
                    setState(() => _sourceId = s.id);
                    _loadNovels();
                  },
                ))
            .toList(),
      );
}

// _TypeSegment 已移至 responsive.dart 作为共享组件 TypeSegment

class _NovelCard extends StatelessWidget {
  final ComicItem item;
  final ColorScheme scheme;
  final VoidCallback onTap;
  const _NovelCard({required this.item, required this.scheme, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedImage(item.pic, fit: BoxFit.cover, radius: 8),
            ),
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
  const _ShelfCard({required this.d, required this.scheme});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final sourceId = d.id.contains('|') ? d.id.split('|').first : '';
        if (sourceId.isEmpty) return;
        Navigator.push(
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
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedImage(d.pic ?? '', fit: BoxFit.cover, radius: 8),
            ),
          ),
          const SizedBox(height: 6),
          Text(d.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
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
