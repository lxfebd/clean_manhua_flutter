part of 'bookshelf_page.dart';

// ─── 子组件 ──────────────────────────────────────────────────────────────

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
              gradient: _BookshelfStyleDecorations.tabEmptyGradient(
                context,
                schemePrimary: scheme.primary,
                isDark: isDark,
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

/// 书架页各装饰位点的风格分支。极简分支严格保持既有观感，小米/苹果仅
/// 切装饰；不动布局/尺寸/热区/字体。
///
/// 设计要点：
/// - [cardRadius]/[coverRadius]/[sheetRadius]/[topSheetShape]/[cardDecoration]：
///   四个卡片 + _ShelfCard 封面 + BottomSheet 上圆角统一走这里。
/// - 极简分支直接返回既有字面量（R.card=12 / kCoverRadius=10 / 20），
///   与改造前逐字节等同，回归面为零。
/// - 小米：使用 StyleTokens 大圆角 + 品牌渐变 + 彩色浮起阴影，封面用超椭圆。
/// - 苹果：使用 StyleTokens 圆角 + 细分割线（0.5px @ alpha 0.4）。
abstract final class _BookshelfStyleDecorations {
  /// 卡片圆角：极简锁 [R.card]=12（与既有实现一致），其余走 StyleTokens。
  static double cardRadius(BuildContext context) =>
      context.uiStyle == UIStyle.minimalist
          ? R.card
          : R.of(R.card, style: context.uiStyle);

  /// 卡片装饰：圆角 + 描边 + 阴影。极简分支严格保持既有观感。
  /// - 极简：R.card 圆角 + Border.all(hairline = onSurface @ alpha 0.08) + 无阴影。
  ///   与改造前逐字节等同（不通过 StyleTokens 中转，因为 StyleTokens 极简描边色
  ///   是 outlineVariant 而非 onSurface.withAlpha(8)，虽然视觉差 <4/255，
  ///   但为严守「回归面为零」，极简分支直接返回原值）。
  /// - 小米：大圆角 + 无描边 + 彩色浮起阴影（StyleTokens）。
  /// - 苹果：R.cardApple 圆角 + 0.5px outlineVariant @ alpha 0.4 细分割线。
  static BoxDecoration cardDecoration(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    final r = cardRadius(context);
    final brightness = Theme.of(context).brightness;
    BoxDecoration decoration;
    if (style == UIStyle.minimalist) {
      // 极简：严格等同既有实现
      decoration = BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(
          color: T.color(scheme.onSurface, TextTier.hairline,
              brightness: brightness),
        ),
      );
    } else {
      final side = StyleTokens.cardBorder(context);
      final shadows = StyleTokens.cardShadow(context);
      decoration = BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(r),
        border: side == null ? null : Border.fromBorderSide(side),
        boxShadow: shadows,
      );
    }
    return decoration;
  }

  /// _ShelfCard 网格封面圆角：极简保持 kCoverRadius=10；小米/苹果走 cardRadius。
  static double coverRadius(BuildContext context) =>
      context.uiStyle == UIStyle.minimalist
          ? kCoverRadius
          : R.of(R.card, style: context.uiStyle);

  /// BottomSheet 上圆角：极简锁 20（既有值），其余走 StyleTokens.sheetRadius。
  static double sheetRadius(BuildContext context) =>
      context.uiStyle == UIStyle.minimalist
          ? 20.0
          : R.of(R.sheet, style: context.uiStyle);

  /// BottomSheet 上圆角形状（不可 const：内部依赖 context 走风格分支）。
  static RoundedRectangleBorder topSheetShape(BuildContext context) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(sheetRadius(context))),
      );

  /// _TabEmpty 渐变：小米使用品牌渐变（StyleTokens.cardGradient），
  /// 极简/苹果保持现状自研渐变。
  static Gradient? tabEmptyGradient(BuildContext context,
      {required Color schemePrimary, required bool isDark}) {
    if (context.uiStyle == UIStyle.xiaomi) {
      return StyleTokens.cardGradient(context);
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        schemePrimary.withValues(alpha: isDark ? 0.22 : 0.16),
        schemePrimary.withValues(alpha: 0.03),
      ],
    );
  }
}

class _ReadingCard extends StatelessWidget {
  final HistoryEntry history;
  final double progress;

  /// 是否显示进度条：小说历史无「页码/章内进度」语义，_progressOf 只会
  /// 落到 0.3 兜底假进度，不渲染避免误导。
  final bool showProgress;
  final VoidCallback onTap;

