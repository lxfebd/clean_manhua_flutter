import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../net/download_manager.dart';
import '../net/local_store.dart';
import '../net/video_download_manager.dart';
import 'responsive.dart';
import 'tokens.dart';
import 'widgets/app_toast.dart';

/// 下载列表过滤纯函数（漫画/动漫共用搜索框；独立便于单元测试）。
/// 漫画按书名/章节标题匹配，动漫按番剧名/集数匹配（空 = 原样返回）。
List<DownloadRecord> filterMangaDownloads(
    List<DownloadRecord> records, String filter) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return records;
  return [
    for (final d in records)
      if (d.book.name.toLowerCase().contains(f) ||
          d.chapterTitle.toLowerCase().contains(f))
        d,
  ];
}

List<VideoDownloadTask> filterAnimeDownloads(
    List<VideoDownloadTask> tasks, String filter) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return tasks;
  return [
    for (final t in tasks)
      if (t.title.toLowerCase().contains(f) ||
          t.episode.toString().contains(f))
        t,
  ];
}

/// 漫画下载累计已缓存页数：所有记录已下载页数（done）之和。
/// 进行中的任务只计入已下载部分，空表返回 0。纯函数便于单元测试。
int totalMangaCachedPages(List<DownloadRecord> records) {
  var total = 0;
  for (final r in records) {
    total += r.done;
  }
  return total;
}

/// 动漫下载累计已完成集数：仅统计 state == 'done' 的任务。
/// 进行中/失败/取消不计入，空表返回 0。纯函数便于单元测试。
int totalAnimeDoneEpisodes(List<VideoDownloadTask> tasks) {
  var total = 0;
  for (final t in tasks) {
    if (t.state == 'done') total++;
  }
  return total;
}

/// 书架「下载」Tab 视图：漫画章节下载 + 已下载动漫，集中在此管理
/// （下载本就属于「我的内容」，从工具箱挪到书架，工具箱回归纯工具）。
///
/// 纯渲染组件：列表数据与操作逻辑由 [BookshelfPageState] 通过构造参数传入
/// （含清空/重试/删除/打开详情等回调），自身只持搜索过滤态。
/// 手机/平板两套布局共用本组件（两处 slivers 调用点均返回本 Widget）。
///
/// 返回单个 Sliver（平板/手机外层 CustomScrollView 均已自带
/// RefreshIndicator + BouncingScrollPhysics）。此处严禁再内嵌
/// CustomScrollView / RefreshIndicator——它们都是 RenderBox，被塞进
/// slivers 列表会让 Viewport 收到非法子组件，直接触发
/// "RenderViewport expected a child of type RenderSliver but received a
/// child of type RenderErrorBox"（书架页崩溃根因）。
class BookshelfDownloadView extends StatefulWidget {
  const BookshelfDownloadView({
    super.key,
    required this.scheme,
    required this.mangaDownloads,
    required this.animeDownloads,
    required this.onClearManga,
    required this.onRetryAllManga,
    this.retryingAll = false,
    required this.onOpenMangaDetail,
    required this.onRetryManga,
    required this.onRemoveManga,
    required this.onRemoveMangaBook,
    required this.onClearAnime,
    required this.onOpenAnime,
    required this.onRetryAnime,
    required this.onRemoveAnime,
    required this.onRemoveAnimeTitle,
  });

  final ColorScheme scheme;

  /// 漫画章节下载记录（书架主 State 持有）。
  final List<DownloadRecord> mangaDownloads;

  /// 已下载完成的动漫任务（书架主 State 持有）。
  final List<VideoDownloadTask> animeDownloads;

  /// 清空全部漫画下载（含确认对话框）。
  final Future<void> Function() onClearManga;

  /// 一键重试所有失败的漫画下载。
  final Future<void> Function() onRetryAllManga;

  /// 一键重试进行中（进行中禁用按钮防重入，避免并发启动相同任务）。
  final bool retryingAll;

  /// 打开漫画详情页。
  final void Function(Bookmark book) onOpenMangaDetail;

  /// 重试单条漫画下载。
  final Future<void> Function(DownloadRecord record) onRetryManga;

  /// 删除单条漫画下载（含确认对话框）。
  final void Function(DownloadRecord record) onRemoveManga;

  /// 删除某本书的全部下载记录（含确认对话框；按 book 聚合）。
  final Future<void> Function(Bookmark book) onRemoveMangaBook;

  /// 清空全部动漫下载（含确认对话框）。
  final Future<void> Function() onClearAnime;

  /// 打开本地动漫视频（或提示文件缺失）。
  final void Function(VideoDownloadTask task) onOpenAnime;

