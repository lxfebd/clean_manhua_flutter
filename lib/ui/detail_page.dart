import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import '../sources/source_result.dart';
import '../net/download_manager.dart';
import '../net/error_logger.dart';
import '../net/http_client.dart';
import '../net/local_store.dart';
import 'detail_providers.dart';
import 'detail_providers.dart' as detailp;
import 'bookshelf_providers.dart' show bookshelfDataProvider;
import 'reader_page.dart';
import 'responsive.dart';
import 'detail_batch_download_sheet.dart';
import 'style_scope.dart';
import 'style_tokens.dart';
import 'tokens.dart';
import 'widgets/app_toast.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';
import 'keyboard_shortcuts.dart';

/// 漫画详情页：沉浸式 Hero 头 + 信息卡 + 章节网格。
class DetailPage extends ConsumerStatefulWidget {
  final String sourceId;
  final String comicId;
  final String? name;
  final String? pic;
  const DetailPage({
    super.key,
    required this.sourceId,
    required this.comicId,
    this.name,
    this.pic,
  });

  /// 解析「开始阅读」目标：查历史里该作品最近读到的章节；无则返回 null（= 第 1 话）。
  /// 转发到 detail_providers 层（provider 依赖此逻辑，提级避免循环导入）；
  /// 行为与历史/章节数据契约解耦，纯函数便于单元测试。
  static Chapter? resolveResumeChapter({
    required List<HistoryEntry> history,
    required List<Chapter> chapters,
    required String sourceId,
    required String comicId,
  }) => detailp.resolveResumeChapter(
    history: history,
    chapters: chapters,
    sourceId: sourceId,
    comicId: comicId,
  );

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  final _scrollCtrl = ScrollController();
  double _scrollOffset = 0;
  bool _descending = false; // 章节倒序（最新在顶部）
  List<Chapter>? _sortedCache; // 按 _descending 缓存的章节列表

  /// 正在打开章节（防止 await 历史记录期间连点并发 push 多个阅读器页）。
  bool _openingChapter = false;

  static const double _heroHeight = 260;

  /// 详情数据（provider 承载加载/超时/错误日志；页面只读展示）。
  ComicDetail? get _detail {
    final v = ref.read(comicDetailProvider((widget.sourceId, widget.comicId)));
    return v.when(data: (d) => d, loading: () => null, error: (_, __) => null);
  }

  /// 加载中：详情 provider 未就绪。
  bool get _loading =>
      ref
          .watch(comicDetailProvider((widget.sourceId, widget.comicId)))
          .isLoading;

  /// 错误文案（provider 抛错时按异常类型映射）。
  String? get _error {
    final v = ref.watch(comicDetailProvider((widget.sourceId, widget.comicId)));
    final e = v.error;
    if (v.hasError && e != null) return _detailErrorMessage(e);
    return null;
  }

  /// 是否在书架（本地状态，读取即缓存——书架页增删后本页不自动刷新，
  /// 与原「进入页面查一次」的行为一致）。
  bool get _saved {
    final v = ref.watch(
      comicInShelfProvider((widget.sourceId, widget.comicId)),
    );
    return v.when(
      data: (d) => d,
      loading: () => false,
      error: (_, __) => false,
    );
  }

  /// 续读目标：详情加载后经历史解析（provider 内编排时序）。
  Chapter? get _resumeChapter {
    final v = ref.watch(
      comicResumeProvider((widget.sourceId, widget.comicId)),
    );
    return v.when(
      data: (r) => r.chapter,
      loading: () => null,
      error: (_, __) => null,
    );
  }

  /// 续读就绪标记：provider 解析完成（失败也 ready——回退第 1 话）。
  bool get _resumeReady {
    final v = ref.watch(comicResumeProvider((widget.sourceId, widget.comicId)));
    return v.when(
      data: (r) => r.ready,
      loading: () => false,
      error: (_, __) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.hasClients) {
      final v = _scrollCtrl.offset.clamp(0.0, _heroHeight);
      if (v != _scrollOffset) setState(() => _scrollOffset = v);
    }
  }

  /// 按异常类型分档错误文案：网络类提示重试、解析类提示稍后、鉴权类提示登录，
  /// 其余沿用通用文案（SourceHttp._unwrap 会把 SourceErr 重包装成 Exception，
  /// 手写源只能走 toString 兜底，故兜底分支保留原措辞）。
  static String _detailErrorMessage(Object e) {
    if (e is TimeoutException) return '网络超时，请重试';
    if (e is SocketException) return '网络连接失败，请检查网络后重试';
    if (e is SourceUnauthorized) return '该源需要登录后才能查看详情';
    if (e is SourceBlocked) return '访问受限（触发站点风控），请稍后再试';
    if (e is SourceParse || e is FormatException) {
      return '页面数据异常，请稍后重试';
    }
    if (e is HttpStatusException) {
      return e.statusCode >= 500
          ? '源站服务异常（HTTP ${e.statusCode}），请稍后重试'
          : '页面数据异常，请稍后重试';
    }
    return '加载失败，请检查网络后重试';
  }