  /// 长按删除单条历史（最近阅读列表用；null = 不支持长按删除）。
  final VoidCallback? onLongPressDelete;
  const _ReadingCard({
    required this.history,
    required this.progress,
    this.showProgress = true,
    required this.onTap,
    this.onLongPressDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = history.book;
    return PressableScale(
      onTap: onTap,
      onLongPress: onLongPressDelete,
      scale: 0.98,
      focusable: true, // TV 遥控器 D-pad 焦点导航（书架卡片）
      child: Container(
        height: 80,
        decoration: _BookshelfStyleDecorations.cardDecoration(context),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            // 封面
            SizedBox(
              width: 56,
              height: double.infinity,
              child: (b.pic.isEmpty)
                  ? Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.book,
                        size: 22,
                        color: T.color(scheme.onSurface, TextTier.fill,
                            brightness: scheme.brightness),
                      ),
                    )
                  : CachedImage(b.pic, fit: BoxFit.cover, radius: 0),
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    history.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                        ),
                  ),
                  const SizedBox(height: 6),
                  // 进度条（小说无章内进度语义，不渲染避免 0.3 假进度）
                  if (showProgress)
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              StyleTokens.controlRadiusOr(context, 2),
                            ),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
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
                          '${(progress * 100).round()}%',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: T.color(scheme.onSurface, TextTier.disabled,
                                    brightness: scheme.brightness),
                              ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: T.color(scheme.onSurface, TextTier.disabled,
                  brightness: scheme.brightness),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _ShelfCard extends StatelessWidget {
  final ComicDetail item;
  final bool editing;
  final VoidCallback onTap;

  /// 长按操作菜单（非编辑态）：查看详情/移入分类/编辑标签/移出书架。
  /// null = 不支持长按（编辑态下点选删除语义优先）。
  final VoidCallback? onLongPress;

  /// 续读位置副标题（如「续读 第3话 · 第5页」）；空则不显示。
  /// 数据来自书架 State 的 `_recent`（历史记录聚合，按 book.key 查找）。
  final String? subtitle;
  const _ShelfCard({
    required this.item,
    required this.editing,
    required this.onTap,
    this.onLongPress,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasUpdate = BookshelfStore.hasUpdate(
      item.sourceId ?? BookshelfStore.sourceIdOf(item.id) ?? '',
      item.id,
      item.chapters.length,
    );
    // 封面剪裁：极简保持既有 ClipRRect(kCoverRadius=10)；
    // 小米用超椭圆（SquircleClipper）+ 大圆角；苹果用 cardRadius（12）。
    final style = context.uiStyle;
    final r = _BookshelfStyleDecorations.coverRadius(context);
    final cover = Stack(
      fit: StackFit.expand,
      children: [
        (item.pic?.isEmpty ?? true)
            ? Container(
                color: scheme.surfaceContainerHighest,
                child: Icon(Icons.image,
                    size: 32,
                    color: scheme.onSurface.withValues(alpha: 0.15)),
              )
            : CachedImage(item.pic ?? '',
                fit: BoxFit.cover,
                radius: 0),
        if (editing)
          Positioned.fill(
            child: Container(
              color: Colors.black45,
              child: Center(
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.error,
                  ),
                  child: const Icon(Icons.close,
                      size: 18, color: Colors.white),
                ),
              ),
            ),
          ),
        if (hasUpdate && !editing)
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: Text(
                '更新',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
              ),
            ),
          ),
      ],
    );
    final coverClipped = style == UIStyle.xiaomi
        ? ClipPath(
            clipper: SquircleClipper(radius: r),
            child: cover,
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(r),
            child: cover,
          );
    return PressableScale(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.96,
      focusable: true, // TV 遥控器 D-pad 焦点导航（书架条目卡）
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: coverClipped),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VideoRecordCard extends StatelessWidget {
  final VideoRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _VideoRecordCard({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });

  /// 副标题：集数 + 播放位置。总集数已知时显示「第 N / M 集」；
  /// seconds 为 0 时只显示集数。
  static String _subtitleOf(VideoRecord r) {
    final ep = r.totalEpisodes > 0
        ? '第 ${r.episode} / ${r.totalEpisodes} 集'
        : '第 ${r.episode} 集';
    final s = r.seconds;
    if (s <= 0) return ep;
    final h = s ~/ 3600;
    final mm = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    final t = h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
    return '$ep · 播放至 $t';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      focusable: true, // TV 遥控器 D-pad 焦点导航（书架卡片）
      child: Container(
        height: 80,
        decoration: _BookshelfStyleDecorations.cardDecoration(context),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            SizedBox(
              width: 56,
              height: double.infinity,
              child: (record.cover?.isEmpty ?? true)
                  ? Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.movie,
                          size: 22,
                          color: T.color(scheme.onSurface, TextTier.fill,
                              brightness: scheme.brightness)),
                    )
                  : CachedImage(record.cover ?? '',
                      fit: BoxFit.cover,
                      radius: 0),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _subtitleOf(record),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除',
              icon: Icon(Icons.delete_outline,
                  size: 18,
                  color: scheme.error.withValues(alpha: 0.7)),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 书签卡片：封面 + 书名 + 章节/页码 + 收藏时间。
class _BookmarkCard extends StatelessWidget {
  final ComicBookmark mark;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _BookmarkCard({
    required this.mark,
    required this.onTap,
    required this.onDelete,
  });

  /// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 具体日期。
  static String _timeText(int ts) {
    if (ts <= 0) return '';
    final diff = DateTime.now().millisecondsSinceEpoch - ts;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
    if (diff < 30 * 24 * 60 * 60 * 1000) return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final y = d.year;
    final m = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$y-$m-$dd';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = mark.book;
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      focusable: true, // TV 遥控器 D-pad 焦点导航（书架卡片）
      child: Container(
        height: 80,
        decoration: _BookshelfStyleDecorations.cardDecoration(context),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            // 封面
            SizedBox(
              width: 56,
              height: double.infinity,
              child: (b.pic.isEmpty)
                  ? Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.book,
                        size: 22,
                        color: T.color(scheme.onSurface, TextTier.fill,
                            brightness: scheme.brightness),
                      ),
                    )
                  : CachedImage(b.pic, fit: BoxFit.cover, radius: 0),
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mark.pageIndex > 0
                        ? '${mark.chapterTitle} · 第 ${mark.pageIndex + 1} 页'
                        : mark.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _timeText(mark.timestamp),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.disabled,
                              brightness: scheme.brightness),
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除',
              icon: Icon(Icons.delete_outline,
                  size: 18,
                  color: scheme.error.withValues(alpha: 0.7)),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 下载 Tab 隔离壳（R1-3）：订阅高频下载 provider（漫画 300ms 合并窗口
/// 流式重读 / 动漫每次进度 tick 推送），把实时列表以构造参数喂给纯渲染
/// [BookshelfDownloadView]。进度变化只重建本壳与视图子树，书架主网格
/// 不再每 300ms 整页 setState。provider 未就绪时用页面首读快照兜底
/// （首帧无空闪烁）。回调（清空/重试/删除/打开）透传给页面层实现。
class _DownloadsTab extends ConsumerWidget {
  final ColorScheme scheme;
  final List<DownloadRecord> initialMangaDownloads;
  final List<VideoDownloadTask> initialAnimeDownloads;
  final bool retryingAll;
  final Future<void> Function() onClearManga;
  final Future<void> Function() onRetryAllManga;
  final void Function(Bookmark book) onOpenMangaDetail;
  final Future<void> Function(DownloadRecord record) onRetryManga;
  final void Function(DownloadRecord record) onRemoveManga;
  final Future<void> Function(Bookmark book) onRemoveMangaBook;
  final Future<void> Function() onClearAnime;
  final void Function(VideoDownloadTask task) onOpenAnime;
  final Future<void> Function(VideoDownloadTask task) onRetryAnime;
  final void Function(VideoDownloadTask task) onRemoveAnime;
  final Future<void> Function(VideoDownloadTask task) onRemoveAnimeTitle;

  const _DownloadsTab({
    required this.scheme,
    required this.initialMangaDownloads,
    required this.initialAnimeDownloads,
    required this.retryingAll,
    required this.onClearManga,
    required this.onRetryAllManga,
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manga =
        ref.watch(mangaDownloadsProvider).value ?? initialMangaDownloads;
    final anime =
        ref.watch(animeDownloadTasksProvider).value ?? initialAnimeDownloads;
    return BookshelfDownloadView(
      scheme: scheme,
      mangaDownloads: manga,
      animeDownloads: anime,
      retryingAll: retryingAll,
      onClearManga: onClearManga,
      onRetryAllManga: onRetryAllManga,
      onOpenMangaDetail: onOpenMangaDetail,
      onRetryManga: onRetryManga,
      onRemoveManga: onRemoveManga,
      onRemoveMangaBook: onRemoveMangaBook,
      onClearAnime: onClearAnime,
      onOpenAnime: onOpenAnime,
      onRetryAnime: onRetryAnime,
      onRemoveAnime: onRemoveAnime,
      onRemoveAnimeTitle: onRemoveAnimeTitle,
    );
  }
}
