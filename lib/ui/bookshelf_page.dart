import 'package:flutter/material.dart';
import 'dart:io';

import '../net/bookshelf_store.dart';
import '../net/download_manager.dart';
import '../net/video_download_manager.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'anime_player_page.dart';
import 'detail_page.dart';
import 'native_player_page.dart';
import 'responsive.dart';
import 'tokens.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

/// 书架页：跨源聚合，按时间倒序。错峰入场。
///
/// 平板布局（≥600dp）：
/// - 左侧：标签分类筛选（固定宽度 200dp）
/// - 右侧：内容列表/网格
///
/// 手机布局：
/// - 顶部：标签切换（横向滚动）
/// - 下方：内容列表/网格
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => BookshelfPageState();
}

class BookshelfPageState extends State<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  List<ComicDetail> _items = [];
  List<ComicDetail> _filtered = [];
  List<HistoryEntry> _recent = [];
  List<VideoRecord> _videos = [];
  // 下载（书架的「下载」Tab）：漫画章节下载 + 已下载完成的动漫。
  List<DownloadRecord> _mangaDownloads = [];
  List<VideoDownloadTask> _animeDownloads = [];
  int _tab = 0;
  bool _loading = true;
  bool _refreshing = false;
  bool _editing = false;
  String? _tagFilter;
  List<String> _allTags = [];
  int _updateCount = 0;
  bool _checkingUpdate = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    if (mounted) {
      setState(() =>
          _loading = _items.isEmpty && _recent.isEmpty && _videos.isEmpty);
    }
    try {
      final list = BookshelfStore.listAll();
      final hist = await LocalStore.history();
      final videos = await LocalStore.videoRecords();
      final dl = await LocalStore.downloads();
      final ani = VideoDownloadManager.instance.tasks
          .where((t) => t.state == 'done')
          .toList();
      if (mounted) {
        setState(() {
          _items = list;
          _filtered = _tagFilter == null
              ? list
              : list.where((d) {
                  final sid = BookshelfStore.sourceIdOf(d.id) ?? '';
                  return BookshelfStore.tagsOf(sid, d.id).contains(_tagFilter);
                }).toList();
          _allTags = BookshelfStore.allTags();
          _recent = hist;
          _videos = videos;
          _mangaDownloads = dl;
          _animeDownloads = ani;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _refreshing = true);
    await reload();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // 分栏布局：≥840dp（Expanded）才开左侧 200dp 筛选栏。
    // 600-839dp 时这个侧栏会吃掉约 1/3 屏宽，内容区过窄，仍沿用顶部标签。
    if (Responsive.isExpanded(context)) {
      return _buildTabletLayout(scheme);
    }

    // 手机：传统布局
    return _buildPhoneLayout(scheme);
  }

  /// 平板布局（≥840dp）：无二级侧栏，Tab 与标签筛选置顶横向展示。
  /// 双导航已收敛——主导航由 main_shell 的 NavigationRail 承担，
  /// 页内仅保留横向 Tab + 标签筛选（功能与原左侧二级栏一致）。
  /// 桌面端升级为 Fluent 页头（26px 大标题 + 命令栏）。
  Widget _buildTabletLayout(ColorScheme scheme) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    // 命令栏按钮：编辑（仅收藏 Tab）/ 检查更新 / 刷新——桌面与平板共用，
    // 桌面放页头右侧，平板放原 21px 标题行右侧。
    final commandButtons = <Widget>[
      if (_tab == 1 && _items.isNotEmpty)
        TextButton(
          onPressed: () => setState(() => _editing = !_editing),
          child: Text(
            _editing ? '完成' : '编辑',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight:
                      _editing ? FontWeight.w700 : FontWeight.w500,
                  color: _editing
                      ? scheme.primary
                      : T.color(scheme.onSurface, TextTier.mid,
                          brightness: scheme.brightness),
                ),
          ),
        ),
      IconButton(
        tooltip: '检查更新',
        onPressed: _checkingUpdate ? null : _checkUpdates,
        icon: _checkingUpdate
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.system_update_alt_rounded,
                size: 20,
                color: _updateCount > 0
                    ? scheme.error
                    : T.color(scheme.onSurface, TextTier.mid,
                        brightness: scheme.brightness),
              ),
      ),
      IconButton(
        tooltip: '刷新',
        onPressed: _refreshing ? null : _onRefresh,
        icon: AnimatedRotation(
          turns: _refreshing ? 1 : 0,
          duration: const Duration(milliseconds: 900),
          child: Icon(
            Icons.refresh_rounded,
            size: 22,
            color: T.color(scheme.onSurface, TextTier.mid,
                brightness: scheme.brightness),
          ),
        ),
      ),
    ];
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 页头：桌面端 26px 大标题 + 命令栏；平板保持原 21px 标题行
            if (isDesktop)
              DesktopPageHeader(
                title: '书架',
                subtitle:
                    '${_tabName()} · 共 ${_items.length} 部收藏',
                actions: commandButtons,
              )
            else
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Responsive.pagePadding(context), 12,
                    Responsive.pagePadding(context), 4),
                child: Row(
                  children: [
                    Text(
                      '书架',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: scheme.onSurface,
                          ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_items.length} 部',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: T.color(scheme.onSurface, TextTier.disabled,
                                brightness: scheme.brightness),
                          ),
                    ),
                    const Spacer(),
                    ...commandButtons,
                  ],
                ),
              ),
            // 横向 Tab（最近阅读/我的收藏/动画记录/下载）
            _tabBar(),
            // 标签筛选（仅收藏 Tab）
            if (_tab == 1 && _allTags.isNotEmpty) _tagChips(),
            Expanded(child: _buildTabletContent(scheme)),
          ],
        ),
      ),
    );
  }

  String _tabName() {
    switch (_tab) {
      case 0:
        return '最近阅读';
      case 1:
        return '我的收藏';
      case 2:
        return '动画记录';
      default:
        return '下载';
    }
  }

  /// 平板右侧内容区。桌面端去掉下拉刷新（桌面命令栏已有刷新按钮），
  /// 物理改 clamping（Windows 无橡皮筋）。
  Widget _buildTabletContent(ColorScheme scheme) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    final scroll = CustomScrollView(
      physics: isDesktop
          ? const AlwaysScrollableScrollPhysics(
              parent: kDesktopScrollPhysics)
          : const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
      slivers: [
        // 顶部标题已由 _buildTabletLayout 统一提供，此处不再重复渲染。

        // 内容
        if (_tab == 0)
          _buildRecentList(scheme)
        else if (_tab == 1)
          _buildShelfGrid(scheme)
        else if (_tab == 2)
          _buildVideoList(scheme)
        else
          _buildDownloadsView(scheme),
      ],
    );
    if (isDesktop) return scroll;
    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: Theme.of(context).colorScheme.primary,
      child: scroll,
    );
  }

  /// 最近阅读列表
  Widget _buildRecentList(ColorScheme scheme) {
    if (_recent.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 120),
          child: _TabEmpty(
            icon: Icons.history_rounded,
            text: '最近还没有阅读记录',
            subtitle: '去首页或发现页逛逛，读过的漫画会自动出现在这里',
          ),
        ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        8,
        Responsive.pagePadding(context),
        110,
      ),
      sliver: SliverList.separated(
        itemCount: _recent.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        // 平板/大屏内容由主框架 MaxWidthContainer 统一收口（1200/1400），
        // 此处不再叠加 600 二级限宽，避免两级限宽叠加冲突。
        itemBuilder: (c, i) => _ReadingCard(
          history: _recent[i],
          progress: _progressOf(_recent[i]),
          onTap: () => _openFromHistory(_recent[i]),
        ),
      ),
    );
  }

  /// 书架网格
  Widget _buildShelfGrid(ColorScheme scheme) {
    if (_items.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 120),
          child: _TabEmpty(
            icon: Icons.bookmark_outline_rounded,
            text: '书架还是空的，去首页收藏几部吧',
            subtitle: '在作品详情页点击收藏，就能在书架里随时找到',
          ),
        ),
      );
    }
    if (_filtered.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 120),
          child: _TabEmpty(
            icon: Icons.filter_alt_off_rounded,
            text: '没有匹配「$_tagFilter」标签的作品',
            subtitle: '试试切换到其他标签分类',
          ),
        ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        8,
        Responsive.pagePadding(context),
        110,
      ),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          // 列数按容器实际宽度（crossAxisExtent）推导，而非全窗宽：
          // 平板布局 rail + 左侧分类栏已吃掉宽度，若按全窗宽算会把卡片挤得过小。
          // 每列约 118dp，上限与 comicGridColumns 一致（最多 10）。
          final contentW = constraints.crossAxisExtent;
          final cols = (contentW / 118).floor().clamp(2, 10);
          final isDesktop = DesktopUi.isDesktopPlatform;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: Responsive.gridSpacing(context),
              crossAxisSpacing: Responsive.gridSpacing(context),
              childAspectRatio: isDesktop ? 0.68 : 0.6,
            ),
            delegate: SliverChildBuilderDelegate(
              (c, i) {
                final item = _filtered[i];
                return RepaintBoundary(
                  child: FadeSlideIn(
                    delay: Duration(milliseconds: 50 * (i % 12)),
                    offset: 16,
                    child: ContextMenuWrapper(
                      items: () => _shelfCardMenu(item),
                      child: _ShelfCard(
                        item: item,
                        editing: _editing,
                        onTap: () => _editing
                            ? _showCardAction(item)
                            : _open(item),
                      ),
                    ),
                  ),
                );
              },
              childCount: _filtered.length,
            ),
          );
        },
      ),
    );
  }

  /// 视频记录列表
  Widget _buildVideoList(ColorScheme scheme) {
    if (_videos.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 120),
          child: _TabEmpty(
            icon: Icons.ondemand_video_rounded,
            text: '还没有动画观看记录',
            subtitle: '在动漫频道看过的内容会自动出现在这里',
          ),
        ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        8,
        Responsive.pagePadding(context),
        110,
      ),
      sliver: SliverList.separated(
        itemCount: _videos.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        // 平板/大屏内容由主框架 MaxWidthContainer 统一收口（1200/1400），
        // 此处不再叠加 600 二级限宽，避免两级限宽叠加冲突。
        itemBuilder: (c, i) => _VideoRecordCard(
          record: _videos[i],
          onTap: () => _openVideoRecord(_videos[i]),
          onDelete: () => _deleteVideoRecord(_videos[i]),
        ),
      ),
    );
  }

  /// 下载 Tab：漫画章节下载 + 已下载动漫，集中在此管理
  /// （下载本就属于「我的内容」，从工具箱挪到书架，工具箱回归纯工具）。
  Widget _buildDownloadsView(ColorScheme scheme) {
    final totalManga = _mangaDownloads.length;
    final totalAnime = _animeDownloads.length;
    // 下载 Tab 返回单个 Sliver（平板/手机外层 CustomScrollView 均已自带
    // RefreshIndicator + BouncingScrollPhysics）。此处严禁再内嵌
    // CustomScrollView / RefreshIndicator——它们都是 RenderBox，被塞进
    // slivers 列表会让 Viewport 收到非法子组件，直接触发
    // "RenderViewport expected a child of type RenderSliver but received a
    // child of type RenderErrorBox"（书架页崩溃根因）。
    final bottomPad = Responsive.isExpanded(context) ? 24.0 : 110.0;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context), 8,
        Responsive.pagePadding(context), bottomPad),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(scheme, Icons.menu_book_rounded, '漫画下载',
                totalManga,
                _mangaDownloads.isEmpty ? null : _confirmClearMangaAll),
            const SizedBox(height: 8),
            if (totalManga == 0)
              const _TabEmpty(
                  icon: Icons.download_done_rounded,
                  text: '还没有漫画下载',
                  subtitle: '在阅读页点击缓存，即可离线观看')
            else
              ..._mangaDownloads.map((d) => _mangaDownloadCard(scheme, d)),
            const SizedBox(height: 20),
            _sectionHeader(
                scheme,
                Icons.ondemand_video_rounded,
                '动漫下载',
                totalAnime,
                _animeDownloads.isEmpty ? null : _confirmClearAnimeAll),
            const SizedBox(height: 8),
            if (totalAnime == 0)
              const _TabEmpty(
                  icon: Icons.video_library_outlined,
                  text: '还没有下载的动漫',
                  subtitle: '观看时点击缓存，即可离线观看')
            else
              ..._animeDownloads.map((t) => _animeDownloadCard(scheme, t)),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(ColorScheme scheme, IconData icon, String title,
      int count, VoidCallback? onClear) {
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
        if (onClear != null)
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: const Text('清空'),
          ),
      ],
    );
  }

  Widget _mangaDownloadCard(ColorScheme scheme, DownloadRecord d) {
    final text = Theme.of(context).textTheme;
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
        onTap: () => _openDownloadDetail(d.book),
        borderRadius: BorderRadius.circular(R.card),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: d.finished
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: Icon(
                d.finished
                    ? Icons.check_circle_outline
                    : Icons.downloading_rounded,
                size: 20,
                color: d.finished ? Colors.green : Colors.orange,
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
                              value: d.total > 0 ? d.done / d.total : 0,
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
                        Text('${d.done}/${d.total}',
                            style: text.labelSmall?.copyWith(
                                color: T.color(scheme.onSurface, TextTier.low,
                                    brightness: scheme.brightness))),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (!d.finished)
              IconButton(
                icon: Icon(Icons.refresh_rounded,
                    color: scheme.primary.withValues(alpha: 0.8)),
                tooltip: '重试',
                onPressed: () => _retryMangaDownload(d),
              ),
            IconButton(
              icon: Icon(Icons.close_rounded,
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness)),
              tooltip: '删除',
              onPressed: () => _confirmRemoveManga(d),
            ),
          ],
        ),
      ),
    );
  }

  Widget _animeDownloadCard(ColorScheme scheme, VideoDownloadTask t) {
    final text = Theme.of(context).textTheme;
    final hasFile =
        t.localPath != null && File(t.localPath!).existsSync();
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
        onTap: () => _openAnimeDownload(t),
        borderRadius: BorderRadius.circular(R.card),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: hasFile
                    ? scheme.primary.withValues(alpha: 0.12)
                    : Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: Icon(
                hasFile ? Icons.play_circle_outline : Icons.downloading_rounded,
                size: 20,
                color: hasFile ? scheme.primary : Colors.orange,
              ),
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
                  Text('第 ${t.episode} 集${hasFile ? '' : ' · 文件缺失'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness))),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close_rounded,
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness)),
              tooltip: '删除',
              onPressed: () => _confirmRemoveAnime(t),
            ),
          ],
        ),
      ),
    );
  }

  void _openDownloadDetail(Bookmark b) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: b.sourceId,
          comicId: b.comicId,
          name: b.name,
          pic: b.pic,
        ),
      ),
    );
  }

  Future<void> _retryMangaDownload(DownloadRecord d) async {
    try {
      final source = SourceManager.byId(d.book.sourceId);
      final urls = await source.chapterPics(d.chapterId);
      await DownloadManager.retry(
          '${d.book.sourceId}::${d.book.comicId}', d.chapterId, d.chapterTitle, urls);
      await reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已重新加入下载')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重试失败：$e')));
    }
  }

  Future<void> _removeMangaDownload(DownloadRecord d) async {
    await LocalStore.removeDownloadFiles(d);
    await LocalStore.removeDownload(d.key);
    await reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已删除下载记录')));
  }

  void _confirmRemoveManga(DownloadRecord d) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('删除下载'),
        content:
            Text('确定删除「${d.book.name} · ${d.chapterTitle}」的下载文件？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _removeMangaDownload(d);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearMangaAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('清空漫画下载'),
        content: const Text('确定清空全部漫画下载记录和文件？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      for (final d in _mangaDownloads) {
        try {
          await LocalStore.removeDownloadFiles(d);
        } catch (_) {}
      }
      await LocalStore.clearDownloads();
      await reload();
    }
  }

  void _openAnimeDownload(VideoDownloadTask t) {
    final p = t.localPath;
    if (p == null || !File(p).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到本地文件，可能无法离线播放')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NativePlayerPage(
          url: 'file://$p',
          title: t.title,
          sourceId: t.sourceId,
          videoId: t.videoId,
        ),
      ),
    );
  }

  Future<void> _removeAnimeDownload(VideoDownloadTask t) async {
    await VideoDownloadManager.instance.remove(t.key);
    await reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已删除动漫下载')));
  }

  void _confirmRemoveAnime(VideoDownloadTask t) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('删除下载'),
        content: Text('确定删除「${t.title} · 第${t.episode}集」的下载文件？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _removeAnimeDownload(t);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearAnimeAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('清空动漫下载'),
        content: const Text('确定删除全部已下载的动漫文件？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final keys = _animeDownloads.map((t) => t.key).toList();
      for (final k in keys) {
        await VideoDownloadManager.instance.remove(k);
      }
      await reload();
    }
  }

  /// 手机布局
  Widget _buildPhoneLayout(ColorScheme scheme) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 标题栏
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Responsive.pagePadding(context), 14,
                  Responsive.pagePadding(context), 8),
              child: Row(
                children: [
                  Text(
                    '书架',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          color: scheme.onSurface,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_items.length} 部',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.disabled,
                              brightness: scheme.brightness),
                        ),
                  ),
                  if (_updateCount > 0)
                    GestureDetector(
                      onTap: _checkUpdates,
                      child: Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(R.control),
                        ),
                        child: Text(
                          '$_updateCount 更新',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: scheme.error,
                              ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (_items.isNotEmpty)
                    TextButton(
                      onPressed: () =>
                          setState(() => _editing = !_editing),
                      child: Text(
                        _editing ? '完成' : '编辑',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: _editing
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: _editing
                                  ? scheme.primary
                                  : T.color(scheme.onSurface, TextTier.mid,
                                      brightness: scheme.brightness),
                            ),
                      ),
                    ),
                  // 常驻「检查更新」入口：旧实现只在 _updateCount>0 时渲染角标，
                  // 导致永远点不到。现在无角标也可主动检查。
                  IconButton(
                    tooltip: '检查更新',
                    onPressed: _checkingUpdate ? null : _checkUpdates,
                    icon: _checkingUpdate
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.system_update_alt_rounded,
                            size: 20,
                            color: _updateCount > 0
                                ? scheme.error
                                : T.color(scheme.onSurface, TextTier.mid,
                                    brightness: scheme.brightness),
                          ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _refreshing ? null : _onRefresh,
                    icon: AnimatedRotation(
                      turns: _refreshing ? 1 : 0,
                      duration: const Duration(milliseconds: 900),
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 22,
                        color: T.color(scheme.onSurface, TextTier.mid,
                            brightness: scheme.brightness),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildPhoneContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoneContent() {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: scheme.primary,
      child: CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics()),
      slivers: [
        SliverToBoxAdapter(child: _tabBar()),
        if (_tab == 0)
          if (_recent.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: _TabEmpty(
                  icon: Icons.history_rounded,
                  text: '最近还没有阅读记录',
                  subtitle: '去首页或发现页逛逛，读过的漫画会自动出现在这里',
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  Responsive.pagePadding(context), 8,
                  Responsive.pagePadding(context), 8),
              sliver: SliverList.separated(
                itemCount: _getRecentCount(),
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (c, i) => Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: _ReadingCard(
                      history: _recent[i],
                      progress: _progressOf(_recent[i]),
                      onTap: () => _openFromHistory(_recent[i]),
                    ),
                  ),
                ),
              ),
            )
        else if (_tab == 1) ...[
          if (_items.isNotEmpty && _allTags.isNotEmpty)
            SliverToBoxAdapter(child: _tagChips()),
          if (_items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: _TabEmpty(
                  icon: Icons.bookmark_outline_rounded,
                  text: '书架还是空的，去首页收藏几部吧',
                  subtitle: '在作品详情页点击收藏，就能在书架里随时找到',
                ),
              ),
            )
          else if (_filtered.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 80),
                child: _TabEmpty(
                  icon: Icons.filter_alt_off_rounded,
                  text: '没有匹配「$_tagFilter」标签的作品',
                  subtitle: '试试切换到其他标签分类',
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 8,
                  Responsive.pagePadding(context), 110),
              sliver: SliverGrid(
                gridDelegate:
                    SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: Responsive.comicGridColumns(context),
                  mainAxisSpacing: Responsive.gridSpacing(context),
                  crossAxisSpacing: Responsive.gridSpacing(context),
                  childAspectRatio: 0.6,
                ),
                delegate: SliverChildBuilderDelegate(
                  (c, i) {
                    final item = _filtered[i];
                    return RepaintBoundary(
                      child: FadeSlideIn(
                        delay: Duration(milliseconds: 50 * (i % 12)),
                        offset: 16,
                        child: _ShelfCard(
                          item: item,
                          editing: _editing,
                          onTap: () => _editing
                              ? _showCardAction(item)
                              : _open(item),
                        ),
                      ),
                    );
                  },
                  childCount: _filtered.length,
                ),
              ),
            ),
        ]
        else if (_videos.isEmpty && _tab == 2)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 80),
              child: _TabEmpty(
                icon: Icons.ondemand_video_rounded,
                text: '还没有动画观看记录',
                subtitle: '在动漫频道看过的内容会自动出现在这里',
              ),
            ),
          )
        else if (_tab == 2)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
                Responsive.pagePadding(context), 8,
                Responsive.pagePadding(context), 110),
            sliver: SliverList.separated(
              itemCount: _videos.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (c, i) => _VideoRecordCard(
                record: _videos[i],
                onTap: () => _openVideoRecord(_videos[i]),
                onDelete: () => _deleteVideoRecord(_videos[i]),
              ),
            ),
          )
        else
          _buildDownloadsView(scheme),
      ],
      ),
    );
  }

  /// 由书架 chapters + 历史页码计算阅读进度
  double _progressOf(HistoryEntry h) {
    if (h.hasPage && h.chapterTotalPages > 0 && h.pageIndex >= 0) {
      return ((h.pageIndex + 1) / h.chapterTotalPages).clamp(0.0, 1.0);
    }
    for (final d in _items) {
      if (d.id != h.book.comicId) continue;
      if (d.chapters.isEmpty) return 0;
      final idx = d.chapters.indexWhere((c) => c.id == h.chapterId);
      if (idx < 0) return 0.3;
      return ((idx + 1) / d.chapters.length).clamp(0.0, 1.0);
    }
    return 0.3;
  }

  /// 根据屏幕尺寸返回最近阅读列表的最大显示数量
  int _getRecentCount() {
    final h = MediaQuery.of(context).size.height;
    if (Responsive.isTablet(context)) {
      return h > 900 ? 10 : 8;
    }
    return _recent.length > 6 ? 6 : _recent.length;
  }

  Future<void> _remove(ComicDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('移出书架'),
        content: Text('确定将「${d.name}」移出书架吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final sid = BookshelfStore.sourceIdOf(d.id);
    if (sid != null) BookshelfStore.remove(sid, d.id);
    reload();
  }

  void _open(ComicDetail d) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: BookshelfStore.sourceIdOf(d.id) ?? '',
          comicId: d.id,
          name: d.name,
          pic: d.pic,
        ),
      ),
    );
  }

  /// 历史记录只存漫画/小说阅读进度（视频观看进度走 [VideoRecord] 独立存储），
  /// 所以这里一律进漫画详情页，不需要区分是不是视频。
  void _openFromHistory(HistoryEntry h) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: h.book.sourceId,
          comicId: h.book.comicId,
          name: h.book.name,
          pic: h.book.pic,
        ),
      ),
    );
  }

  /// 续播：先向源解析该集的播放入口（站点 iframe 解析器 URL），再交给
  /// AnimePlayerPage —— 由它抓到真实直链后自动切原生播放器。
  ///
  /// 不能直接 push NativePlayerPage：它要求必填真实直链（m3u8/mp4），
  /// 而直链只有 WebView 播放页才能拿到。
  Future<void> _openVideoRecord(VideoRecord r) async {
    final src = SourceManager.videoById(r.sourceId);
    if (src == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该视频源已不可用，无法续播')),
      );
      return;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    String url;
    try {
      url = await src.playUrl(r.videoId, r.season, r.episode);
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('续播失败：$e')),
        );
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AnimePlayerPage(
          url: url,
          title: r.title,
          cover: r.cover,
          initialSeason: r.season,
          initialEpisode: r.episode,
          resolveUrl: (s, e) => src.playUrl(r.videoId, s, e),
          sourceId: r.sourceId,
          videoId: r.videoId,
        ),
      ),
    );
  }

  Future<void> _deleteVideoRecord(VideoRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('删除记录'),
        content: Text('确定删除「${r.title}」的观看记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await LocalStore.removeVideoRecord(r.key);
      reload();
    }
  }

  void _showCardAction(ComicDetail d) {
    showResponsiveBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(d.name),
              subtitle: const Text('查看详情'),
              onTap: () {
                Navigator.pop(ctx);
                _open(d);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('移出书架',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _remove(d);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 桌面右键菜单项：查看详情 / 移出书架（破坏性）。
  List<CtxMenuItem> _shelfCardMenu(ComicDetail d) => [
        CtxMenuItem(
          label: '查看详情',
          icon: Icons.info_outline_rounded,
          onTap: () => _open(d),
        ),
        const CtxMenuItem.separator(),
        CtxMenuItem(
          label: '移出书架',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onTap: () => _remove(d),
        ),
      ];

  Future<void> _checkUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    var count = 0;
    for (final d in _items) {
      final sid = BookshelfStore.sourceIdOf(d.id);
      if (sid == null) continue;
      try {
        final detail = await SourceManager.byId(sid).detail(d.id);
        if (detail.chapters.length > d.chapters.length) count++;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _updateCount = count;
        _checkingUpdate = false;
      });
    }
  }

  // ─── Tab Bar ────────────────────────────────────────────────────────────

  Widget _tabBar() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 6,
          Responsive.pagePadding(context), 0),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          border: Border(
            bottom:
                BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
          ),
        ),
        child: Row(
          children: [
            _tabItem('最近阅读', 0),
            _tabItem('我的收藏', 1),
            _tabItem('动画记录', 2),
            _tabItem('下载', 3),
          ],
        ),
      ),
    );
  }

  Widget _tabItem(String label, int v) {
    final scheme = Theme.of(context).colorScheme;
    final active = _tab == v;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab = v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          active ? FontWeight.w700 : FontWeight.w500,
                      color: active
                          ? scheme.primary
                          : T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                    ),
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: active ? 26 : 0,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(R.control),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Tag Chips ──────────────────────────────────────────────────────────

  Widget _tagChips() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      child: ListView.separated(
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pagePadding(context), vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: _allTags.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          if (i == 0) {
            final sel = _tagFilter == null;
            return GestureDetector(
              onTap: () => setState(() => _tagFilter = null),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: sel
                      ? scheme.primary.withValues(alpha: 0.16)
                      : scheme.surface,
                  borderRadius: BorderRadius.circular(R.pill),
                  border: Border.all(
                    color: sel
                        ? scheme.primary.withValues(alpha: 0.3)
                        : T.color(scheme.onSurface, TextTier.hairline,
                            brightness: scheme.brightness),
                  ),
                ),
                child: Text(
                  '全部',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight:
                            sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel
                            ? scheme.primary
                            : T.color(scheme.onSurface, TextTier.low,
                                brightness: scheme.brightness),
                      ),
                ),
              ),
            );
          }
          final tag = _allTags[i - 1];
          final sel = _tagFilter == tag;
          return GestureDetector(
            onTap: () => setState(() => _tagFilter = tag),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: sel
                    ? scheme.primary.withValues(alpha: 0.16)
                    : scheme.surface,
                borderRadius: BorderRadius.circular(R.pill),
                border: Border.all(
                  color: sel
                      ? scheme.primary.withValues(alpha: 0.3)
                      : T.color(scheme.onSurface, TextTier.hairline,
                          brightness: scheme.brightness),
                ),
              ),
              child: Text(
                tag,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight:
                          sel ? FontWeight.w700 : FontWeight.w500,
                      color: sel
                          ? scheme.primary
                          : T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                    ),
              ),
            ),
          );
        },
      ),
    );
  }
}

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

class _ReadingCard extends StatelessWidget {
  final HistoryEntry history;
  final double progress;
  final VoidCallback onTap;
  const _ReadingCard({
    required this.history,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = history.book;
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness),
          ),
        ),
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
                  // 进度条
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
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
  const _ShelfCard({
    required this.item,
    required this.editing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasUpdate = BookshelfStore.hasUpdate(
      BookshelfStore.sourceIdOf(item.id) ?? '',
      item.id,
      item.chapters.length,
    );
    return PressableScale(
      onTap: onTap,
      scale: 0.96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(kCoverRadius),
              child: Stack(
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
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
              ),
            ),
          ),
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

  /// 副标题：集数 + 播放位置。seconds 为 0 时只显示集数。
  static String _subtitleOf(VideoRecord r) {
    final ep = '第 ${r.episode} 集';
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
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness),
          ),
        ),
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
