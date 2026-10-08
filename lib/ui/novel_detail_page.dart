import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/novel_chapter_cache.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../ui/novel_reader_page.dart';
import '../ui/responsive.dart';
import '../ui/widgets/app_toast.dart';
import '../ui/widgets/cached_image.dart';
import '../ui/widgets/motion.dart';
import 'detail_providers.dart' as detailp;
import 'keyboard_shortcuts.dart';
import 'style_scope.dart';
import 'style_tokens.dart';
import 'tokens.dart';
import 'widgets/squircle.dart';

/// 章节目录过滤纯函数（小说详情页目录搜索框用；独立便于单元测试）。
/// [filter] 按标题模糊匹配（空 = 原列表原样）。
List<NovelChapter> filterNovelChapters(
  List<NovelChapter> chapters,
  String filter,
) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return chapters;
  return [
    for (final c in chapters)
      if (c.title.toLowerCase().contains(f)) c,
  ];
}

/// 小说详情封面三风格分支（手机/平板共用）：
/// - 极简：既有圆角 10 逐字节等同；
/// - 小米：[StyleTokens.cardRadius] + 超椭圆剪裁 + 品牌渐变底衬；
/// - 苹果：[StyleTokens.cardRadius] + 细分割线描边。
/// 布局/热区/字体不动，只切装饰。
class _NovelCover extends StatelessWidget {
  final String url;
  final double width;
  final double height;
  const _NovelCover({
    required this.url,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final style = context.uiStyle;
    final r = switch (style) {
      UIStyle.minimalist => 10.0,
      UIStyle.xiaomi || UIStyle.apple => R.of(R.card, style: context.uiStyle),
    };
    if (style == UIStyle.xiaomi) {
      return SizedBox(
        width: width,
        height: height,
        child: ClipPath(
          clipper: SquircleClipper(radius: r),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: StyleTokens.cardGradient(context),
            ),
            child: SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: CachedImage(url, fit: BoxFit.cover),
            ),
          ),
        ),
      );
    }
    final border = style == UIStyle.apple
        ? StyleTokens.cardBorder(context)
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: border == null
          ? CachedImage(url, width: width, height: height, radius: r)
          : Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(r),
                border: Border.all(color: border.color, width: border.width),
              ),
              child: CachedImage(
                url,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
                radius: r,
              ),
            ),
    );
  }
}

/// 小说详情页：封面/元信息 + 章节目录。章节点击进入阅读器。
class NovelDetailPage extends ConsumerStatefulWidget {
  final String sourceId;
  final String novelId;
  final String? name;
  final String? pic;
  const NovelDetailPage({
    super.key,
    required this.sourceId,
    required this.novelId,
    this.name,
    this.pic,
  });

  /// 解析「继续阅读」目标：历史里该小说最近读到的章节；无则 null（按钮不
  /// 显示）。转发到 detail_providers 层（与漫画 [DetailPage.resolveResumeChapter]
  /// 同模式），纯函数便于单元测试。
  static ({NovelChapter chapter, double offset})? resolveNovelResumeChapter({
    required List<HistoryEntry> history,
    required List<NovelChapter> chapters,
    required String sourceId,
    required String novelId,
  }) => detailp.resolveNovelResumeChapter(
    history: history,
    chapters: chapters,
    sourceId: sourceId,
    novelId: novelId,
  );

  @override
  ConsumerState<NovelDetailPage> createState() => _NovelDetailPageState();
}

/// 「缓存后续」预取章节数：从续读章下一个开始向后预取，覆盖离线追更
/// 常用量。单章 15s 超时、失败跳过，串行不阻塞 UI。
const int prefetchCount = 20;

class _NovelDetailPageState extends ConsumerState<NovelDetailPage> {
  bool _descExpanded = false; // 平板左侧窄面板长简介折叠
  bool _openingChapter = false; // 防连点：进入阅读器期间忽略重复点击
  bool _shelfBusy = false; // 防连点：书架切换期间忽略重复点击

  /// 续读位：详情加载后查历史得到最后阅读章节（无记录为 null）。
  /// 查询在 initState 异步进行，就绪前「继续阅读」按钮不显示。
  ({NovelChapter chapter, double offset})? _resume;

