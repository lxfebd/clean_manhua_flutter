import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../net/download_manager.dart';
import '../net/local_store.dart';
import '../net/video_download_manager.dart';
import 'responsive.dart';
import 'tokens.dart';
import 'widgets/app_toast.dart';

/// 书架「下载」Tab 视图：漫画章节下载 + 已下载动漫，集中在此管理
/// （下载本就属于「我的内容」，从工具箱挪到书架，工具箱回归纯工具）。
///
/// 纯渲染组件：列表数据与操作逻辑由 [BookshelfPageState] 通过构造参数传入
/// （含清空/重试/删除/打开详情等回调），自身不持有业务状态。
/// 手机/平板两套布局共用本组件（两处 slivers 调用点均返回本 Widget）。
///
/// 返回单个 Sliver（平板/手机外层 CustomScrollView 均已自带
/// RefreshIndicator + BouncingScrollPhysics）。此处严禁再内嵌
/// CustomScrollView / RefreshIndicator——它们都是 RenderBox，被塞进
/// slivers 列表会让 Viewport 收到非法子组件，直接触发
/// "RenderViewport expected a child of type RenderSliver but received a
/// child of type RenderErrorBox"（书架页崩溃根因）。
class BookshelfDownloadView extends StatelessWidget {
  const BookshelfDownloadView({
    super.key,
    required this.scheme,
    required this.mangaDownloads,
    required this.animeDownloads,
    required this.onClearManga,
    required this.onRetryAllManga,
    required this.onOpenMangaDetail,
    required this.onRetryManga,
    required this.onRemoveManga,
    required this.onClearAnime,
    required this.onOpenAnime,
    required this.onRetryAnime,
    required this.onRemoveAnime,
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

  /// 打开漫画详情页。
  final void Function(Bookmark book) onOpenMangaDetail;

  /// 重试单条漫画下载。
  final Future<void> Function(DownloadRecord record) onRetryManga;

  /// 删除单条漫画下载（含确认对话框）。
  final void Function(DownloadRecord record) onRemoveManga;

  /// 清空全部动漫下载（含确认对话框）。
  final Future<void> Function() onClearAnime;

  /// 打开本地动漫视频（或提示文件缺失）。
  final void Function(VideoDownloadTask task) onOpenAnime;

  /// 重新下载失败的动漫单集（重试走同一 start 入口恢复原任务）。
  final Future<void> Function(VideoDownloadTask task) onRetryAnime;

  /// 删除单条动漫下载（含确认对话框）。
  final void Function(VideoDownloadTask task) onRemoveAnime;

  /// 已失败（非进行中）的漫画下载任务：未完成且计数到齐（无法完成的重试
  /// 之后中断），与卡片失败样式判定一致。进行中的任务（done < total）不算，
  /// 避免「重试 N」虚高与对进行中任务重复启动下载。
  List<DownloadRecord> get _failedManga => mangaDownloads
      .where((d) => !d.finished && d.total > 0 && d.done >= d.total)
      .toList();

  @override
  Widget build(BuildContext context) {
    final totalManga = mangaDownloads.length;
    final totalAnime = animeDownloads.length;
    final bottomPad = Responsive.isExpanded(context) ? 24.0 : 110.0;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context), 8,
        Responsive.pagePadding(context), bottomPad),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, scheme, Icons.menu_book_rounded, '漫画下载',
                totalManga,
                mangaDownloads.isEmpty ? null : onClearManga,
                trailing: _failedManga.isEmpty
                    ? null
                    : TextButton.icon(
                        onPressed: onRetryAllManga,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: Text('重试 ${_failedManga.length}'),
                      )),
            const SizedBox(height: 8),
            if (totalManga == 0)
              const _TabEmpty(
                  icon: Icons.download_done_rounded,
                  text: '还没有漫画下载',
                  subtitle: '在阅读页点击缓存，即可离线观看')
            else
              ...mangaDownloads.map((d) => _mangaDownloadCard(context, scheme, d)),
            const SizedBox(height: 20),
            _sectionHeader(context, scheme,
                Icons.ondemand_video_rounded,
                '动漫下载',
                totalAnime,
                animeDownloads.isEmpty ? null : onClearAnime),
            const SizedBox(height: 8),
            if (totalAnime == 0)
              const _TabEmpty(
                  icon: Icons.video_library_outlined,
                  text: '还没有下载的动漫',
                  subtitle: '观看时点击缓存，即可离线观看')
            else
              ...animeDownloads.map((t) => _animeDownloadCard(context, scheme, t)),
          ],
        ),
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
        onTap: () => onOpenMangaDetail(d.book),
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
                onPressed: () => onRetryManga(d),
              ),
            IconButton(
              icon: Icon(Icons.close_rounded,
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness)),
              tooltip: '删除',
              onPressed: () => onRemoveManga(d),
            ),
          ],
        ),
      ),
    );
  }

  Widget _animeDownloadCard(
      BuildContext context, ColorScheme scheme, VideoDownloadTask t) {
    final text = Theme.of(context).textTheme;
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
        ? (Icons.play_circle_outline, scheme.primary,
            scheme.primary.withValues(alpha: 0.12))
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
        onTap: () => onOpenAnime(t),
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
                onPressed: () => onRetryAnime(t),
              ),
            IconButton(
              icon: Icon(Icons.close_rounded,
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness)),
              tooltip: '删除',
              onPressed: () => onRemoveAnime(t),
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