  /// 重新下载失败的动漫单集（重试走同一 start 入口恢复原任务）。
  final Future<void> Function(VideoDownloadTask task) onRetryAnime;

  /// 删除单条动漫下载（含确认对话框）。
  final void Function(VideoDownloadTask task) onRemoveAnime;

  /// 删除某部番剧的全部下载记录（含确认对话框；按 title 聚合）。
  final Future<void> Function(VideoDownloadTask task) onRemoveAnimeTitle;

  @override
  State<BookshelfDownloadView> createState() => _BookshelfDownloadViewState();
}

class _BookshelfDownloadViewState extends State<BookshelfDownloadView> {
  final _filterCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  /// 已失败（非进行中）的漫画下载任务：未完成且计数到齐（无法完成的重试
  /// 之后中断），与卡片失败样式判定一致。进行中的任务（done < total）不算，
  /// 避免「重试 N」虚高与对进行中任务重复启动下载。
  List<DownloadRecord> get _failedManga => widget.mangaDownloads
      .where((d) => !d.finished && d.total > 0 && d.done >= d.total)
      .toList();

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final manga = filterMangaDownloads(widget.mangaDownloads, _filter);
    final anime = filterAnimeDownloads(widget.animeDownloads, _filter);
    final totalManga = widget.mangaDownloads.length;
    final totalAnime = widget.animeDownloads.length;
    final bottomPad = Responsive.isExpanded(context) ? 24.0 : 110.0;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context), 8,
        Responsive.pagePadding(context), bottomPad),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _searchField(context),
            _summaryRow(context, totalManga, totalAnime),
            if (_filter.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '匹配 ${manga.length + anime.length} 条下载',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.55),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _sectionHeader(context, scheme, Icons.menu_book_rounded, '漫画下载',
                totalManga,
                manga.isEmpty ? null : widget.onClearManga,
                trailing: _failedManga.isEmpty
                    ? null
                    : TextButton.icon(
                        onPressed:
                            widget.retryingAll ? null : widget.onRetryAllManga,
                        icon: widget.retryingAll
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded, size: 16),
                        label: Text(
                            widget.retryingAll ? '重试中…' : '重试 ${_failedManga.length}'),
                      )),
            const SizedBox(height: 8),
            if (manga.isEmpty)
              _TabEmpty(
                  icon: Icons.download_done_rounded,
                  text: _filter.trim().isEmpty
                      ? '还没有漫画下载'
                      : '没有匹配「$_filter」的漫画下载',
                  subtitle: _filter.trim().isEmpty
                      ? '在阅读页点击缓存，即可离线观看'
                      : null)
            else
              ...manga.map((d) => _mangaDownloadCard(context, scheme, d)),
            const SizedBox(height: 20),
            _sectionHeader(context, scheme,
                Icons.ondemand_video_rounded,
                '动漫下载',
                totalAnime,
                anime.isEmpty ? null : widget.onClearAnime),
            const SizedBox(height: 8),
            if (anime.isEmpty)
              _TabEmpty(
                  icon: Icons.video_library_outlined,
                  text: _filter.trim().isEmpty
                      ? '还没有下载的动漫'
                      : '没有匹配「$_filter」的动漫下载',
                  subtitle: _filter.trim().isEmpty
                      ? '观看时点击缓存，即可离线观看'
                      : null)
            else
              ...anime.map((t) => _animeDownloadCard(context, scheme, t)),
          ],
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: _filterCtrl,
      onChanged: (v) => setState(() => _filter = v),
      style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索下载（书名 / 番剧名 / 集数）',
        hintStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurface.withValues(alpha: 0.4),
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 18,
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
        suffixIcon: _filter.isEmpty
            ? null
            : IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: () {
                  _filterCtrl.clear();
                  setState(() => _filter = '');
                },
              ),
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(R.control),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// 总览统计行：漫画下载条目数 / 累计已缓存页数 / 动漫已完成集数。
  /// 与分区徽标同为全量口径（不受搜索过滤影响），过滤态另由「匹配 N 条」提示。
  Widget _summaryRow(BuildContext context, int totalManga, int totalAnime) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 12,
      color: scheme.onSurface.withValues(alpha: 0.55),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Text('共 ${totalManga + totalAnime} 条下载', style: style),
          if (totalManga > 0) ...[
            const SizedBox(width: 8),
            Text('· 漫画已缓存 ${totalMangaCachedPages(widget.mangaDownloads)} 页',
                style: style),
          ],
          if (totalAnimeDoneEpisodes(widget.animeDownloads) > 0) ...[
            const SizedBox(width: 8),
            Text(
                '· 动漫已完成 ${totalAnimeDoneEpisodes(widget.animeDownloads)} 集',
                style: style),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, ColorScheme scheme, IconData icon,
      String title, int count, VoidCallback? onClear,
      {Widget? trailing}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Text(title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                )),
        const SizedBox(width: 8),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(R.control),
            ),
            child: Text('$count',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    )),
          ),
        const Spacer(),
        if (trailing != null) ...[
          trailing,
          const SizedBox(width: 4),
        ],
        if (onClear != null)
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: const Text('清空'),
          ),
      ],
    );
  }

  Widget _mangaDownloadCard(
      BuildContext context, ColorScheme scheme, DownloadRecord d) {
    final text = Theme.of(context).textTheme;
    // 状态机（三态区分，取消≠失败）：
    // - finished        → 完成（绿）
    // - error=='已取消' → 用户主动取消，中性灰（不是失败，不该红名吓用户）
    // - 其余 error      → 真实失败（写盘/网络），红名 + 显示原因
    // - 计数到齐未 finished → 旧记录失败态（重试之后中断），红名兜底
    // - 其他            → 进行中（橙）
    final cancelled = !d.finished && d.error == '已取消';
    final failed =
        !d.finished &&
        !cancelled &&
        ((d.error?.isNotEmpty ?? false) ||
            (d.total > 0 && d.done >= d.total));
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(R.card),
        border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness)),
      ),
      child: InkWell(
        onTap: () => widget.onOpenMangaDetail(d.book),
        onLongPress: () => _showMangaCardMenu(context, d),
        borderRadius: BorderRadius.circular(R.card),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: d.finished
                    ? Colors.green.withValues(alpha: 0.1)
                    : (cancelled
                        ? scheme.onSurface.withValues(alpha: 0.08)
                        : (failed
                            ? Colors.red.withValues(alpha: 0.1)
                            : Colors.orange.withValues(alpha: 0.1))),
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: Icon(
                d.finished
                    ? Icons.check_circle_outline
                    : (cancelled
                        ? Icons.stop_circle_outlined
                        : (failed
                            ? Icons.error_outline_rounded
                            : Icons.downloading_rounded)),
                size: 20,
                color: d.finished
                    ? Colors.green
                    : (cancelled
                        ? T.color(scheme.onSurface, TextTier.low,
                            brightness: scheme.brightness)
                        : (failed ? Colors.red : Colors.orange)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.book.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                  const SizedBox(height: 4),
                  Text(d.chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness))),
                  if (!d.finished) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: (failed || cancelled)
                                  ? null
                                  : (d.total > 0 ? d.done / d.total : 0),
                              minHeight: 4,
                              backgroundColor:
                                  T.color(scheme.onSurface, TextTier.hairline,
                                      brightness: scheme.brightness),
                              valueColor: failed
                                  ? AlwaysStoppedAnimation(Colors.red
                                      .withValues(alpha: 0.6))
                                  : (cancelled
                                      ? AlwaysStoppedAnimation(
                                          T.color(scheme.onSurface,
                                              TextTier.low,
                                              brightness: scheme.brightness))
                                      : AlwaysStoppedAnimation(scheme.primary)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                            cancelled
                                ? '已取消'
                                : failed
                                ? (d.error ?? '下载失败')
                                : '${d.done}/${d.total}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                                color: failed
                                    ? Colors.red
                                    : T.color(scheme.onSurface,
                                        TextTier.low,
                                        brightness: scheme.brightness))),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (!d.finished)
              IconButton(
                icon: Icon(Icons.close_rounded,
                    color: scheme.primary.withValues(alpha: 0.8)),
                tooltip: '取消下载',
                onPressed: () {
                  DownloadManager.cancelTask(d.localKey);
                  AppToast.info(context, '已请求取消该下载', duration: const Duration(seconds: 1));
                },
              ),
            if (!d.finished)
              IconButton(
                icon: Icon(Icons.refresh_rounded,
                    color: scheme.primary.withValues(alpha: 0.8)),
                tooltip: '重试',
                onPressed: () => widget.onRetryManga(d),
              ),
            IconButton(
              icon: Icon(Icons.close_rounded,
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness)),
              tooltip: '删除',
              onPressed: () => widget.onRemoveManga(d),
            ),
          ],
        ),
      ),
    );
  }

  /// 漫画下载卡长按菜单：删除单话 / 删除该书全部下载（按 book 聚合）。
  void _showMangaCardMenu(BuildContext context, DownloadRecord d) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, size: 20),
              title: Text('删除本话「${d.chapterTitle}」',
                  style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                widget.onRemoveManga(d);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined, size: 20),
              title: Text('删除《${d.book.name}》全部下载',
                  style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                widget.onRemoveMangaBook(d.book);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 动漫下载卡长按菜单：删除单集 / 删除该番剧全部下载（按 title 聚合）。
  void _showAnimeCardMenu(BuildContext context, VideoDownloadTask t) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, size: 20),
              title: Text('删除第 ${t.episode} 集「${t.title}」',
                  style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                widget.onRemoveAnime(t);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined, size: 20),
              title: Text('删除《${t.title}》全部下载',
                  style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                widget.onRemoveAnimeTitle(t);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _animeDownloadCard(
      BuildContext context, ColorScheme scheme, VideoDownloadTask t) {    final text = Theme.of(context).textTheme;
    final hasFile = !kIsWeb &&
        t.localPath != null &&
        File(t.localPath!).existsSync();
    // 三态区分（与漫画卡片同构，取消≠失败）：
    // - done + 文件在      → 完成（蓝/绿，可播放）
    // - done + 文件缺失    → 文件缺失（灰，可删除重下）
    // - failed             → 失败（红，显示原因 + 可重试）
    // - canceled           → 已取消（中性灰，可重新下载）
    // - downloading        → 进行中（橙，进度条实时走动）
    final failed = t.state == 'failed';
    final canceled = t.state == 'canceled';
    final missing = t.state == 'done' && !hasFile;
    final (icon, color, bg) = t.state == 'done'
        ? (missing
            ? (Icons.help_outline_rounded,
                T.color(scheme.onSurface, TextTier.low,
                    brightness: scheme.brightness),
                scheme.onSurface.withValues(alpha: 0.08))
            : (Icons.play_circle_outline, scheme.primary,
                scheme.primary.withValues(alpha: 0.12)))
        : failed
            ? (Icons.error_outline_rounded, Colors.red,
                Colors.red.withValues(alpha: 0.1))
            : canceled
                ? (Icons.stop_circle_outlined,
                    T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                    scheme.onSurface.withValues(alpha: 0.08))
                : (Icons.downloading_rounded, Colors.orange,
                    Colors.orange.withValues(alpha: 0.1));
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(R.card),
        border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness)),
      ),
      child: InkWell(
        onTap: () => widget.onOpenAnime(t),
        onLongPress: () => _showAnimeCardMenu(context, t),
        borderRadius: BorderRadius.circular(R.card),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                  const SizedBox(height: 4),
                  Text(
                      missing
                          ? '第 ${t.episode} 集 · 文件缺失'
                          : failed
                              ? '第 ${t.episode} 集：${t.error ?? '下载失败'}'
                              : canceled
                                  ? '第 ${t.episode} 集 · 已取消'
                                  : '第 ${t.episode} 集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                          color: failed
                              ? Colors.red
                              : T.color(scheme.onSurface, TextTier.low,
                                  brightness: scheme.brightness))),
                  if (t.state == 'downloading') ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: t.progress,
                              minHeight: 4,
                              backgroundColor:
                                  T.color(scheme.onSurface, TextTier.hairline,
                                      brightness: scheme.brightness),
                              valueColor:
                                  AlwaysStoppedAnimation(scheme.primary),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                            t.totalBytes > 0
                                ? '${(t.progress * 100).round()}%'
                                : '${t.segmentsDone}/${t.segmentsTotal}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                                color: T.color(scheme.onSurface,
                                    TextTier.low,
                                    brightness: scheme.brightness))),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (failed || canceled || missing)
              IconButton(
                icon: Icon(Icons.refresh_rounded,
                    color: scheme.primary.withValues(alpha: 0.8)),
                tooltip: '重新下载',
                onPressed: () => widget.onRetryAnime(t),
              ),
            IconButton(
              icon: Icon(Icons.close_rounded,
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness)),
              tooltip: '删除',
              onPressed: () => widget.onRemoveAnime(t),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分区标题行（与 bookshelf_page 同款：图标 + 标题 + 数量徽标 + 清空/尾随）。
/// 本文件为独立库，_TabEmpty/_sectionHeader 无法跨库共享私有符号，按原样
/// 保留在本文件内（视觉与原实现一致）。
class _TabEmpty extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? subtitle;
  const _TabEmpty({required this.icon, required this.text, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 渐变圆环 + 内圈图标：比单一浅色圆更有质感
          Container(
            width: 88,
            height: 88,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: isDark ? 0.22 : 0.16),
                  scheme.primary.withValues(alpha: 0.03),
                ],
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: isDark ? 0.16 : 0.10),
              ),
              child: Icon(icon, size: 36, color: scheme.primary),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.5,
                      color: T.color(scheme.onSurface, TextTier.disabled,
                          brightness: scheme.brightness),
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