  /// 章节目录滚动控制：手机端整页 CustomScrollView 与平板右栏目录共用，
  /// 「定位续读」按钮按续读章节下标 jumpTo（dense ListTile ≈ 48px 估算）。
  final ScrollController _tocCtrl = ScrollController();

  /// 续读章节 tile 的锚点：定位时从估算跳后精确对齐（惰性列表只 build
  /// 可视区附近，行高估算 + ensureVisible 两段式才可靠）。
  final GlobalKey _resumeTileKey = GlobalKey();

    /// 已离线缓存的章节 id 集合（目录里标小图标）。详情就绪后异步扫描，
  /// 断网时用户能一眼看出哪些章节可直接离线读。
  Set<String> _cachedIds = const {};

  /// 本地图记（已读集 + 历史快照）：历史一次读双视图派生（
  /// [detailMarksProvider]），替代原 _loadReadIds/_loadResume 各自全表读。
  /// build 期 watch：阅读返回失效后角标自动刷新。
  detailp.DetailMarks get _marks {
    final v =
        ref.watch(detailp.detailMarksProvider((widget.sourceId, widget.novelId)));
    return v.when(
      data: (m) => m,
      loading: () => const detailp.DetailMarks(),
      error: (_, __) => const detailp.DetailMarks(),
    );
  }

  /// 已读章节 id 集合（目录里标勾选标记；图记派生，与续读位同一份历史）。
  Set<String> get _readIds => _marks.readChapters;

  /// 「缓存后续」预取状态：null = 空闲，否则正在预取（value = 已完成/总数）。
  /// 预取串行跑，可取消（置 true 后当前章结束后中断）。
  ({int done, int total})? _prefetch;
  bool _prefetchCancel = false;

  /// 章节目录标题搜索关键词（空 = 不过滤）。手机/平板两处目录共用；
  /// 过滤后「定位续读」在下标按原列表计算，被过滤章不可定位。
  String _chapterFilter = '';
  final _chapterFilterCtrl = TextEditingController();

  /// 过滤后的可见章节列表（按标题模糊匹配；空过滤 = 原列表）。
  List<NovelChapter> get _visibleChapters =>
      filterNovelChapters(_detail?.chapters ?? const [], _chapterFilter);

  /// 续读章节是否在当前目录里（历史兜底章节可能已被源下架）。
  bool get _hasResumeInList {
    final r = _resume;
    final d = _detail;
    return r != null && d != null && d.chapters.any((c) => c.id == r.chapter.id);
  }

  /// 预取起点：续读章节的下一个（继续往追更位置之前的不重复拉）。
  NovelChapter? get _prefetchStart {
    final r = _resume;
    final d = _detail;
    if (r == null || d == null) return null;
    final idx = d.chapters.indexWhere((c) => c.id == r.chapter.id);
    if (idx < 0 || idx + 1 >= d.chapters.length) return null;
    return d.chapters[idx + 1];
  }

  /// 串行预取「续读章之后的 [prefetchCount] 章」离线缓存。
  /// 每章 15s 超时、失败跳过继续（源站单章挂了不阻塞整批），可取消。
  Future<void> _prefetchChapters() async {
    final s = SourceManager.novelById(widget.sourceId);
    final d = _detail;
    final start = _prefetchStart;
    if (s == null || d == null || start == null) return;
    final idx0 = d.chapters.indexWhere((c) => c.id == start.id);
    if (idx0 < 0) return;
    final total = (d.chapters.length - idx0).clamp(1, prefetchCount);
    final targets = d.chapters.sublist(idx0, idx0 + total);
    _prefetchCancel = false;
    setState(() => _prefetch = (done: 0, total: total));
    var done = 0;
    var cancelled = false;
    for (final ch in targets) {
      if (_prefetchCancel || !mounted) {
        cancelled = _prefetchCancel;
        break;
      }
      try {
        final c = await s
            .chapterContent(ch.id)
            .timeout(const Duration(seconds: 15));
        if (mounted) {
          await NovelChapterCache.write(
            widget.sourceId,
            widget.novelId,
            ch.id,
            c,
          );
        }
      } catch (e) {
        // 单章失败跳过：断更/被墙章节不阻塞整批预取。
        ErrorLogger.instance.warn(
            '[novel-prefetch] chapter ${ch.id} failed: $e');
      }
      done++;
      if (mounted) setState(() => _prefetch = (done: done, total: total));
    }
    if (!mounted) return;
    setState(() {
      _prefetch = null;
      _prefetchCancel = false;
    });
    _loadCachedIds(); // 刷新目录离线标记
    if (!cancelled && done > 0) {
      AppToast.info(context, '已缓存 $done 章，可离线阅读');
    }
  }

