import 'package:flutter/material.dart';

import '../../sources/comic_source.dart';
import '../tokens.dart';

/// 通用章节目录底部弹窗（P1-3：detail_allChapters / reader_chapterList /
/// novel_reader_toc 三处弹窗合一；novel_detail 内嵌列表共用过滤纯函数）。
///
/// 参数化覆盖三处差异：
/// - 数据：detail/reader 同步传 [chapters]；novel 目录走 [load] 异步拉取；
/// - 外观：reader 沉浸暗色 [dark]（固定深底圆角卡片+白字），detail/novel 亮色跟随主题；
/// - 头部：detail 倒序切换 / novel 关闭按钮 / reader 拖拽把手（[showHandle]）+ 行序号（[showNumberPrefix]）；
/// - 导航：novel 打开后定位当前章（[scrollToCurrent]）。
/// 行点击 [onTap] 携带条目本身（过滤/倒序后无需调用方还原下标）。
class ChapterListSheet<E> extends StatefulWidget {
  /// 同步章节数据源（detail/reader；与 [load] 二选一）。
  final List<E>? chapters;

  /// 异步加载章节数据（novel 目录；与 [chapters] 二选一）。失败显示重试。
  final Future<List<E>> Function()? load;

  /// 行标题（[index] 为原始顺序下标；空标题占位等规则由调用方实现）。
  final String Function(E chapter, {required int index}) titleOf;

  /// 条目 id（当前章高亮 / 已读 / 已缓存 / 已下载角标的键）。
  final String Function(E chapter) idOf;

  /// 当前章 id（高亮；null = 不高亮）。
  final String? currentId;

  /// 已读章节 id 集合（行首标 ✓）。
  final Set<String> readIds;

  /// 已缓存章节 id 集合（行首标缓存图标）。
  final Set<String> cachedIds;

  /// 已下载章节 id 集合（行尾 offline 角标；静态传入）。
  final Set<String> downloadedIds;

  /// 懒加载已下载章节 id（reader：打开时读一次本地下载记录；
  /// 与 [downloadedIds] 并集生效；失败静默降级为仅静态集）。
  final Future<Set<String>> Function()? loadDownloaded;

  /// 行点击（携带条目本身）。
  final ValueChanged<E> onTap;

  /// 标题文案。
  final String title;

  /// 是否显示倒序切换（detail）。
  final bool sortable;

  /// 是否显示搜索框。
  final bool searchable;

  /// 阅读器沉浸暗色：固定深底圆角卡片 + 白字（reader）。
  final bool dark;

  /// 行首显示原始序号（reader）。
  final bool showNumberPrefix;

  /// 打开后自动定位当前章到可视区（novel）。
  final bool scrollToCurrent;

  /// 头部拖拽把手（reader）。
  final bool showHandle;

  /// 关闭按钮（null = 不显示；优先于 [sortable] 切换）。
  final VoidCallback? onClose;

  const ChapterListSheet({
    super.key,
    this.chapters,
    this.load,
    required this.titleOf,
    required this.idOf,
    this.currentId,
    this.readIds = const {},
    this.cachedIds = const {},
    this.downloadedIds = const {},
    this.loadDownloaded,
    required this.onTap,
    required this.title,
    this.sortable = true,
    this.searchable = true,
    this.dark = false,
    this.showNumberPrefix = false,
    this.scrollToCurrent = false,
    this.showHandle = false,
    this.onClose,
  }) : assert(chapters != null || load != null, 'chapters 与 load 必须提供其一');

  @override
  State<ChapterListSheet<E>> createState() => _ChapterListSheetState<E>();
}

class _ChapterListSheetState<E> extends State<ChapterListSheet<E>> {
  final _filterCtrl = TextEditingController();
  final _ctrl = ScrollController();
  String _filter = '';
  bool _descending = false;

  /// 当前数据（同步传入或异步加载后）；null = 加载中。
  List<E>? _items;

