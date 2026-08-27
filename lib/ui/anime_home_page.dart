import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import '../sources/video_source.dart';
import 'anime_player_page.dart';
import 'responsive.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

/// 动漫首页：搜索 + 分类胶囊 + 番剧网格。
class AnimeHomePage extends StatefulWidget {
  /// 0=漫画 1=动漫（由外层 MangaAnimeTabs 驱动）
  final int type;
  final ValueChanged<int>? onTypeChanged;
  const AnimeHomePage({super.key, this.type = 1, this.onTypeChanged});

  @override
  State<AnimeHomePage> createState() => _AnimeHomePageState();
}

class _AnimeHomePageState extends State<AnimeHomePage> {
  final _items = <ComicItem>[];
  int _page = 1;
  bool _loading = false;
  bool _noMore = false;
  String _mode = 'rank';
  String _categoryId = '';
  String _keyword = '';
  String? _error;
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  late VideoSource _source;
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
    _source = SourceManager.videoSources.first;
    _scrollCtrl.addListener(_onScroll);
    _loadSourceCats();
    _refresh();
  }

  /// 弹出视频源选择底部弹窗。
  void _pickSource() {
    showModalBottomSheet(
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
            for (final s in SourceManager.videoSources)
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
      debugPrint('loadSourceCats failed: $e');
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

  void _refresh() {
    _page = 1;
    _items.clear();
    _error = null;
    _noMore = false;
    setState(() {});
    _loadMore();
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
    final source = _source;
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
      if (mounted) {
        setState(() {
          if (r.isEmpty) {
            _noMore = true;
          } else {
            _items.addAll(r);
            _page++;
          }
        });
        _maybeAutoLoadMore();
      }
    } catch (e) {
      if (mounted && _items.isEmpty) {
        setState(() => _error = '加载失败：$e');
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

  /// 内容不满一屏时自动续页，避免首屏太短时滚动分页不触发导致"很快到底"的错觉。
  void _maybeAutoLoadMore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _noMore) return;
      if (_scrollCtrl.hasClients &&
          _scrollCtrl.position.maxScrollExtent <= 0) {
        _loadMore();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(children: [
        _buildHeader(theme),
        _buildChips(theme),
        Expanded(child: _buildContent()),
      ]),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _refresh);
    }
    if (_items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return CustomScrollView(
      controller: _scrollCtrl,
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _modeTitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                if (_items.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${_items.length} 部',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ],
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
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: Responsive.isTablet(context) ? 200 : 150,
              mainAxisSpacing: Responsive.gridSpacing(context),
              crossAxisSpacing: Responsive.gridSpacing(context),
              childAspectRatio: 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (c, i) => FadeSlideIn(
                delay: Duration(milliseconds: 50 * (i % 12)),
                offset: 16,
                child: _AnimeCard(
                  item: _items[i],
                  onTap: () => _openDetail(_items[i]),
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
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
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

  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 56, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
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
                Flexible(
                  child: Column(
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
                      GestureDetector(
                        onTap: _pickSource,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                _source.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurface.withValues(alpha: 0.5),
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(Icons.swap_horiz_rounded,
                                size: 13,
                                color: scheme.onSurface.withValues(alpha: 0.4)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _pickSource,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: scheme.onSurface.withValues(alpha: 0.15),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.public_rounded,
                            size: 14,
                            color: scheme.onSurface.withValues(alpha: 0.8)),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            _source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(Icons.unfold_more_rounded,
                            size: 14,
                            color: scheme.onSurface.withValues(alpha: 0.6)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 搜索栏 + 漫画/动漫切换（同一行）
            Row(
              children: [
                Expanded(
                  child: _animeSearch(theme),
                ),
                const SizedBox(width: 10),
                _typeSegment(
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

  Widget _animeSearch(ThemeData theme) {
    final scheme = theme.colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
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
            color: scheme.onSurface.withValues(alpha: 0.4),
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 19,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: InputBorder.none,
        ),
      ),
    );
  }

  /// 漫画 / 动漫 分段切换（黑底胶囊）。
  Widget _typeSegment({
    required int type,
    ValueChanged<int>? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Widget seg(String label, int v) {
      final active = type == v;
      return GestureDetector(
        onTap: onChanged == null ? null : () => onChanged(v),
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

    return Container(
      height: 40,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.onSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('漫画', 0), seg('动漫', 1), seg('小说', 2)],
      ),
    );
  }

  Widget _buildChips(ThemeData theme) {
    final primary = theme.colorScheme.secondary;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          for (final c in _sourceCats)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: PressableScale(
                onTap: () => _switchMode('category', categoryId: c.id),
                scale: 0.94,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: _categoryId == c.id && _mode == 'category'
                        ? primary
                        : theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _categoryId == c.id && _mode == 'category'
                          ? primary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.06),
                    ),
                    boxShadow: _categoryId == c.id && _mode == 'category'
                        ? [
                            BoxShadow(
                              color: primary.withValues(alpha: 0.35),
                              blurRadius: 12,
                              spreadRadius: -2,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
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

  void _openDetail(ComicItem it) async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
    }
  }
}

class _AnimeCard extends StatefulWidget {
  final ComicItem item;
  final VoidCallback onTap;
  const _AnimeCard({required this.item, required this.onTap});

  @override
  State<_AnimeCard> createState() => _AnimeCardState();
}

class _AnimeCardState extends State<_AnimeCard> {
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
            borderRadius: BorderRadius.circular(16),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: scheme.secondary.withValues(alpha: 0.22),
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
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: scheme.surface,
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
                                  fit: BoxFit.cover, radius: 0),
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
                            width: _hover ? 48 : 0,
                            height: _hover ? 48 : 0,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.secondary.withValues(alpha: 0.9),
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 30,
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

/// 无封面条目的首字占位封面：按标题哈希取主题色，居中显示首个字符，
/// 避免纯文本源（如 Anime1）全部卡片挤成同一张空占位图。
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
