import 'package:flutter/material.dart';
import 'dart:io';

import '../net/bookshelf_store.dart';
import '../net/shelf_updater.dart';
import '../net/download_manager.dart';
import '../net/video_download_manager.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'detail_page.dart';
import 'native_player_page.dart';
import 'reader_page.dart';
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
  List<ComicBookmark> _bookmarks = [];
  // 下载（书架的「下载」Tab）：漫画章节下载 + 已下载完成的动漫。
  List<DownloadRecord> _mangaDownloads = [];
  List<VideoDownloadTask> _animeDownloads = [];
  int _tab = 0;
  bool _loading = true;
  bool _refreshing = false;
  bool _editing = false;
  String? _tagFilter;
  List<String> _allTags = [];
  // 书架分类（文件夹）：'all' = 全部视图；null = 未启用分类筛选。
  String? _folderFilter;
  List<Map<String, dynamic>> _folders = [];
  // 收藏 Tab 内搜索 + 筛选 + 排序。
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String? _statusFilter;
  List<String> _allStatuses = [];
  int _sortMode = 0; // 0=最近更新 1=最近收藏 2=名称
  int _updateCount = 0;
  bool _checkingUpdate = false;

  /// 续播解析中（防止 await playUrl 期间连点叠多个 dialog/播放器页）。
  bool _openingVideo = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 后台定时检查发现新更新时弹出提示（应用内横幅）。
    ShelfUpdater.instance.onUpdatesFound = (names) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('收藏有更新：${names.take(3).join('、')}${names.length > 3 ? ' 等' : ''}'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              setState(() {
                _tab = 1;
                _updateCount = names.length;
                _applyFilters();
              });
            },
          ),
        ),
      );
    };
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
      final marks = await LocalStore.bookmarks();
      // 分类列表（含「全部」与「默认分类」）；若当前选中的分类已不存在
      // （被删除/备份还原），回落「全部」，避免过滤后空白。
      final folders = await BookshelfStore.folders();
      if (mounted) {
        setState(() {
          _items = list;
          _allTags = BookshelfStore.allTags();
          _folders = folders;
          if (_folderFilter != null && _folderFilter != BookshelfStore.allFolderId &&
              !folders.any((f) => f['id'] == _folderFilter)) {
            _folderFilter = null;
          }
          _allStatuses = _collectStatuses(list);
          _recent = hist;
          _videos = videos;
          _bookmarks = marks;
          _mangaDownloads = dl;
          _animeDownloads = ani;
          _loading = false;
          _applyFilters();
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
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 从书架条目收集所有出现过的「状态」值（连载中/已完结/…），保序去重。
  List<String> _collectStatuses(List<ComicDetail> list) {
    final seen = <String>[];
    for (final d in list) {
      final s = (d.status ?? '').trim();
      if (s.isNotEmpty && !seen.contains(s)) seen.add(s);
    }
    return seen;
  }

  /// 统一过滤管线：分类 + 标签 + 搜索 + 状态筛选 + 排序，结果写入 [_filtered]。
  void _applyFilters() {
    final q = _searchQuery.trim().toLowerCase();
    var out = _items.where((d) {
      final sid = d.sourceId ?? BookshelfStore.sourceIdOf(d.id) ?? '';
      // 分类过滤：选中「全部」或未选时不过滤；进分类后只看该分类的书。
      if (_folderFilter != null && _folderFilter != BookshelfStore.allFolderId) {
        if (BookshelfStore.folderIdOf(sid, d.id) != _folderFilter) {
          return false;
        }
      }
      if (_tagFilter != null) {
        if (!BookshelfStore.tagsOf(sid, d.id).contains(_tagFilter)) {
          return false;
        }
      }
      if (_statusFilter != null && (d.status ?? '') != _statusFilter) {
        return false;
      }
      if (q.isNotEmpty) {
        final name = d.name.toLowerCase();
        final author = (d.author ?? '').toLowerCase();
        if (!name.contains(q) && !author.contains(q)) return false;
      }
      return true;
    }).toList();

    // 排序：各 case 必须 break，否则 case 1/2 会贯穿执行（历史 bug）。
    switch (_sortMode) {
      case 1:
        out.sort((a, b) =>
            BookshelfStore.addedAtOf(b).compareTo(BookshelfStore.addedAtOf(a)));
        break;
      case 2:
        out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      default:
        out.sort((a, b) => BookshelfStore.updateTimeOf(b, _recent)
            .compareTo(BookshelfStore.updateTimeOf(a, _recent)));
    }
    _filtered = out;
  }

  /// 搜索/筛选/排序任一变化时调用（需要 setState 刷新 UI）。
  void _onFilterChanged() {
    setState(_applyFilters);
  }

  String _emptyFilterText() {
    final q = _searchQuery.trim();
    if (q.isNotEmpty) return '没有找到「$q」';
    if (_statusFilter != null) return '没有「$_statusFilter」状态的作品';
    if (_tagFilter != null) return '没有匹配「$_tagFilter」标签的作品';
    return '没有匹配的作品';
  }

  String _emptyFilterSubtitle() {
    if (_searchQuery.trim().isNotEmpty) {
      return '换个关键词，或试试标题 / 作者名';
    }
    return '试试清除筛选条件';
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
            // 收藏 Tab：搜索 + 标签/状态筛选 + 排序
            if (_tab == 1 && _items.isNotEmpty) _shelfFilterBar(),
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
      case 3:
        return '下载';
      default:
        return '书签';
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
        else if (_tab == 3)
          _buildDownloadsView(scheme)
        else
          _buildBookmarkList(scheme),
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
            text: _emptyFilterText(),
            subtitle: _emptyFilterSubtitle(),
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

  /// 书签列表
  Widget _buildBookmarkList(ColorScheme scheme) {
    if (_bookmarks.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 120),
          child: _TabEmpty(
            icon: Icons.bookmark_added_rounded,
            text: '还没有手动书签',
            subtitle: '阅读漫画时呼出菜单点「书签当前页」，就能在这里随时跳回',
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
        itemCount: _bookmarks.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (c, i) => _BookmarkCard(
          mark: _bookmarks[i],
          onTap: () => _openBookmark(_bookmarks[i]),
          onDelete: () => _deleteBookmark(_bookmarks[i]),
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
                _mangaDownloads.isEmpty ? null : _confirmClearMangaAll,
                trailing: _failedManga.isEmpty
                    ? null
                    : TextButton.icon(
                        onPressed: _retryAllManga,
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
      int count, VoidCallback? onClear,
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

  /// 未完成（失败/中断）的漫画下载任务。
  List<DownloadRecord> get _failedManga =>
      _mangaDownloads.where((d) => !d.finished).toList();

  /// 一键重试所有失败的漫画下载。
  Future<void> _retryAllManga() async {
    final failed = _failedManga;
    if (failed.isEmpty) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('正在重试 ${failed.length} 话…'),
        duration: const Duration(seconds: 2)));
    var ok = 0;
    var keep = 0;
    for (final d in failed) {
      try {
        final source = SourceManager.byId(d.book.sourceId);
        final urls = await source.chapterPics(d.chapterId);
        final success = await DownloadManager.retry(
            '${d.book.sourceId}::${d.book.comicId}',
            d.chapterId,
            d.chapterTitle,
            urls);
        if (success) {
          ok++;
        } else {
          keep++;
        }
      } catch (_) {
        keep++;
      }
    }
    await reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(keep == 0 ? '已重试完成：成功 $ok 话' : '重试完成：成功 $ok 话，$keep 话仍失败')));
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
          if (_items.isNotEmpty)
            SliverToBoxAdapter(child: _shelfFilterBar()),
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
                  text: _emptyFilterText(),
                  subtitle: _emptyFilterSubtitle(),
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
        else if (_tab == 3)
          _buildDownloadsView(scheme)
        else
          _buildBookmarkList(scheme),
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
    final sid = d.sourceId ?? BookshelfStore.sourceIdOf(d.id);
    if (sid != null) BookshelfStore.remove(sid, d.id);
    reload();
  }

  void _open(ComicDetail d) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: d.sourceId ?? BookshelfStore.sourceIdOf(d.id) ?? '',
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

  /// 书签直达：先向源解析该章节的目录（拿到全章节列表供连读/切章），
  /// 再携带书签页码直接进入阅读器。
  Future<void> _openBookmark(ComicBookmark m) async {
    final src = SourceManager.byId(m.book.sourceId);
    try {
      final detail = await src.detail(m.book.comicId);
      if (!mounted) return;
      final chapters = detail.chapters;
      final ch = chapters.isNotEmpty
          ? chapters.firstWhere((c) => c.id == m.chapterId,
              orElse: () => chapters.first)
          : Chapter(m.chapterId, m.chapterTitle);
      Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => ReaderPage(
            sourceId: m.book.sourceId,
            comicId: m.book.comicId,
            chapterId: ch.id,
            title: ch.title,
            comicName: detail.name,
            comicPic: detail.pic ?? '',
            comicAuthor: detail.author ?? '',
            chapters: chapters,
            initialPage: m.pageIndex,
          ),
          transitionDuration: const Duration(milliseconds: 320),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: child,
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('跳转书签失败：$e')),
      );
    }
  }

  Future<void> _deleteBookmark(ComicBookmark m) async {
    await LocalStore.removeBookmark(
        m.book.sourceId, m.book.comicId, m.chapterId, m.pageIndex);
    reload();
  }

  /// 续播：向源解析该集的播放入口后统一进 NativePlayerPage（单一播放器）。
  /// 直链走 mpv 通道；网页地址（站点 iframe 解析器/人机校验）由页面内嵌
  /// WebView 通道处理，不再跳独立 AnimePlayerPage。
  Future<void> _openVideoRecord(VideoRecord r) async {
    if (_openingVideo) return;
    _openingVideo = true;
    try {
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
          builder: (_) => NativePlayerPage(
            url: url,
            title: r.title,
            cover: r.cover,
            episodes: const [],
            season: r.season,
            episode: r.episode,
            resolveUrl: (s, e) => src.playUrl(r.videoId, s, e),
            sourceId: r.sourceId,
            videoId: r.videoId,
          ),
        ),
      );
    } finally {
      _openingVideo = false;
    }
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
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移入分类'),
              subtitle: const Text('整理书架到文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                _showFolderPicker(d);
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('编辑标签'),
              subtitle: const Text('分类整理书架'),
              onTap: () {
                Navigator.pop(ctx);
                _showTagEditor(d);
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

  /// 「移入分类」底部弹窗：列出全部自建分类，点选即移动并刷新。
  /// 目标分类高亮当前所属；选中「默认分类」归位。
  Future<void> _showFolderPicker(ComicDetail d) async {
    final sid = d.sourceId ?? BookshelfStore.sourceIdOf(d.id);
    if (sid == null) return;
    final folders = await BookshelfStore.userFolders();
    if (!mounted) return; // await 后使用 context，需保证 State 仍在树上
    final current = BookshelfStore.folderIdOf(sid, d.id);

    await showResponsiveBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('移入分类',
                    style: Theme.of(ctx).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...folders.map((f) {
                  final id = f['id'] as String;
                  final sel = current == id;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      sel
                          ? Icons.check_circle_rounded
                          : Icons.folder_outlined,
                      size: 20,
                      color: sel
                          ? Theme.of(ctx).colorScheme.primary
                          : Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(f['name'] as String,
                        style: const TextStyle(fontSize: 14)),
                    trailing: sel
                        ? Icon(Icons.chevron_right_rounded,
                            size: 18,
                            color:
                                Theme.of(ctx).colorScheme.onSurfaceVariant)
                        : null,
                    onTap: () {
                      BookshelfStore.setFolderId(sid, d.id, id);
                      Navigator.pop(ctx);
                      if (mounted) {
                        setState(() {
                          // 若当前正筛着别的分类且书被移走，刷新后自动回落
                          _applyFilters();
                        });
                      }
                    },
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 分类管理弹窗：新增 / 重命名 / 删除分类（「默认分类」不可删，删除后
  /// 书籍自动归入默认分类）。操作后刷新书架筛选栏与列表。
  Future<void> _showFolderManager() async {
    final controller = TextEditingController();
    var folders = await BookshelfStore.userFolders();
    if (!mounted) return; // await 后使用 context，需保证 State 仍在树上

    await showResponsiveBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // 弹窗内分类列表 + 页面筛选栏的同步刷新（增删改后两处一起更新）。
          Future<void> refresh() async {
            final fs = await BookshelfStore.folders();
            folders = fs;
            setSheetState(() {});
            if (mounted) {
              setState(() {
                _folders = fs;
                if (_folderFilter != null &&
                    _folderFilter != BookshelfStore.allFolderId &&
                    !fs.any((f) => f['id'] == _folderFilter)) {
                  _folderFilter = null;
                }
                _applyFilters();
              });
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('管理分类',
                          style: Theme.of(ctx).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('完成'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 新增分类
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: '新分类名称',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (v) async {
                          final t = v.trim();
                          if (t.isEmpty) return;
                          await BookshelfStore.addFolder(t);
                          controller.clear();
                          await refresh();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () async {
                        final t = controller.text.trim();
                        if (t.isEmpty) return;
                        await BookshelfStore.addFolder(t);
                        controller.clear();
                        await refresh();
                      },
                      child: const Text('新增'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 分类列表（仅自建分类，可删可改）
                ...folders.map((f) {
                  final id = f['id'] as String;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined,
                        size: 20, color: Colors.amber),
                    title: Text(f['name'] as String,
                        style: const TextStyle(fontSize: 14)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '重命名',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () async {
                            final name =
                                await _promptFolderName(ctx, f['name'] as String);
                            if (name == null || name.trim().isEmpty) return;
                            await BookshelfStore.renameFolder(id, name);
                            await refresh();
                          },
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: Icon(Icons.delete_outline,
                              size: 18,
                              color: Theme.of(ctx).colorScheme.error),
                          onPressed: () async {
                            await BookshelfStore.deleteFolder(id);
                            await refresh();
                          },
                        ),
                      ],
                    ),
                  );
                }),
                if (folders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('还没有分类，输入名称创建一个吧',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        );
      },
      ),
    );
    controller.dispose();
  }

  /// 重命名输入弹窗，返回新名称（取消返回 null）。
  Future<String?> _promptFolderName(BuildContext ctx, String current) async {
    final ctrl = TextEditingController(text: current);
    final v = await showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('重命名分类'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '分类名称', isDense: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return v;
  }

  /// 标签编辑弹窗：预设标签多选 + 自定义输入，写回书架存储并刷新筛选。
  Future<void> _showTagEditor(ComicDetail d) async {
    final sid = d.sourceId ?? BookshelfStore.sourceIdOf(d.id);
    if (sid == null) return;
    final selected = BookshelfStore.tagsOf(sid, d.id).toList();
    final controller = TextEditingController();

    await showResponsiveBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('编辑标签',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setSheetState(() => selected.clear());
                      },
                      child: const Text('清空'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: BookshelfStore.allTags()
                      .map((tag) => FilterChip(
                            label: Text(tag),
                            selected: selected.contains(tag),
                            onSelected: (on) => setSheetState(() {
                              on ? selected.add(tag) : selected.remove(tag);
                            }),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: '自定义标签',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (v) {
                          final t = v.trim();
                          if (t.isEmpty) return;
                          setSheetState(() {
                            if (!selected.contains(t)) selected.add(t);
                            controller.clear();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () {
                        final t = controller.text.trim();
                        if (t.isEmpty) return;
                        setSheetState(() {
                          if (!selected.contains(t)) selected.add(t);
                          controller.clear();
                        });
                      },
                      child: const Text('添加'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      BookshelfStore.setTags(sid, d.id, selected);
                      Navigator.pop(ctx);
                      if (mounted) {
                        setState(() => _allTags = BookshelfStore.allTags());
                      }
                    },
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.dispose();
  }

  /// 桌面右键菜单项：查看详情 / 移入分类 / 编辑标签 / 移出书架（破坏性）。
  List<CtxMenuItem> _shelfCardMenu(ComicDetail d) => [
        CtxMenuItem(
          label: '查看详情',
          icon: Icons.info_outline_rounded,
          onTap: () => _open(d),
        ),
        CtxMenuItem(
          label: '移入分类',
          icon: Icons.drive_file_move_outlined,
          onTap: () => _showFolderPicker(d),
        ),
        CtxMenuItem(
          label: '编辑标签',
          icon: Icons.label_outline_rounded,
          onTap: () => _showTagEditor(d),
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
    try {
      final updated = await ShelfUpdater.checkNow();
      if (mounted) {
        setState(() {
          _updateCount = updated.length;
          _checkingUpdate = false;
        });
        if (updated.isEmpty || _updateCount == 0) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${updated.length} 部作品有更新${_newNames(updated)}'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  String _newNames(List<String> names) {
    if (names.isEmpty) return '';
    var preview = names.take(3).join('、');
    if (names.length > 3) preview += ' 等';
    return '：$preview';
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
            _tabItem('书签', 4),
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
        onTap: () {
          if (v == 4) reload(); // 切到书签页时刷新（阅读器里可能刚增删了书签）
          setState(() => _tab = v);
        },
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

  // ─── 收藏筛选栏（搜索 + 标签/状态 + 排序） ─────────────────────────────

  Widget _shelfFilterBar() {
    final scheme = Theme.of(context).colorScheme;
    final pad = Responsive.pagePadding(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 0),
          child: SizedBox(
            height: 38,
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) {
                _searchQuery = v;
                _onFilterChanged();
              },
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '搜索收藏（标题 / 作者）',
                prefixIcon:
                    const Icon(Icons.search_rounded, size: 18),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          _searchQuery = '';
                          _onFilterChanged();
                        },
                      ),
                isDense: true,
                filled: true,
                fillColor: scheme.surface,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(R.pill),
                  borderSide: BorderSide(
                      color: scheme.onSurface.withValues(alpha: 0.08)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(R.pill),
                  borderSide: BorderSide(
                      color: scheme.onSurface.withValues(alpha: 0.08)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(R.pill),
                  borderSide: BorderSide(color: scheme.primary, width: 1.2),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView.separated(
            padding:
                EdgeInsets.symmetric(horizontal: pad, vertical: 8),
            scrollDirection: Axis.horizontal,
            itemCount: _chipCount(),
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _filterChipAt(i),
          ),
        ),
      ],
    );
  }

  int _chipCount() {
    // 排序 + 状态 + 分类段（含「全部」+ 自建分类 + 管理入口）+ 标签段（全部 + 标签）
    final folderCount = _folders.length + 1; // +1 = 管理入口
    final tagCount = _allTags.length + 1; // +1 = 标签「全部」
    return 1 + (_allStatuses.isNotEmpty ? 1 : 0) + folderCount + tagCount;
  }

  Widget _filterChipAt(int i) {
    var idx = 0;
    // 排序
    if (i == idx++) return _sortChip();
    // 状态
    if (_allStatuses.isNotEmpty && i == idx++) return _statusChip();
    // 分类段：全部 + 自建分类 + 管理入口
    final folderSel = _folderFilter ?? BookshelfStore.allFolderId;
    for (final f in _folders) {
      final id = f['id'] as String;
      if (i == idx++) {
        return _chip(f['name'] as String, folderSel == id, () {
          setState(() {
            _folderFilter = id == BookshelfStore.allFolderId ? null : id;
            _applyFilters();
          });
        });
      }
    }
    if (i == idx++) return _manageFolderChip();
    // 标签段：全部标签
    if (i == idx++) {
      final sel = _tagFilter == null;
      return _chip('全部', sel, () => setState(() {
        _tagFilter = null;
        _applyFilters();
      }));
    }
    // 标签
    final tag = _allTags[i - idx];
    final sel = _tagFilter == tag;
    return _chip(tag, sel, () => setState(() {
      _tagFilter = tag;
      _applyFilters();
    }));
  }

  /// 「管理分类」入口 chip：打开分类管理弹窗；正在筛选中时带个小圆点提示。
  Widget _manageFolderChip() {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _showFolderManager,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
              color: scheme.onSurface.withValues(alpha: 0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.create_new_folder_outlined,
                size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text('管理分类',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool sel, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: sel ? scheme.primary.withValues(alpha: 0.16) : scheme.surface,
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: sel
                ? scheme.primary.withValues(alpha: 0.3)
                : T.color(scheme.onSurface, TextTier.hairline,
                    brightness: scheme.brightness),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                  color: sel
                      ? scheme.primary
                      : T.color(scheme.onSurface, TextTier.low,
                          brightness: scheme.brightness),
                ),
          ),
        ),
      ),
    );
  }

  /// 排序下拉（最近更新 / 最近收藏 / 名称）。
  Widget _sortChip() {
    final scheme = Theme.of(context).colorScheme;
    final labels = ['最近更新', '最近收藏', '名称'];
    return PopupMenuButton<int>(
      tooltip: '排序方式',
      initialValue: _sortMode,
      onSelected: (v) => setState(() {
        _sortMode = v;
        _applyFilters();
      }),
      itemBuilder: (_) => [
        for (var i = 0; i < labels.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                Icon(
                  _sortMode == i
                      ? Icons.check_rounded
                      : Icons.sort_rounded,
                  size: 16,
                  color: _sortMode == i
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(labels[i], style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
      child: _chip('排序：${labels[_sortMode]}', false, () {}),
    );
  }

  /// 状态筛选下拉（连载中 / 已完结 / …）。
  Widget _statusChip() {
    final scheme = Theme.of(context).colorScheme;
    final items = <String>['不限', ..._allStatuses];
    return PopupMenuButton<int>(
      tooltip: '按状态筛选',
      initialValue: _statusFilter == null ? 0 : _allStatuses.indexOf(_statusFilter!) + 1,
      onSelected: (v) => setState(() {
        _statusFilter = v == 0 ? null : _allStatuses[v - 1];
        _applyFilters();
      }),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                Icon(
                  (_statusFilter == null && i == 0) ||
                          (_statusFilter != null &&
                              _allStatuses[i - 1] == _statusFilter)
                      ? Icons.check_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(items[i], style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
      child: _chip(
        _statusFilter == null ? '状态：不限' : '状态：$_statusFilter',
        _statusFilter != null,
        () {},
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
      item.sourceId ?? BookshelfStore.sourceIdOf(item.id) ?? '',
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