  @override
  void initState() {
    super.initState();
    // 详情异步加载中就绪后查续读位（initState 时 provider 未就绪，直接查
    // 拿不到章节表）。
    ref.listenManual(detailp.novelDetailProvider((widget.sourceId, widget.novelId)),
        (prev, next) {
      if (next.hasValue) _loadResume();
    });
    // 详情就绪前就启动缓存扫描：阅读器返回时缓存可能新增，_openChapter
    // 返回后同样会重扫。
    _loadCachedIds();
    // 已读图记由 [_marks]（build 期 watch）首次读取即加载。
  }

  /// 扫描本小说已缓存章节（供目录离线标记）。失败静默（无标记不阻塞）。
  Future<void> _loadCachedIds() async {
    final ids = await NovelChapterCache.cachedChapterIds(
      widget.sourceId,
      widget.novelId,
    );
    if (mounted) setState(() => _cachedIds = ids);
  }

  @override
  void dispose() {
    _tocCtrl.dispose();
    _chapterFilterCtrl.dispose();
    super.dispose();
  }

  /// 目录「定位续读」：先按行高估算 jumpTo（惰性 SliverList 无法对
  /// 远视口项 ensureVisible），进入 cacheExtent 后 post-frame 用
  /// [Scrollable.ensureVisible] 精确对齐；估算落点仍没找到目标时
  /// （手机端目录前有头图，估算可能偏差超出缓存区）再补跳一屏重试。
  void _jumpToResume() {
    final resume = _resume;
    if (resume == null || !_tocCtrl.hasClients) return;
    final d = _detail;
    if (d == null) return;
    // 过滤态下续读章可能不在可见列表（tile 未 build，精修找不到）：
    // 清除过滤词再定位，让「定位续读」永远有可预期的结果。
    if (_chapterFilter.isNotEmpty) {
      _chapterFilterCtrl.clear();
      setState(() => _chapterFilter = '');
    }
    final idx = d.chapters.indexWhere((c) => c.id == resume.chapter.id);
    if (idx < 0) return;
    final viewport = _tocCtrl.position.viewportDimension;
    final maxExtent = _tocCtrl.position.maxScrollExtent;
    final estimate = (idx * 48.0 - viewport * 0.3).clamp(0.0, maxExtent);
    _tocCtrl.jumpTo(estimate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tocCtrl.hasClients) return;
      if (_refineToResumeTile()) return;
      // 估算偏出缓存区：目标 tile 尚未 build，补跳一屏后再精修一次。
      final max2 = _tocCtrl.position.maxScrollExtent;
      _tocCtrl.jumpTo((_tocCtrl.offset + viewport).clamp(0.0, max2));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refineToResumeTile();
      });
    });
  }

  /// 目标 tile 已 build 则精确滚到可视区上部；返回是否找到。
  bool _refineToResumeTile() {
    final ctx = _resumeTileKey.currentContext;
    if (ctx == null) return false;
    Scrollable.ensureVisible(ctx, duration: Duration.zero, alignment: 0.1);
    return true;
  }

  /// 章节目录搜索框（手机整页目录与平板右栏目录共用）：
  /// 数百章小说按标题关键词即时过滤，跨屏查找章节不用翻到底。
  Widget _chapterSearchField(ColorScheme scheme) {
    return TextField(
      controller: _chapterFilterCtrl,
      onChanged: (v) => setState(() => _chapterFilter = v),
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索章节标题',
        hintStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurface.withValues(alpha: 0.4),
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 18,
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
        suffixIcon: _chapterFilter.isEmpty
            ? null
            : IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: () {
                  _chapterFilterCtrl.clear();
                  setState(() => _chapterFilter = '');
                },
              ),
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(R.control),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// 从历史记录解析续读位（复用纯函数 [resolveNovelResumeChapter]）。
  Future<void> _loadResume() async {
    try {
      final hist = (await ref
              .read(detailp.detailMarksProvider(
                      (widget.sourceId, widget.novelId))
                  .future))
          .history;
      final d = _detail;
      if (d == null) return; // 详情未就绪时历史不落位（等下次进入）
      final r = detailp.resolveNovelResumeChapter(
        history: hist,
        chapters: d.chapters,
        sourceId: widget.sourceId,
        novelId: widget.novelId,
      );
      if (r == null) return;
      if (mounted) setState(() => _resume = r);
    } catch (e) {
      // 历史读取失败不阻塞页面：无续读按钮，用户仍可手动从目录进。
      ErrorLogger.instance.warn('novel resume load failed: $e');
    }
  }

  /// 详情数据（provider 承载加载/超时/错误日志；页面只读展示）。
  NovelDetail? get _detail {
    final v = ref.read(
      detailp.novelDetailProvider((widget.sourceId, widget.novelId)),
    );
    return v.when(data: (d) => d, loading: () => null, error: (_, __) => null);
  }

  /// 加载中：详情 provider 未就绪。
  bool get _loading =>
      ref
          .watch(detailp.novelDetailProvider((widget.sourceId, widget.novelId)))
          .isLoading;

  /// 错误文案：源缺失 → 「未找到小说源」；其余统一网络文案。
  String? get _error {
    final v = ref.watch(detailp.novelDetailProvider((widget.sourceId, widget.novelId)));
    if (v.hasError) {
      if (v.error is detailp.NovelSourceMissing) return '未找到小说源';
      return '加载失败，请检查网络后重试';
    }
    return null;
  }

  /// 是否在书架（本地状态，读取即缓存；增删经 invalidate 刷新）。
  bool get _saved {
    final v = ref.watch(
      detailp.novelInShelfProvider((widget.sourceId, widget.novelId)),
    );
    return v.when(data: (d) => d, loading: () => false, error: (_, __) => false);
  }

  Future<void> _toggleSave() async {
    final s = SourceManager.novelById(widget.sourceId);
    if (s == null || _detail == null || _shelfBusy) return;
    _shelfBusy = true;
    HapticFeedback.lightImpact();
    final wasSaved = _saved;
    try {
      await s.toggleBookshelf(_detail!);
    } catch (e) {
      // 写书架失败不翻转状态（磁盘与 UI 不失步）。
      ErrorLogger.instance.warn('novel toggle bookshelf failed: $e');
      if (mounted) {
        AppToast.error(context, '书架操作失败，请重试');
      }
      _shelfBusy = false;
      return;
    }
    if (!mounted) return;
    // 翻转书架状态：失效 provider 让下次读取重跑 isInBookshelf（异步，
    // UI 随 watch 重建自动反映新值）；toast 用本地捕获的旧值取反。
    ref.invalidate(detailp.novelInShelfProvider((widget.sourceId, widget.novelId)));
    _shelfBusy = false;
    AppToast.info(
      context,
      wasSaved ? '已移出书架' : '已加入书架',
      duration: const Duration(seconds: 1),
    );
  }

  void _openChapter(NovelChapter ch, {double resumeOffset = 0}) async {
    // 防连点：history() await 期间重复点击会 push 多个阅读器。
    if (_openingChapter) return;
    _openingChapter = true;
    HapticFeedback.selectionClick();
    try {
      final d = _detail!;
      // 续读直达场景（「继续阅读」按钮）已带偏移，无需再查历史；
      // 目录手动点选仍按历史恢复该章节内的滚动位置。
      var scrollOffset = resumeOffset;
      if (resumeOffset == 0) {
        final hist = await LocalStore.history();
        final key =
            Bookmark(
              sourceId: widget.sourceId,
              comicId: widget.novelId,
              name: '',
              pic: '',
            ).key;
        // 倒序找最新一条：同一章节被多次记录时取最近一次位置。
        for (final h in hist.reversed) {
          if (h.book.key == key && h.chapterId == ch.id) {
            scrollOffset = h.scrollOffset;
            break;
          }
        }
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => NovelReaderPage(
                sourceId: widget.sourceId,
                novelId: widget.novelId,
                chapterId: ch.id,
                title: ch.title,
                novelName: d.name,
                novelPic: d.pic ?? '',
                novelAuthor: d.author ?? d.comic.author ?? '',
                initialOffset: scrollOffset,
              ),
        ),
      );
      // 从阅读器返回：续读位可能已前进（读了新章节），重新解析历史，
      // 让「继续阅读」按钮、目录高亮与定位按钮跟随最新进度；阅读器里
      // 也会新增章节缓存，重扫目录离线标记。
      if (mounted) {
        // 失效图记（已读集/续读位同源）：_loadResume await future 读到重载
        // 后的最新历史，_readIds 角标随 watch 重建自动刷新。
        ref.invalidate(
            detailp.detailMarksProvider((widget.sourceId, widget.novelId)));
        _loadResume();
        _loadCachedIds();
      }
    } finally {
      _openingChapter = false;
    }
  }

  @override
  Widget build(BuildContext context) => EscPopScope(child: _buildRoot(context));

  Widget _buildRoot(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        title: Text(widget.name ?? _detail?.name ?? '小说详情'),
        actions: [
          if (_detail != null)
            IconButton(
              tooltip: _saved ? '移出书架' : '加入书架',
              icon: Icon(
                _saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              ),
              onPressed: _toggleSave,
            ),
        ],
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _error != null
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _error!,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => ref.invalidate(
                        detailp.novelDetailProvider(
                          (widget.sourceId, widget.novelId),
                        ),
                      ),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
              : Responsive.isExpanded(context)
              ? _bodyTablet(scheme)
              : _body(scheme),
    );
  }

  Widget _bodyTablet(scheme) {
    final d = _detail!;
    final pad = Responsive.pagePadding(context);

    // 使用响应式左侧面板宽度
    final leftPanelWidth = Responsive.detailLeftWidth(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 左侧：封面 + 元信息（固定宽度） ──────────────
        Container(
          width: leftPanelWidth,
          // body 已在 AppBar 之下，不再叠加状态栏高度，避免顶部空洞错位。
          padding: EdgeInsets.fromLTRB(pad, 14, 8, 16),
          // 长描述在矮屏/平板竖屏时左侧会超出视口：整列可滚动，杜绝溢出。
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                // 封面保持 2:3 比例：固定 height:200 在宽面板下会把封面压扁变形。
                Center(
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: _NovelCover(
                      url: d.pic ?? '',
                      width: double.infinity,
                      height: 200,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  d.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '作者：${d.author ?? d.comic.author ?? '未知'}',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                if (d.status != null)
                  Text(
                    '状态：${d.status}',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                const SizedBox(height: 10),
                if (_resume != null) ...[
                  FilledButton.icon(
                    onPressed: () => _openChapter(
                      _resume!.chapter,
                      resumeOffset: _resume!.offset,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text('继续阅读'),
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton.icon(
                  onPressed: _toggleSave,
                  icon: Icon(
                    _saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                  ),
                  label: Text(_saved ? '已在书架' : '加入书架'),
                ),
                if (d.description != null && d.description!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    d.description!,
                    maxLines: _descExpanded ? null : 4,
                    overflow: _descExpanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: scheme.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                  if (d.description!.length > 100)
                    GestureDetector(
                      onTap:
                          () => setState(() => _descExpanded = !_descExpanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _descExpanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        // ── 右侧：章节目录（可滚动） ─────────────────────
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(pad, 16, pad, 4),
                child: Row(
                  children: [
                    Text(
                      '目录（${d.chapters.length} 章）',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    if (_prefetch != null)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: () => setState(() => _prefetchCancel = true),
                        icon: const Icon(Icons.stop_circle_rounded, size: 14),
                        label: Text(
                          '缓存中 ${_prefetch!.done}/${_prefetch!.total}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      )
                    else if (_prefetchStart != null)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _prefetchChapters,
                        icon: const Icon(Icons.download_rounded, size: 14),
                        label: const Text('缓存后续',
                            style: TextStyle(fontSize: 12.5)),
                      )
                    else if (_hasResumeInList)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _jumpToResume,
                        icon: const Icon(Icons.my_location_rounded, size: 14),
                        label: const Text('定位续读',
                            style: TextStyle(fontSize: 12.5)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
                child: _chapterSearchField(scheme),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _tocCtrl,
                  padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
                  itemCount: _visibleChapters.length,
                  itemBuilder: (ctx, i) {
                    final ch = _visibleChapters[i];
                    final isResume = _resume?.chapter.id == ch.id;
                    return ListTile(
                      key: isResume ? _resumeTileKey : null,
                      dense: true,
                      title: Text(
                        ch.title,
                        style: TextStyle(
                          fontSize: 14,
                          color:
                              isResume ? scheme.primary : scheme.onSurface,
                          fontWeight: isResume ? FontWeight.w600 : null,
                        ),
                      ),
                      trailing: isResume
                          ? Icon(Icons.play_circle_fill_rounded,
                              size: 18, color: scheme.primary)
                          : _readIds.contains(ch.id)
                              ? Icon(Icons.check_circle_rounded,
                                  size: 16,
                                  color: scheme.primary.withValues(alpha: 0.7))
                              : Icon(
                                  _cachedIds.contains(ch.id)
                                      ? Icons.offline_pin_rounded
                                      : Icons.chevron_right_rounded,
                                  size: 18,
                                  color: _cachedIds.contains(ch.id)
                                      ? scheme.primary.withValues(alpha: 0.7)
                                      : null,
                                ),
                      onTap: () => _openChapter(ch),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(scheme) {
    final d = _detail!;
    return CustomScrollView(
      controller: _tocCtrl,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _NovelCover(url: d.pic ?? '', width: 96, height: 132),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '作者：${d.author ?? d.comic.author ?? '未知'}',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      if (d.status != null)
                        Text(
                          '状态：${d.status}',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      const SizedBox(height: 10),
                      if (_resume != null) ...[
                        FilledButton.icon(
                          onPressed: () => _openChapter(
                            _resume!.chapter,
                            resumeOffset: _resume!.offset,
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: Text('继续阅读'),
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.icon(
                        onPressed: _toggleSave,
                        icon: Icon(
                          _saved
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                        ),
                        label: Text(_saved ? '已在书架' : '加入书架'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (d.description != null && d.description!.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.description!,
                    maxLines: _descExpanded ? null : 4,
                    overflow: _descExpanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.6,
                      color: scheme.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                  if (d.description!.length > 100)
                    GestureDetector(
                      onTap:
                          () => setState(() => _descExpanded = !_descExpanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _descExpanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: FadeSlideIn(
            delay: const Duration(milliseconds: 200),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text(
                    '目录（${d.chapters.length} 章）',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  if (_prefetch != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => setState(() => _prefetchCancel = true),
                      icon: const Icon(Icons.stop_circle_rounded, size: 14),
                      label: Text(
                        '缓存中 ${_prefetch!.done}/${_prefetch!.total}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    )
                  else if (_prefetchStart != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: _prefetchChapters,
                      icon: const Icon(Icons.download_rounded, size: 14),
                      label: const Text('缓存后续',
                          style: TextStyle(fontSize: 12.5)),
                    )
                    else if (_hasResumeInList)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _jumpToResume,
                        icon: const Icon(Icons.my_location_rounded, size: 14),
                        label: const Text('定位续读',
                            style: TextStyle(fontSize: 12.5)),
                      ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: FadeSlideIn(
            delay: const Duration(milliseconds: 220),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _chapterSearchField(scheme),
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate((ctx, i) {
            final ch = _visibleChapters[i];
            final isResume = _resume?.chapter.id == ch.id;
            return FadeSlideIn(
              delay: Duration(milliseconds: 250 + 30 * (i % 20)),
              child: ListTile(
                key: isResume ? _resumeTileKey : null,
                dense: true,
                // 续读章节高亮：主题色文字 + 播放小图标，用户一眼定位追更位。
                title: Text(
                  ch.title,
                  style: TextStyle(
                    fontSize: 14,
                    color: isResume ? scheme.primary : scheme.onSurface,
                    fontWeight: isResume ? FontWeight.w600 : null,
                  ),
                ),
                trailing: isResume
                    ? Icon(Icons.play_circle_fill_rounded,
                        size: 18, color: scheme.primary)
                    : _readIds.contains(ch.id)
                        ? Icon(Icons.check_circle_rounded,
                            size: 16,
                            color: scheme.primary.withValues(alpha: 0.7))
                        : Icon(
                            _cachedIds.contains(ch.id)
                                ? Icons.offline_pin_rounded
                                : Icons.chevron_right_rounded,
                            size: 18,
                            color: _cachedIds.contains(ch.id)
                                ? scheme.primary.withValues(alpha: 0.7)
                                : null,
                          ),
                onTap: () => _openChapter(ch),
              ),
            );
          }, childCount: _visibleChapters.length),
        ),
      ],
    );
  }
}