  @override
  Widget build(BuildContext context) => EscPopScope(child: _buildRoot(context));

  Widget _buildRoot(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final mq = MediaQuery.of(context);
        final name = _detail?.name ?? widget.name ?? '加载中…';
        final pic = _detail?.pic ?? widget.pic;
        final style = context.uiStyle;

        // 分栏布局：Expanded 及以上（≥840dp）才左右分栏。
        //
        // 原先 600/1200 两个分支都走 _buildTablet，判断是冗余的；且 600dp 就分栏过窄
        // ——按 detailLeftWidth，600dp 时左 260 + 右仅 340，两侧都施展不开。
        // M3 明确：Medium(600-839) 只有「低密度 + 操作明确」的内容才适合双窗格，
        // 竞品 Mihon / Kotatsu 也都是横屏或大屏才分栏。
        if (constraints.maxWidth >= Responsive.mediumBreakpoint) {
          return _buildTablet(theme, scheme, mq, name, pic);
        }
        // 手机：单栏沉浸式布局
        final topPad = mq.padding.top;
        final heroH = _heroHeight + topPad;
        final collapseProgress = (_scrollOffset / _heroHeight).clamp(0.0, 1.0);

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          body: Stack(
            children: [
              // ── 可滚动内容 ────────────────────────────────────────
              CustomScrollView(
                controller: _scrollCtrl,
                physics:
                    DesktopUi.isDesktopPlatform
                        ? kDesktopScrollPhysics
                        : const BouncingScrollPhysics(),
                slivers: [
                  // 给 Hero 留出空间
                  SliverToBoxAdapter(child: SizedBox(height: heroH)),

                  // ── 加载态 ──────────────────────────────────────
                  if (_loading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 60),
                        child: _LoadingView(),
                      ),
                    )
                  else if (_error != null)
                    SliverToBoxAdapter(
                      child: _ErrorView(
                        error: _error!,
                        onRetry: () => ref.invalidate(
                          comicDetailProvider((widget.sourceId, widget.comicId)),
                        ),
                      ),
                    )
                  else if (_detail != null) ...[
                    // 信息区（封面 + 标题 + 徽章 + 操作按钮）
                    SliverToBoxAdapter(
                      child: FadeSlideIn(
                        delay: const Duration(milliseconds: 100),
                        offset: 14,
                        child: _MetaSection(
                          detail: _detail!,
                          saved: _saved,
                          resumeChapter: _resumeReady ? _resumeChapter : null,
                          onRead:
                              _detail!.chapters.isEmpty
                                  ? null
                                  : () => _openStartChapter(),
                          onShelf: _toggleSave,
                        ),
                      ),
                    ),
                    // 简介
                    if ((_detail!.description ?? '').isNotEmpty)
                      SliverToBoxAdapter(
                        child: FadeSlideIn(
                          delay: const Duration(milliseconds: 180),
                          offset: 14,
                          child: _DescCard(detail: _detail!),
                        ),
                      ),
                    // 章节标题
                    SliverToBoxAdapter(
                      child: FadeSlideIn(
                        delay: const Duration(milliseconds: 260),
                        child: _ChapterHeader(
                          count: _detail!.chapters.length,
                          descending: _descending,
                          onToggleDescending: () {
                            setState(() {
                              _descending = !_descending;
                              _sortedCache = null;
                            });
                          },
                          onTapAll: _showAllChapters,
                        ),
                      ),
                    ),
                    // 章节列表（卡片行）
                    SliverToBoxAdapter(
                      child: FadeSlideIn(
                        delay: const Duration(milliseconds: 300),
                        offset: 14,
                      child: Container(
                        margin: EdgeInsets.fromLTRB(
                          Responsive.pagePadding(context),
                          4,
                          Responsive.pagePadding(context),
                          4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          // 头图是大卡 → hero 槽位：极简锁原值 14，小米 28 / 苹果 16。
                          borderRadius:
                              BorderRadius.circular(StyleTokens.heroRadius(context, 14)),
                          // 极简保持现状 hairline（onSurface@0.06, 1px）；
                          // 小米无描边（null，靠彩色阴影浮起）；苹果 0.5px alpha0.4 细描边。
                          border: Border.all(
                            color: style == UIStyle.minimalist
                                ? scheme.onSurface.withValues(alpha: 0.06)
                                : (StyleTokens.cardBorder(context) ?? BorderSide.none).color,
                            width: style == UIStyle.minimalist
                                ? 1
                                : (StyleTokens.cardBorder(context) ?? BorderSide.none).width,
                          ),
                          // 极简保持无阴影（原值）；小米加彩色阴影；苹果无阴影。
                          boxShadow: style == UIStyle.minimalist
                              ? null
                              : StyleTokens.cardShadow(context),
                        ),
                        clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (
                                var i = 0;
                                i < _detail!.chapters.length && i < 6;
                                i++
                              ) ...[
                                if (i > 0)
                                  Divider(
                                                                      height: 0.5,
                                                                      indent: StyleTokens.separatorIndent(context, 16),
                                                                      endIndent: StyleTokens.separatorEndIndent(context, 16),
                                                                      color: StyleTokens.rowSeparatorColor(context),
                                                                    ),
                                Builder(
                                  builder: (ctx) {
                                    final ch = _sortedChapters()[i];
                                    return _ChapterTile(
                                      index: i,
                                      chapter: ch,
                                      onTap: () => _openChapter(ch),
                                    );
                                  },
                                ),
                              ],
                              Divider(
                                height: 0.5,
                                indent: StyleTokens.separatorIndent(context, 16),
                                endIndent: StyleTokens.separatorEndIndent(context, 16),
                                color: StyleTokens.rowSeparatorColor(context),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: _showAllChapters,
                                      // 极简 R.control=8 与 token 一致，走 token 三风格化。
                                      borderRadius: BorderRadius.circular(
                                        R.of(R.control, style: context.uiStyle),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 13,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              '查看全部 ${_detail!.chapters.length} 话',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                                color: scheme.onSurface
                                                    .withValues(alpha: 0.6),
                                              ),
                                            ),
                                            Icon(
                                              Icons.keyboard_arrow_down_rounded,
                                              size: 16,
                                              color: scheme.onSurface
                                                  .withValues(alpha: 0.4),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 0.5,
                                    height: 18,
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.08,
                                    ),
                                  ),
                                  Expanded(
                                    child: InkWell(
                                      onTap: _showBatchDownload,
                                      // 极简 R.control=8 与 token 一致，走 token 三风格化。
                                      borderRadius: BorderRadius.circular(
                                        R.of(R.control, style: context.uiStyle),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 13,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.download_outlined,
                                              size: 15,
                                              color: scheme.primary.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              '批量下载',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: scheme.primary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 底部安全距离
                    SliverToBoxAdapter(
                      child: SizedBox(height: mq.padding.bottom + 40),
                    ),
                  ],
                ],
              ),

              // ── Hero 图片区（固定在顶部，随滚动淡出） ──────────────
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: heroH,
                child: Opacity(
                  opacity: 1.0 - collapseProgress,
                  child: _Hero(
                    sourceId: widget.sourceId,
                    comicId: widget.comicId,
                    name: name,
                    pic: pic,
                    status: _detail?.status,
                  ),
                ),
              ),

              // ── 顶部渐变蒙版（随滚动消失） ────────────────────────
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: topPad + 56,
                child: Opacity(
                  opacity: (1.0 - collapseProgress * 3).clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.35),
                          Colors.black.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── 顶部 AppBar 区域 ──────────────────────────────────
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: topPad + 56,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        const _BackButton(),
                        const Spacer(),
                        // 标题（滚动后显示）
                        if (collapseProgress > 0.6)
                          Expanded(
                            child: Opacity(
                              opacity: ((collapseProgress - 0.6) / 0.4).clamp(
                                0.0,
                                1.0,
                              ),
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: _saved ? '移出书架' : '加入书架',
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 280),
                            transitionBuilder:
                                (c, a) => ScaleTransition(scale: a, child: c),
                            child:
                                _saved
                                    ? const Icon(
                                      Icons.bookmark_rounded,
                                      key: ValueKey(true),
                                    )
                                    : const Icon(
                                      Icons.bookmark_border_rounded,
                                      key: ValueKey(false),
                                    ),
                          ),
                          color: scheme.primary,
                          onPressed: _toggleSave,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 平板/桌面横屏：左封面 + 右信息/按钮/章节列表（与播放器、预备页分栏范式统一）。
  Widget _buildTablet(
    ThemeData theme,
    ColorScheme scheme,
    MediaQueryData mq,
    String name,
    String? pic,
  ) {
    final topPad = mq.padding.top;
    final d = _detail;
    final style = context.uiStyle;
    final metaParts = <String>[
      if (d != null && (d.author ?? '').isNotEmpty) '${d.author} 著',
      if (d != null && (d.type ?? '').isNotEmpty) d.type!,
      if (d != null && (d.area ?? '').isNotEmpty) d.area!,
    ];

    // 使用响应式左侧面板宽度
    final leftPanelWidth = Responsive.detailLeftWidth(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 左侧：完整竖版封面（固定） ──────────────────────
          Container(
            width: leftPanelWidth,
            padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context),
              topPad + 10,
              8,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _BackButton(),
                const SizedBox(height: 10),
                // 封面保持 2:3 比例并限高，避免大屏（左栏随视口高度拉伸）
                // 把封面拉成全列高的竖长条、BoxFit.cover 裁切到只剩中缝。
                Center(
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: ClipRRect(
                      // 极简锁原值 18（StyleTokens.controlRadius 极简=8，与现状不匹配）；
                      // 小米 14 / 苹果 10 走 token。
                      borderRadius: BorderRadius.circular(
                        style == UIStyle.minimalist
                            ? 18
                            : R.of(R.control, style: context.uiStyle),
                      ),
                      child: Container(
                        width: double.infinity,
                        color: scheme.surfaceContainerHighest,
                        child:
                            (pic == null || pic.isEmpty)
                                ? Center(
                                  child: Icon(
                                    Icons.image_outlined,
                                    size: 48,
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.2,
                                    ),
                                  ),
                                )
                                : CachedImage(
                                  pic,
                                  fit: BoxFit.cover,
                                  radius: 0,
                                ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── 右侧：信息 + 按钮 + 简介 + 章节列表（可滚动） ──
          // 桌面超宽屏右栏不含限宽（本页是独立路由，不经过 main_shell 的
          // MaxWidthContainer），内容会被拉到 1500dp+；限宽 1040 居中。
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: CustomScrollView(
                  controller: _scrollCtrl,
                  physics:
                      DesktopUi.isDesktopPlatform
                          ? kDesktopScrollPhysics
                          : const BouncingScrollPhysics(),
                  slivers: [
                    if (_loading)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: 80),
                          child: _LoadingView(),
                        ),
                      )
                    else if (_error != null)
                      SliverToBoxAdapter(
                        child: _ErrorView(
                          error: _error!,
                          onRetry: () => ref.invalidate(
                            comicDetailProvider(
                              (widget.sourceId, widget.comicId),
                            ),
                          ),
                        ),
                      )
                    else if (d != null) ...[
                      SliverToBoxAdapter(
                        child: FadeSlideIn(
                          delay: const Duration(milliseconds: 80),
                          offset: 14,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              Responsive.pagePadding(context),
                              topPad + 12,
                              Responsive.pagePadding(context),
                              6,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.name,
                                  style: TextStyle(
                                    fontSize:
                                        Responsive.isExpanded(context)
                                            ? 24
                                            : 20,
                                    fontWeight: FontWeight.w800,
                                    height: 1.3,
                                  ),
                                ),
                                if (metaParts.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    metaParts.join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: scheme.onSurface.withValues(
                                        alpha: 0.55,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    if ((d.status ?? '').isNotEmpty)
                                      _StatusPill(label: d.status!),
                                    _CountPill(label: '${d.chapters.length} 话'),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                // 统一尺寸按钮，并排大热区
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.icon(
                                        onPressed:
                                            d.chapters.isEmpty
                                                ? null
                                                : () {
                                                  final resume =
                                                      _resumeReady
                                                          ? _resumeChapter
                                                          : null;
                                                  _openChapter(
                                                    resume ?? d.chapters.first,
                                                  );
                                                },
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                          size: 18,
                                        ),
                                        label: Text(
                                          _resumeReady && _resumeChapter != null
                                              ? '继续阅读'
                                              : '开始阅读',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: _toggleSave,
                                        icon: Icon(
                                          _saved
                                              ? Icons.bookmark_rounded
                                              : Icons.bookmark_outline_rounded,
                                          size: 18,
                                        ),
                                        label: Text(_saved ? '已在书架' : '加入书架'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if ((d.description ?? '').isNotEmpty)
                        SliverToBoxAdapter(
                          child: FadeSlideIn(
                            delay: const Duration(milliseconds: 170),
                            offset: 14,
                            child: _DescCard(detail: d),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: FadeSlideIn(
                          delay: const Duration(milliseconds: 250),
                          offset: 14,
                          child: _ChapterHeader(
                            count: d.chapters.length,
                            descending: _descending,
                            onToggleDescending: () {
                              setState(() {
                                _descending = !_descending;
                                _sortedCache = null;
                              });
                            },
                            onTapAll: _showAllChapters,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(child: _tabletChapterList(d, scheme)),
                      SliverToBoxAdapter(
                        child: SizedBox(height: mq.padding.bottom + 40),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 平板右栏章节列表：竖向排列，直观大热区，支持排序切换与全部/批量下载。
  Widget _tabletChapterList(ComicDetail d, ColorScheme scheme) {
    final chapters = _sortedChapters();
    // 平板上显示更多章节（最多20个），充分利用空间
    final isExpanded = Responsive.isExpanded(context);
    final show =
        isExpanded
            ? (chapters.length < 20 ? chapters.length : 20)
            : (chapters.length < 12 ? chapters.length : 12);
    final style = context.uiStyle;
    return Container(
      margin: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        4,
        Responsive.pagePadding(context),
        4,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        // 极简锁原值 14（StyleTokens.cardRadius 极简=12，与现状不匹配）；
        // 小米 20 / 苹果 12 走 token。
        borderRadius: BorderRadius.circular(
          style == UIStyle.minimalist
              ? 14
              : R.of(R.card, style: context.uiStyle),
        ),
        // 极简保持现状 hairline（onSurface@0.06, 1px）；
        // 小米无描边；苹果 0.5px alpha0.4 细描边。
        border: Border.all(
          color: style == UIStyle.minimalist
              ? scheme.onSurface.withValues(alpha: 0.06)
              : (StyleTokens.cardBorder(context) ?? BorderSide.none).color,
          width: style == UIStyle.minimalist
              ? 1
              : (StyleTokens.cardBorder(context) ?? BorderSide.none).width,
        ),
        // 极简保持无阴影；小米加彩色阴影；苹果无阴影。
        boxShadow: style == UIStyle.minimalist
            ? null
            : StyleTokens.cardShadow(context),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < show; i++) ...[
            if (i > 0)
              Divider(
                height: 0.5,
                indent: StyleTokens.separatorIndent(context, 16),
                endIndent: StyleTokens.separatorEndIndent(context, 16),
                color: StyleTokens.rowSeparatorColor(context),
              ),
            _ChapterTile(
              index: i,
              chapter: chapters[i],
              onTap: () => _openChapter(chapters[i]),
            ),
          ],
          Divider(
            height: 0.5,
            indent: StyleTokens.separatorIndent(context, 16),
            endIndent: StyleTokens.separatorEndIndent(context, 16),
            color: StyleTokens.rowSeparatorColor(context),
          ),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _showAllChapters,
                  // 极简 R.control=8 与 token 一致，走 token 三风格化。
                  borderRadius: BorderRadius.circular(
                    R.of(R.control, style: context.uiStyle),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '查看全部 ${d.chapters.length} 话',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: scheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: 0.5,
                height: 18,
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
              Expanded(
                child: InkWell(
                  onTap: _showBatchDownload,
                  // 极简 R.control=8 与 token 一致，走 token 三风格化。
                  borderRadius: BorderRadius.circular(
                    R.of(R.control, style: context.uiStyle),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.download_outlined,
                          size: 15,
                          color: scheme.primary.withValues(alpha: 0.9),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '批量下载',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _toggleSave() async {
    if (_detail == null) return;
    HapticFeedback.lightImpact();
    final wasSaved = _saved;
    try {
      final source = SourceManager.byId(widget.sourceId);
      await source.toggleBookshelf(_detail!);
    } catch (e) {
      // 写书架失败不翻转状态（磁盘与 UI 不失步）。
      ErrorLogger.instance.warn('toggle bookshelf failed: $e');
      if (mounted) {
        AppToast.error(context, '书架操作失败，请重试');
      }
      return;
    }
    if (!mounted) return;
    // 翻转书架状态：失效 provider 让下次读取重跑 isInBookshelf（异步，
    // UI 随 watch 重建自动反映新值）；toast 用本地捕获的旧值取反。
    // 同时失效 bookshelfDataProvider：书架列表常驻 keep-alive（不重建），
    // 只失效详情侧会导致「详情页收藏了、书架里却不出现」的跨页不同步。
    ref.invalidate(comicInShelfProvider((widget.sourceId, widget.comicId)));
    ref.invalidate(bookshelfDataProvider);
    AppToast.info(context, wasSaved ? '已移出书架' : '已加入书架');
  }

  /// 按当前排序返回章节列表（带缓存）。
  List<Chapter> _sortedChapters() {
    final cache = _sortedCache;
    if (cache != null) return cache;
    final list = _detail!.chapters;
    final out = _descending ? list.reversed.toList(growable: false) : list;
    _sortedCache = out;
    return out;
  }

  /// 完整章节列表底部弹窗。
  void _showAllChapters() {
    // 数据量下很快（一次读表），但先给即时反馈避免"点了没反应"。
    _loadCachedChapters().then((_) {
      if (!mounted) return;
      _showAllChaptersSheet();
    });
  }

  /// 批量下载选章弹窗：多选章节 → 批量下载。
  void _showBatchDownload() {
    _loadCachedChapters().then((_) {
      if (!mounted) return;
      _openBatchDownloadSheet();
    });
  }

  /// 批量下载选章弹窗：逻辑已拆至 detail_batch_download_sheet.dart。
  void _openBatchDownloadSheet() {
    final detail = _detail;
    if (detail == null) return;
    showBatchDownloadSheet(
      context,
      chapters: _sortedChapters(),
      cachedIds: _cachedChapters,
      sourceId: widget.sourceId,
      comicId: detail.id,
      comicName: detail.name,
      comicPic: detail.pic,
    );
  }

  /// 预加载所有章节的缓存状态（用于章节列表显示 ✓）。
  /// 一次读取全表 + key 前缀过滤（逐章 isDownloaded 会 O(N²) 全表重扫，
  /// 章节多时让"查看全部/批量下载"按钮像点了没反应）。
  Future<void> _loadCachedChapters() async {
    if (_chaptersBusy) return;
    _chaptersBusy = true;
    try {
      final bookKey = DownloadManager.bookKeyOf(widget.sourceId, _detail!.id);
      final prefix = '$bookKey/';
      final all = await LocalStore.downloads();
      final set = <String>{
        for (final d in all)
          if (d.finished == true && d.key.startsWith(prefix))
            d.key.substring(prefix.length),
      };
      if (mounted) setState(() => _cachedChapters = set);
    } finally {
      _chaptersBusy = false;
    }
  }

  bool _chaptersBusy = false;

  Set<String> _cachedChapters = {};

  void _showAllChaptersSheet() {
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(
            StyleTokens.sheetRadiusOr(context, 20),
          ),
        ),
      ),
      builder:
          (ctx) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Text(
                          '全部章节 · ${_detail!.chapters.length} 话',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: Theme.of(ctx).colorScheme.onSurface,
                          ),
                        ),
                        if (_cachedChapters.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              '已缓存 ${_cachedChapters.length} 话',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                            ),
                          ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _descending = !_descending;
                              _sortedCache = null;
                            });
                          },
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
                  Divider(
                                      height: 0.5,
                                      indent: StyleTokens.separatorIndent(context, 0),
                                      endIndent: StyleTokens.separatorEndIndent(context, 0),
                                      color: context.uiStyle == UIStyle.minimalist
                                          ? null
                                          : StyleTokens.rowSeparatorColor(context),
                                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _sortedChapters().length,
                      itemBuilder: (_, i) {
                        final ch = _sortedChapters()[i];
                        final cached = _cachedChapters.contains(ch.id);
                        return ListTile(
                          title: Row(
                            children: [
                              if (cached)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Icon(
                                    Icons.download_done_rounded,
                                    size: 14,
                                    color: Theme.of(ctx).colorScheme.primary,
                                  ),
                                ),
                              Flexible(
                                child: Text(
                                  ch.title.isEmpty ? '第${i + 1}话' : ch.title,
                                  style: const TextStyle(fontSize: 13.5),
                                ),
                              ),
                            ],
                          ),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: Theme.of(
                              ctx,
                            ).colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _openChapter(ch);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  /// 「开始阅读」：有历史记录则续读上次章节，否则从第 1 话开始。
  void _openStartChapter() {
    final resume = _resumeChapter;
    final chapters = _detail?.chapters;
    if (chapters == null || chapters.isEmpty) return;
    final target = resume ?? chapters.first;
    _openChapter(target);
  }

  Future<void> _openChapter(Chapter ch) async {
    if (_openingChapter) return;
    _openingChapter = true;
    try {
      final history = await _historyForChapter(ch);
      if (!mounted) return;
      Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder:
              (_, __, ___) => ReaderPage(
                sourceId: widget.sourceId,
                comicId: _detail!.id,
                chapterId: ch.id,
                title: ch.title,
                comicName: _detail!.name,
                comicPic: _detail!.pic ?? '',
                comicAuthor: _detail!.author ?? '',
                chapters: _detail!.chapters,
                initialPage: history.pageIndex,
                initialOffset: history.scrollOffset,
              ),
          transitionDuration: context.uiStyle == UIStyle.minimalist
              ? const Duration(milliseconds: 320)
              : StyleTokens.transitionDuration(context),
          transitionsBuilder: (_, anim, __, child) {
            return FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: anim,
                  curve: context.uiStyle == UIStyle.minimalist
                      ? Curves.easeOut
                      : StyleTokens.transitionCurve(context),
                )),
                child: child,
              ),
            );
          },
        ),
      );
    } finally {
      _openingChapter = false;
    }
  }

  /// 从历史记录里查当前章节最后读到的位置（无则 pageIndex=-1 从第一页开始）。
  /// 返回完整条目以同时提供页码与纵向滚动偏移（像素级续读）。
  Future<HistoryEntry> _historyForChapter(Chapter ch) async {
    final hist = await LocalStore.history();
    final b = _detail!.bookmarkFor(widget.sourceId);
    final key = b.key;
    // 倒序找最新一条（同一章节可能被多次记录，页码取最近一次）。
    for (final h in hist.reversed) {
      if (h.book.key == key && h.chapterId == ch.id && h.hasPage) {
        return h;
      }
    }
    return HistoryEntry(
      book: b,
      chapterId: ch.id,
      chapterTitle: ch.title,
      timestamp: 0,
      pageIndex: -1,
    );
  }
}

// ─── 沉浸式 Hero ────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final String sourceId;
  final String comicId;
  final String name;
  final String? pic;
  final String? status;
  const _Hero({
    required this.sourceId,
    required this.comicId,
    required this.name,
    required this.pic,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = context.uiStyle;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 详情页头图不用 Hero：来源列表（首页/书架/搜索等多处同款列表并存）里
        // 同一 tag 会出现多次，Hero 动画反而会触发「multiple heroes」崩溃。
        if (pic != null && pic!.isNotEmpty)
          CachedImage(pic!, fit: BoxFit.cover, radius: 0)
        else
          Container(color: scheme.surfaceContainerHighest),
        // 三段式渐变蒙版
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.18),
                Colors.black.withValues(alpha: 0.38),
                theme.scaffoldBackgroundColor.withValues(alpha: 0.0),
                theme.scaffoldBackgroundColor,
              ],
              stops: const [0, 0.35, 0.78, 1.0],
            ),
          ),
        ),
        // 底部恒暗黑衬：标题区白字在浅色主题/浅封面上也不隐身
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.72),
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.0),
                ],
                stops: const [0, 0.3, 0.58],
              ),
            ),
          ),
        ),
        // 标题区
        Positioned(
          left: 18,
          right: 18,
          bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeSlideIn(
                delay: const Duration(milliseconds: 80),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.secondary,
                        // 极简锁原值 5（StyleTokens.controlRadius 极简=8，与现状不匹配）；
                        // 小米 14 / 苹果 10 走 token。
                        borderRadius: BorderRadius.circular(
                          style == UIStyle.minimalist
                              ? 5
                              : R.of(R.control, style: context.uiStyle),
                        ),
                        // Minimalist：徽标扁平，不使用辉光。
                        boxShadow: const [],
                      ),
                      child: Text(
                        (status?.isNotEmpty == true) ? status! : '连载中',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        // 极简锁原值 6（StyleTokens.controlRadius 极简=8，与现状不匹配）；
                        // 小米 14 / 苹果 10 走 token。
                        borderRadius: BorderRadius.circular(
                          style == UIStyle.minimalist
                              ? 6
                              : R.of(R.control, style: context.uiStyle),
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3),
                          width: 0.5,
                        ),
                      ),
                      child: const Text(
                        'COMIC',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              FadeSlideIn(
                delay: const Duration(milliseconds: 160),
                offset: 16,
                child: ShaderMask(
                  shaderCallback:
                      (rect) => const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Colors.white, Color(0xFFE8EAF0)],
                      ).createShader(rect),
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      height: 1.18,
                      letterSpacing: 0.3,
                      shadows: [Shadow(blurRadius: 12, color: Colors.black54)],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTablet = Responsive.isTablet(context);

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color:
            isTablet
                ? scheme.surface.withValues(alpha: 0.9)
                : Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.maybePop(context),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(
              Icons.arrow_back_rounded,
              color: isTablet ? scheme.onSurface : Colors.white,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 元数据条 ────────────────────────────────────────────────────────────────

class _MetaSection extends StatelessWidget {
  final ComicDetail detail;
  final bool saved;
  final VoidCallback? onRead;
  final VoidCallback onShelf;

  /// 非空 = 有上次阅读记录（按钮显示「继续阅读」）；null = 从第 1 话开始。
  final Chapter? resumeChapter;
  const _MetaSection({
    required this.detail,
    required this.saved,
    this.onRead,
    required this.onShelf,
    this.resumeChapter,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = detail;
    final style = context.uiStyle;
    final metaParts = <String>[
      if ((d.author ?? '').isNotEmpty) '${d.author} 著',
      if ((d.type ?? '').isNotEmpty) d.type!,
      if ((d.area ?? '').isNotEmpty) d.area!,
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        14,
        Responsive.pagePadding(context),
        6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                // 极简锁原值 10（StyleTokens.controlRadius 极简=8，与现状不匹配）；
                // 小米 14 / 苹果 10 走 token。
                borderRadius: BorderRadius.circular(
                  style == UIStyle.minimalist
                      ? 10
                      : R.of(R.control, style: context.uiStyle),
                ),
                child: Container(
                  width: 104,
                  height: 148,
                  color: scheme.surfaceContainerHighest,
                  child:
                      (d.pic == null || d.pic!.isEmpty)
                          ? Icon(
                            Icons.image_outlined,
                            size: 32,
                            color: scheme.onSurface.withValues(alpha: 0.2),
                          )
                          : CachedImage(d.pic!, fit: BoxFit.cover, radius: 0),
                ),
              ),
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
                        height: 1.3,
                      ),
                    ),
                    if (metaParts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          metaParts.join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if ((d.status ?? '').isNotEmpty)
                          _StatusPill(label: d.status!),
                        _CountPill(label: '${d.chapters.length} 话'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onRead,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(resumeChapter != null ? '继续阅读' : '开始阅读'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onShelf,
                  icon: Icon(
                    saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_outline_rounded,
                    size: 18,
                  ),
                  label: Text(saved ? '已在书架' : '加入书架'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 状态徽章（墨蓝底白字，如"连载中"）。
class _StatusPill extends StatelessWidget {
  final String label;
  const _StatusPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final style = context.uiStyle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        // 极简锁原值 5（StyleTokens.controlRadius 极简=8，与现状不匹配）；
        // 小米 14 / 苹果 10 走 token。
        borderRadius: BorderRadius.circular(
          style == UIStyle.minimalist
              ? 5
              : R.of(R.control, style: context.uiStyle),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 计数徽章（黑 6% 底，黑 60% 字）。
class _CountPill extends StatelessWidget {
  final String label;
  const _CountPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        // 极简锁原值 5（StyleTokens.controlRadius 极简=8，与现状不匹配）；
        // 小米 14 / 苹果 10 走 token。
        borderRadius: BorderRadius.circular(
          style == UIStyle.minimalist
              ? 5
              : R.of(R.control, style: context.uiStyle),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

// ─── 简介卡 ──────────────────────────────────────────────────────────────────

class _DescCard extends StatefulWidget {
  final ComicDetail detail;
  const _DescCard({required this.detail});

  @override
  State<_DescCard> createState() => _DescCardState();
}

class _DescCardState extends State<_DescCard> {
  /// 长简介折叠：默认收起（>4 行时截断 + 显示「展开」），避免长介绍
  /// 把封面/章节列表挤出首屏；手动展开后保留展开态。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desc = widget.detail.description ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        10,
        Responsive.pagePadding(context),
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            desc,
            maxLines: _expanded ? null : 4,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.75,
              color: scheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          if (desc.length > 120)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _expanded ? '收起' : '展开',
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
    );
  }
}

// ─── 章节标题 ────────────────────────────────────────────────────────────────

class _ChapterHeader extends StatelessWidget {
  final int count;
  final bool descending;
  final VoidCallback onToggleDescending;
  final VoidCallback onTapAll;
  const _ChapterHeader({
    required this.count,
    this.descending = false,
    required this.onToggleDescending,
    required this.onTapAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        16,
        Responsive.pagePadding(context),
        10,
      ),
      child: SectionHeader(
        icon: Icons.menu_book_rounded,
        title: '章节',
        count: count,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: onTapAll,
              behavior: HitTestBehavior.opaque,
              child: Text(
                '全部 $count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 14),
            GestureDetector(
              onTap: onToggleDescending,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Text(
                    descending ? '倒序' : '正序',
                    style: TextStyle(fontSize: 11, color: scheme.primary),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    descending
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    size: 14,
                    color: scheme.primary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 章节项 ──────────────────────────────────────────────────────────────────

class _ChapterTile extends StatefulWidget {
  final int index;
  final Chapter chapter;
  final VoidCallback onTap;
  const _ChapterTile({
    required this.index,
    required this.chapter,
    required this.onTap,
  });

  @override
  State<_ChapterTile> createState() => _ChapterTileState();
}

class _ChapterTileState extends State<_ChapterTile> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.chapter.title.isEmpty
                    ? '第${widget.index + 1}话'
                    : widget.chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 加载 & 错误态 ───────────────────────────────────────────────────────────

class _LoadingView extends StatefulWidget {
  const _LoadingView();

  @override
  State<_LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<_LoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final t = ((_c.value + i / 3) % 1.0);
              final opacity = (1.0 - (t - 0.5).abs() * 2).clamp(0.2, 1.0);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: opacity),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
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
                child: Icon(
                  Icons.cloud_off_outlined,
                  size: 44,
                  color: scheme.error,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.7),
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
      ),
    );
  }
}
