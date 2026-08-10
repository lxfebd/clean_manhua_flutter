import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'novel_detail_page.dart';

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
            title: _TypeSegment(type: widget.type, onChanged: widget.onTypeChanged),
            titleSpacing: 16,
            actions: const [],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: _sourceChips(scheme),
              ),
            ),
            _novelGrid(scheme),
          ] else
            SliverToBoxAdapter(
              child: _EmptySource(scheme),
            ),
        ],
      ),
    );
  }

  Widget _shelfGrid(scheme) {
    if (_shelf.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('书架还是空的，去添加喜欢的小说吧～',
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.55))),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 112,
          mainAxisSpacing: 14,
          crossAxisSpacing: 10,
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
          child: Center(
            child: Column(children: [
              Text(_error!,
                  style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.6))),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadNovels, child: const Text('重试')),
            ]),
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const SliverToBoxAdapter(
          child: SizedBox(height: 40, child: Center(child: Text('暂无内容'))));
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 112,
          mainAxisSpacing: 14,
          crossAxisSpacing: 10,
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

class _TypeSegment extends StatelessWidget {
  final int type;
  final ValueChanged<int>? onChanged;
  const _TypeSegment({required this.type, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.onSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(scheme, '漫画', 0),
          _seg(scheme, '动漫', 1),
          _seg(scheme, '小说', 2),
        ],
      ),
    );
  }

  Widget _seg(scheme, String label, int v) {
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
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NovelDetailPage(
            sourceId: d.id.contains('|') ? d.id.split('|').first : '',
            novelId: d.id,
            name: d.name,
            pic: d.pic ?? '',
          ),
        ),
      ),
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
  final ColorScheme scheme;
  const _EmptySource(this.scheme);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(Icons.menu_book_rounded,
              size: 48, color: scheme.onSurface.withValues(alpha: 0.35)),
          const SizedBox(height: 12),
          Text('小说源即将接入',
              style:
                  TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 6),
          Text('具体小说源（笔趣阁类等）随后接入，书架已就绪。',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.55))),
        ],
      ),
    );
  }
}
