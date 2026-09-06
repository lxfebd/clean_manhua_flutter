import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'detail_page.dart';
import 'reader_page.dart';
import 'responsive.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

/// 跨源统一搜索：输入关键词，并发搜索所有启用的漫画源，结果按源分组展示。
class UnifiedSearchPage extends StatefulWidget {
  final String keyword;
  const UnifiedSearchPage({super.key, required this.keyword});

  @override
  State<UnifiedSearchPage> createState() => _UnifiedSearchPageState();
}

class _UnifiedSearchPageState extends State<UnifiedSearchPage> {
  List<_SourceResult> _results = [];
  bool _loading = true;
  bool _loadingMore = false; // 正在加载下一页
  bool _hasMore = false; // 任一源还有下一页
  final _searchCtrl = TextEditingController();

  // 双栏预览（≥840dp）：右侧面板当前选中的结果与其详情。
  ComicItem? _selected;
  ComicSource? _selectedSource;
  ComicDetail? _selectedDetail;
  bool _detailLoading = false;
  String _fetchKey = ''; // 防竞态：只采纳最后一次请求的返回
  Timer? _selectDebounce;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.keyword;
    _search();
  }

  @override
  void dispose() {
    _selectDebounce?.cancel();
    _listCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final kw = _searchCtrl.text.trim();
    if (kw.isEmpty) return;
    setState(() => _loading = true);
    try {
      final enabled = await SourceManager.enabledSources();
      final futures = <Future<List<ComicItem>>>[];
      for (final s in enabled) {
        futures.add(s.search(kw, 1).timeout(const Duration(seconds: 15)));
      }
      final all = await Future.wait(futures, eagerError: false);
      if (!mounted) return;
      final list = <_SourceResult>[];
      var anyMore = false;
      for (var i = 0; i < enabled.length; i++) {
        final items = all[i];
        if (items.isNotEmpty) {
          list.add(_SourceResult(source: enabled[i], items: items, page: 1));
          // 一页就能拉满的源（数量少于页容量）视为没有更多
          anyMore = anyMore || items.length >= _pageSize;
        }
      }
      _fetchKey = ''; // 新搜索作废旧预览请求
      setState(() {
        _results = list;
        _loading = false;
        _loadingMore = false;
        _hasMore = anyMore;
        _selected = null;
        _selectedSource = null;
        _selectedDetail = null;
        _detailLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 搜索单页结果的大致容量（各源实际页容量可能不同，仅用于判断"还有没有更多"）。
  static const int _pageSize = 20;

  /// 滚动到底加载下一页：所有源并发拉取下一页，按 id 去重追加。
  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final kw = _searchCtrl.text.trim();
    if (kw.isEmpty || _results.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final futures = <Future<List<ComicItem>>>[];
      for (final r in _results) {
        futures.add(r.source
            .search(kw, r.page + 1)
            .timeout(const Duration(seconds: 15)));
      }
      final all = await Future.wait(futures, eagerError: false);
      if (!mounted) return;
      var anyMore = false;
      final updated = <_SourceResult>[];
      for (var i = 0; i < _results.length; i++) {
        final r = _results[i];
        final newItems = all[i];
        if (newItems.isEmpty) {
          updated.add(r); // 该源没有更多了，保持现状
          continue;
        }
        // 按 id 去重（跨页重复条目只保留第一页的）
        final seen = <String>{for (final it in r.items) it.id};
        final merged = [...r.items];
        for (final it in newItems) {
          if (seen.add(it.id)) merged.add(it);
        }
        anyMore = anyMore || newItems.length >= _pageSize;
        updated.add(_SourceResult(
            source: r.source, items: merged, page: r.page + 1));
      }
      setState(() {
        _results = updated;
        _loadingMore = false;
        _hasMore = anyMore;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 选中一个结果：清除旧详情，异步拉取详情填充右侧预览面板。
  void _select(ComicSource src, ComicItem item) {
    if (_selected?.id == item.id && _selectedSource?.id == src.id) return;
    final key = '${src.id}::${item.id}';
    _fetchKey = key;
    setState(() {
      _selected = item;
      _selectedSource = src;
      _selectedDetail = null;
      _detailLoading = true;
    });
    _loadDetail(src, item.id, key);
  }

  Future<void> _loadDetail(ComicSource src, String id, String key) async {
    try {
      final d = await src.detail(id);
      if (!mounted || _fetchKey != key) return;
      setState(() {
        _selectedDetail = d;
        _detailLoading = false;
      });
    } catch (_) {
      if (!mounted || _fetchKey != key) return;
      setState(() => _detailLoading = false);
    }
  }

  /// 桌面悬停选中：250ms 防抖，避免鼠标扫过卡片时连发详情请求。
  void _scheduleSelect(ComicSource src, ComicItem item) {
    _selectDebounce?.cancel();
    _selectDebounce = Timer(
        const Duration(milliseconds: 250), () => _select(src, item));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        // 整页限宽居中（M3 LS-U2）：搜索行与结果列表在桌面大屏不拉满全宽。
        // SizedBox.expand + Align 保证高度有界（Expanded 安全），宽度收口到 1100dp。
        // 1100 容纳双栏：左结果 ~640 + 分隔 + 右预览 ~380。
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        Responsive.pagePadding(context), 10,
                        Responsive.pagePadding(context), 8),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.maybePop(context),
                          icon: Icon(
                              DesktopUi.isDesktopPlatform
                                  ? Icons.arrow_back_rounded
                                  : Icons.arrow_back_ios_new_rounded,
                              size: 18, color: scheme.onSurface),
                        ),
                        const SizedBox(width: 4),
                        // Flexible（loose）而非 Expanded（tight）：tight 约束会吞掉
                        // ConstrainedBox(maxWidth)，导致大屏搜索框仍被拉满全宽。
                        Flexible(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                                maxWidth: Responsive.fieldMaxWidth(context)),
                            child: SizedBox(
                              height: 40,
                              child: TextField(
                                controller: _searchCtrl,
                                textInputAction: TextInputAction.search,
                                onSubmitted: (_) => _search(),
                                style: TextStyle(
                                    fontSize: 14, color: scheme.onSurface),
                                decoration: InputDecoration(
                                  hintText: '搜索所有源…',
                                  hintStyle: TextStyle(
                                      fontSize: 13.5,
                                      color: scheme.onSurface
                                          .withValues(alpha: 0.4)),
                                  prefixIcon: Icon(Icons.search_rounded,
                                      size: 20,
                                      color: scheme.primary),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 10),
                                  border: InputBorder.none,
                                  filled: true,
                                  fillColor: scheme.surface,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _search,
                          child: const Text('搜索'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: _buildBody(scheme)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.08),
              ),
              child: Icon(Icons.search_off_rounded,
                  size: 40, color: scheme.primary),
            ),
            const SizedBox(height: 12),
            Text('没有找到相关结果',
                style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurface.withValues(alpha: 0.6))),
          ],
        ),
      );
    }
    // 双栏（≥840dp）：左侧结果列表 + 右侧详情预览面板。
    if (Responsive.isExpanded(context)) {
      final w = MediaQuery.sizeOf(context).width;
      // 窄平板（840-1000dp）右栏收窄到 320，避免左栏被挤到 500dp 以下；
      // 更宽时保持 380 的舒适预览宽度。
      final panelW = w < 1000 ? 320.0 : 380.0;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _buildResultList(scheme, compactCards: false),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          SizedBox(
            width: panelW,
            child: _buildPreviewPanel(scheme),
          ),
        ],
      );
    }
    return _buildResultList(scheme, compactCards: true);
  }

  Widget _buildResultList(ColorScheme scheme, {required bool compactCards}) {
    return ListView.builder(
      controller: _listCtrl,
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 4,
          Responsive.pagePadding(context),
          (Responsive.isTablet(context) ? 24 : 110)),
      itemCount: _results.length + 1,
      itemBuilder: (_, i) {
        if (i == _results.length) return _buildListFooter();
        return _SourceResultGroup(
          result: _results[i],
          selected: _selected,
          selectedSourceId: _selectedSource?.id,
          compact: compactCards,
          // 双栏模式：点卡片 = 选中并在右侧预览（master-detail）；
          // 单栏模式：点卡片 = 直接进详情页。
          onTap: (item) => compactCards
              ? _openDetail(_results[i].source, item)
              : _select(_results[i].source, item),
          onHover: (item) => _scheduleSelect(_results[i].source, item),
        );
      },
    );
  }

  final ScrollController _listCtrl = ScrollController();

  /// 列表尾部：滚动触发加载下一页；无更多时显示到底提示。
  Widget _buildListFooter() {
    final scheme = Theme.of(context).colorScheme;
    // 滚动触底即加载下一页（滚近底部时提前触发，避免等到底部才闪现加载态）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_loadingMore && _hasMore &&
          _listCtrl.hasClients &&
          _listCtrl.position.extentAfter < 400) {
        _loadMore();
      }
    });
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: scheme.primary),
          ),
        ),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text('已经到底啦',
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.35))),
        ),
      );
    }
    return const SizedBox(height: 40); // 触底占位，等待滚动触发
  }

  /// 右侧详情预览面板：封面 + 信息 + 章节入口。
  Widget _buildPreviewPanel(ColorScheme scheme) {
    final sel = _selected;
    if (sel == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.touch_app_rounded,
                  size: 40, color: scheme.onSurface.withValues(alpha: 0.25)),
              const SizedBox(height: 12),
              Text('从左侧选择一部作品查看详情',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.45))),
            ],
          ),
        ),
      );
    }
    final d = _selectedDetail;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        const SizedBox(height: 8),
        // 封面
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 132,
              height: 188,
              child: CachedImage(sel.pic, fit: BoxFit.cover, radius: 0),
            ),
          ),
        ),
        const SizedBox(height: 14),
        // 书名
        Text(
          sel.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w700, color: scheme.onSurface),
        ),
        if (d != null && d.author != null && d.author!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '作者：${d.author}',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5, color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
        if (d != null && (d.type?.isNotEmpty ?? false)) ...[
          const SizedBox(height: 2),
          Text(
            d.type!,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.45)),
          ),
        ],
        const SizedBox(height: 16),
        // 按钮
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _openDetail(_selectedSource!, sel),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('打开详情'),
              ),
            ),
            const SizedBox(width: 8),
            if (d != null && d.chapters.isNotEmpty)
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _openReader(d),
                  icon: const Icon(Icons.auto_stories_rounded, size: 16),
                  label: const Text('开始阅读'),
                ),
              ),
          ],
        ),
        if (_detailLoading)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
                child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (d == null)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Text('详情加载失败，请点击「打开详情」重试',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurface.withValues(alpha: 0.4))),
          )
        else if (d.description != null && d.description!.isNotEmpty) ...[
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              d.description!,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: scheme.onSurface.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ],
    );
  }

  /// 从预览面板直接进入阅读器（跳第一章）。
  void _openReader(ComicDetail d) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          sourceId: _selectedSource!.id,
          comicId: d.id,
          chapterId: d.chapters.first.id,
          title: d.chapters.first.title,
          comicName: d.name,
          comicPic: d.pic ?? '',
          comicAuthor: d.author ?? '',
          chapters: d.chapters,
        ),
      ),
    );
  }

  void _openDetail(ComicSource source, ComicItem item) {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: source.id,
          comicId: item.id,
          name: item.name,
          pic: item.pic,
        ),
      ),
    );
  }
}