  bool _failed = false;

  /// 懒加载的已下载章节 id（reader 专用）。
  Set<String> _downloaded = const {};

  @override
  void initState() {
    super.initState();
    _items = widget.chapters;
    if (widget.chapters == null) _fetch();
    if (widget.loadDownloaded != null) _loadDownloaded();
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadDownloaded() async {
    try {
      final ids = await widget.loadDownloaded!();
      if (!mounted) return;
      setState(() => _downloaded = ids);
    } catch (_) {
      // 本地读取失败不阻塞目录（下载标记是附加信息）。
    }
  }

  Future<void> _fetch() async {
    setState(() {
      _items = null;
      _failed = false;
    });
    try {
      final data = await widget.load!();
      if (!mounted) return;
      setState(() => _items = data);
      if (widget.scrollToCurrent) _scrollToCurrent();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 过滤 + 倒序后的可见条目（携带原始下标；空过滤 = 全量原序）。
  List<(E, int)> get _visible {
    final all = _items;
    if (all == null) return const [];
    var pairs = [for (var i = 0; i < all.length; i++) (all[i], i)];
    if (_descending) pairs = pairs.reversed.toList(growable: false);
    final f = _filter.trim().toLowerCase();
    if (f.isEmpty) return pairs;
    return [
      for (final (item, i) in pairs)
        if (widget.titleOf(item, index: i).toLowerCase().contains(f))
          (item, i),
    ];
  }

  /// 目录加载后定位到当前章：长篇（几十上百章）打开目录时当前章可能
  /// 在屏幕外，高亮章需要自动滚进可视区。post-frame 等 ListView 挂载。
  void _scrollToCurrent() {
    final all = _items;
    final cur = widget.currentId;
    if (all == null || all.isEmpty || cur == null) return;
    final idx = all.indexWhere((c) => widget.idOf(c) == cur);
    if (idx < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      // 定位到可视区中间偏上，四周留上下文（当前章上下各约 2 屏）。
      final target = tocTargetOffset(
        idx,
        MediaQuery.of(context).size.height,
        _ctrl.position.maxScrollExtent,
      );
      _ctrl.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = widget.dark;
    final onSurface = dark ? Colors.white : scheme.onSurface;
    final muted =
        dark
            ? Colors.white.withValues(alpha: 0.5)
            : scheme.onSurface.withValues(alpha: 0.5);
    final mutedDim =
        dark
            ? Colors.white.withValues(alpha: 0.3)
            : scheme.onSurface.withValues(alpha: 0.3);

    final content = SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.65,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showHandle) ...[
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: onSurface,
                      ),
                    ),
                  ),
                  if (widget.cachedIds.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '已缓存 ${widget.cachedIds.length} 话',
                        style: TextStyle(fontSize: 11, color: scheme.primary),
                      ),
                    ),
                  if (widget.readIds.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '已读 ${widget.readIds.length} 话',
                        style: TextStyle(fontSize: 11, color: muted),
                      ),
                    ),
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: '关闭',
                      icon: Icon(Icons.close_rounded, size: 20, color: onSurface),
                      onPressed: widget.onClose,
                    )
                  else if (widget.sortable)
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _descending = !_descending),
                      icon: Icon(
                        _descending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 16,
                      ),
                      label: Text(_descending ? '倒序' : '正序'),
                    ),
                ],
              ),
            ),
            if (widget.searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: TextField(
                  controller: _filterCtrl,
                  onChanged: (v) => setState(() => _filter = v),
                  style: TextStyle(fontSize: 13.5, color: onSurface),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索章节标题',
                    hintStyle: TextStyle(fontSize: 13, color: mutedDim),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: muted,
                    ),
                    suffixIcon: _filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除',
                            icon: Icon(Icons.close_rounded, size: 16),
                            onPressed: () {
                              _filterCtrl.clear();
                              setState(() => _filter = '');
                            },
                          ),
                    filled: true,
                    fillColor: dark
                        ? Colors.white.withValues(alpha: 0.08)
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(R.control),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            if (widget.searchable)
              Divider(
                height: 0.5,
                indent: 36,
                endIndent: 36,
                color: dark ? null : scheme.outlineVariant,
              ),
            Expanded(child: _buildList(context, scheme, muted, mutedDim)),
          ],
        ),
      ),
    );

    if (!dark) return content;
    // 阅读器沉浸暗色：固定深底圆角卡片（与设置弹窗一致）。
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1B1F),
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
      child: content,
    );
  }

  Widget _buildList(
    BuildContext context,
    ColorScheme scheme,
    Color muted,
    Color mutedDim,
  ) {
    final dark = widget.dark;
    final onSurface = dark ? Colors.white : scheme.onSurface;
    final primary = scheme.primary;
    final items = _items;
    if (widget.load != null && items == null) {
      if (_failed) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 38,
                color: mutedDim,
              ),
              const SizedBox(height: 10),
              Text(
                '目录加载失败，请重试',
                style: TextStyle(fontSize: 13, color: muted),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重试'),
              ),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 36, color: mutedDim),
            const SizedBox(height: 8),
            Text(
              _filter.trim().isEmpty ? '暂无章节' : '没有匹配「$_filter」的章节',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ],
        ),
      );
    }
    final downloadedAll =
        widget.loadDownloaded == null
            ? widget.downloadedIds
            : {...widget.downloadedIds, ..._downloaded};
    final showNumber = widget.showNumberPrefix;
    return ListView.builder(
      controller: _ctrl,
      itemCount: visible.length,
      itemBuilder: (_, v) {
        final (item, i) = visible[v];
        final id = widget.idOf(item);
        final active = widget.currentId != null && widget.currentId == id;
        final read = widget.readIds.contains(id);
        final cached = widget.cachedIds.contains(id);
        final downloaded = downloadedAll.contains(id);
        return ListTile(
          dense: true,
          selected: active,
          // 暗色下当前章用主色填充（与亮色主题下文字高亮对称）。
          tileColor: active && dark ? primary : null,
          onTap: () => widget.onTap(item),
          leading: showNumber
              ? Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? Colors.white
                        : onSurface.withValues(alpha: 0.45),
                  ),
                )
              : null,
          title: Row(
            children: [
              if (read)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 14,
                    color: primary.withValues(alpha: 0.7),
                  ),
                ),
              if (cached)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.download_done_rounded,
                    size: 14,
                    color: primary,
                  ),
                ),
              Flexible(
                child: Text(
                  widget.titleOf(item, index: i),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: active
                        ? (dark ? Colors.white : primary)
                        : onSurface,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          trailing: active
              ? Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: dark ? Colors.white : primary,
                )
              : downloaded
                  ? Icon(
                      Icons.offline_pin_rounded,
                      size: 15,
                      color: Colors.greenAccent.withValues(alpha: 0.8),
                    )
                  : Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: mutedDim,
                    ),
        );
      },
    );
  }
}

/// 目录滚动定位：当前章滚到可视区中间偏上（dense ListTile 约 56px 高）。
/// 顶部章节不越界（clamp 0），末尾 clamp 到 maxScrollExtent。
double tocTargetOffset(int idx, double viewport, double maxExtent) {
  final target = idx * 56 - viewport * 0.4;
  return target.clamp(0.0, maxExtent);
}
/// 章节显示标题：空标题用「第N话」占位（下标按原始顺序）。
///
/// P1-22：detail 页旧 [titleOfChapter]（内部 indexOf）与 reader 页
/// [chapterFilterTitle]（显式传下标）同义，统一为显式下标版（O(1)，
/// 且过滤/倒序后无需还原原始下标）。
String chapterFilterTitle(
  List<Chapter> chapters,
  Chapter c,
  int index,
) =>
    c.title.isEmpty ? '第${index + 1}话' : c.title;