class _SourceResult {
  final ComicSource source;
  final List<ComicItem> items;
  final int page; // 已加载到的页码（从 1 开始）
  const _SourceResult(
      {required this.source, required this.items, this.page = 1});
}

class _SourceResultGroup extends StatelessWidget {
  final _SourceResult result;
  final ValueChanged<ComicItem> onTap;
  final ValueChanged<ComicItem> onHover;
  final ComicItem? selected;
  final String? selectedSourceId;
  final bool compact;
  const _SourceResultGroup({
    required this.result,
    required this.onTap,
    required this.onHover,
    this.selected,
    this.selectedSourceId,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: SectionHeader(
            icon: Icons.public_rounded,
            title: result.source.name,
            count: result.items.length,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: result.items.map((item) => _UnifiedCard(
            item: item,
            sourceId: result.source.id,
            compact: compact,
            selected: selected?.id == item.id && selectedSourceId == result.source.id,
            onTap: () => onTap(item),
            onHover: () => onHover(item),
          )).toList(),
        ),
      ],
    );
  }
}

class _UnifiedCard extends StatefulWidget {
  final ComicItem item;
  final String sourceId;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final bool compact;
  final bool selected;
  const _UnifiedCard({
    required this.item,
    required this.sourceId,
    required this.onTap,
    required this.onHover,
    this.compact = false,
    this.selected = false,
  });

  @override
  State<_UnifiedCard> createState() => _UnifiedCardState();
}

class _UnifiedCardState extends State<_UnifiedCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.compact ? 104.0 : 112.0;
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hover = true);
        if (!widget.compact) widget.onHover();
      },
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
          width: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            // Minimalist：卡片无投影，悬停仅微位移反馈。
            boxShadow: const [],
            // 双栏模式：选中项用主题色描边标明当前预览对象。
            border: widget.selected
                ? Border.all(color: scheme.primary, width: 2)
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: scheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: size,
                    height: size * 1.42,
                    child: CachedImage(
                      widget.item.pic,
                      fit: BoxFit.cover,
                      radius: 0,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
                    child: Text(
                      widget.item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                        height: 1.3,
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