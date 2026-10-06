import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';

import 'bookshelf_providers.dart';
import 'detail_providers.dart' show comicInShelfProvider;
import '../net/bookshelf_store.dart';
import '../net/error_logger.dart';
import '../net/shelf_updater.dart';
import '../net/download_manager.dart';
import '../net/video_download_manager.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'bookshelf_download_view.dart';
import 'anime_player_page.dart' show animePlayerWebChannel;
import 'detail_page.dart';
import 'native_player_page.dart';
import 'novel_detail_page.dart';
import 'reader_page.dart';
import 'responsive.dart';
import 'tokens.dart';
import 'widgets/app_toast.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';
import 'widgets/squircle.dart';
import 'style_scope.dart';
import 'style_tokens.dart';

/// 网格书架卡的续读副标题文本：在 [recent]（按时间倒序）中找 `bookKey
/// == key` 的最近一条历史。有页码 → 「续读 第N话 · 第M页」；无页码 →
/// 只显示章节名（页面停在目录/顶部）；章节名为空 → 「已读」。找不到 → ''。
/// 纯函数：书架 State 的 `_resumeTextOf` 是薄转发，便于单测。
String resumeTextOf(String key, List<HistoryEntry> recent) {
  for (final h in recent) {
    if (h.book.key == key) {
      final name = h.chapterTitle.isEmpty ? '已读' : '续读 ${h.chapterTitle}';
      return h.hasPage && h.pageIndex >= 0
          ? '$name · 第${h.pageIndex + 1}页'
          : name;
    }
  }
  return '';
}

/// 书签列表过滤纯函数：按书名/章节标题匹配（空 = 原样返回）。
/// 语义与下载 Tab/批量下载过滤一致，独立便于单元测试。
List<ComicBookmark> filterBookmarks(
    List<ComicBookmark> bookmarks, String filter) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return bookmarks;
  return [
    for (final b in bookmarks)
      if (b.book.name.toLowerCase().contains(f) ||
          b.chapterTitle.toLowerCase().contains(f))
        b,
  ];
}

/// 书架页：跨源聚合，按时间倒序。错峰入场。
///
/// 平板布局（≥600dp）：
/// - 左侧：标签分类筛选（固定宽度 200dp）
/// - 右侧：内容列表/网格
///
/// 手机布局：
/// - 顶部：标签切换（横向滚动）
/// - 下方：内容列表/网格
class BookshelfPage extends ConsumerStatefulWidget {
  /// 空书架引导按钮回调（跳转首页/发现页）。为 null 时不显示按钮。
  final VoidCallback? onGotoHome;
  const BookshelfPage({super.key, this.onGotoHome});

  @override
  ConsumerState<BookshelfPage> createState() => BookshelfPageState();
}

class BookshelfPageState extends ConsumerState<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  List<ComicDetail> _items = [];
  /// comicId → 章节 id 列表（由 [_items] 派生），供最近阅读进度 O(1) 反查。
  Map<String, List<String>> _chapterIndex = const {};
  List<ComicDetail> _filtered = [];
  List<HistoryEntry> _recent = [];
  List<VideoRecord> _videos = [];
  List<ComicBookmark> _bookmarks = [];
  // 下载（书架的「下载」Tab）：漫画章节下载 + 已下载完成的动漫。
  List<DownloadRecord> _mangaDownloads = [];
  List<VideoDownloadTask> _animeDownloads = [];
  int _tab = 0;
  bool _loading = true;
  /// 本地数据读取失败原因：六组全败时置位（整页错误视图用）。
  /// 部分失败时用空列表替代该组，不进错误态，不打扰用户。
  String? _loadError;
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
  // 书签 Tab 搜索（独立于收藏 Tab 搜索，各自持有输入态）。
  final _bookmarkFilterCtrl = TextEditingController();
  String _bookmarkFilter = '';
  String? _statusFilter;
  List<String> _allStatuses = [];
  int _sortMode = 0; // 0=最近更新 1=最近收藏 2=名称
  int _updateCount = 0;
  bool _checkingUpdate = false;
  /// 用户主动取消本轮检查更新（转圈时再点一次按钮触发）。
  bool _cancelUpdateCheck = false;
  /// 检查更新进度文案（'12/156'），转圈时展示。
  String _checkProgress = '';
  /// 手机端最近阅读是否已展开（截断 6 条时点击「查看全部」置位）。
  bool _recentExpanded = false;

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
      AppToast.show(
        context,
        '收藏有更新：${names.take(3).join('、')}${names.length > 3 ? ' 等' : ''}',
        duration: const Duration(seconds: 5),
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
      );
    };
    // 数据源由 bookshelfDataProvider 承载（六组本地读取 + foldersVersion 自动失效），
    // 数据到达或版本变化时经 ref.listenManual 灌入本地字段。页面触发刷新用
    // ref.invalidate(bookshelfDataProvider)；外部（main_shell/测试）仍走 reload()。
    ref.listenManual<AsyncValue<BookshelfData>>(
      bookshelfDataProvider,
      (prev, next) {
        if (!mounted) return;
        next.when(
          data: (data) => setState(() => _applyData(data)),
          error: (e, _) {
            ErrorLogger.instance.warn('书架数据源错误: $e');
            setState(() {
              _loading = false;
              _loadError = '书架本地数据读取异常，请重试';
            });
          },
          loading: () {
            // 首次加载或主动刷新（invalidate 后）进入 loading：
            // 仅当没有任何可渲染内容时才显示转圈，其余情况保持旧内容。
            if (prev?.value == null && mounted) {
              setState(() =>
                  _loading = _items.isEmpty && _recent.isEmpty && _videos.isEmpty);
            }
          },
        );
      },
    );
    // 首次加载由订阅触发（listenManual 激活 provider 即开始读取）：
    // 不在 initState 里直接调 reload()——后者经 ref.invalidate/ref.read 访问
    // ProviderScope 容器，initState 阶段依赖树尚未建立（框架断言）。
    // 动漫下载任务单独订阅（bookshelfDataProvider 已不聚合下载，避免高频进度
    // 重读拖累书架主列表）；progress 实时流入「下载」Tab。
    ref.listenManual<AsyncValue<List<VideoDownloadTask>>>(
      animeDownloadTasksProvider,
      (prev, next) {
        if (!mounted) return;
        next.when(
          data: (tasks) => setState(() => _animeDownloads = tasks),
          error: (e, _) {
            ErrorLogger.instance.warn('动漫下载任务读取失败: $e');
          },
          loading: () {},
        );
      },
    );
    // 漫画下载记录单独订阅（同动漫侧理由：bookshelfDataProvider 内嵌的
    // downloads 组读一次就固化，进度不动；改用 mangaDownloadsProvider 的
    // 版本号信号 + 300ms 合并窗口流式重读，进度条实时走动）。
    ref.listenManual<AsyncValue<List<DownloadRecord>>>(
      mangaDownloadsProvider,
      (prev, next) {
        if (!mounted) return;
        next.when(
          data: (records) => setState(() => _mangaDownloads = records),
          error: (e, _) {
            ErrorLogger.instance.warn('漫画下载记录读取失败: $e');
          },
          loading: () {},
        );
      },
    );
  }

  /// 把 provider 聚合快照灌入本地渲染字段（setState 已在调用方包好）。
  /// 保持既有派生逻辑：章节索引、全部标签、文件夹校验、状态集合、动画下载。
  void _applyData(BookshelfData data) {
    final list = data.items;
    _items = list;
    _chapterIndex = {
      for (final d in list)
        if (d.chapters.isNotEmpty) d.id: [
              for (final c in d.chapters) c.id
            ],
    };
    _allTags = BookshelfStore.allTags();
    _folders = data.folders;
    if (_folderFilter != null &&
        _folderFilter != BookshelfStore.allFolderId &&
        !data.folders.any((f) => f['id'] == _folderFilter)) {
      _folderFilter = null;
    }
    _allStatuses = _collectStatuses(list);
    _recent = data.recent;
    _videos = data.videos;
    _bookmarks = data.bookmarks;
    _mangaDownloads = data.mangaDownloads;
    _loading = false;
    _loadError = data.totalError;
    _applyFilters();
  }

  /// 页面重载：使 bookshelfDataProvider 失效并等待新数据灌入。
  /// 供下拉刷新、main_shell 与测试复用。
  Future<void> reload() async {
    if (mounted) {
      setState(() =>
          _loading = _items.isEmpty && _recent.isEmpty && _videos.isEmpty);
    }
    // invalidate 使 provider 重跑（六组并行读取）；await future 等数据灌入，
    // 避免调用方（下拉刷新等）在数据落地前就收尾。
    ref.invalidate(bookshelfDataProvider);
    try {
      await ref.read(bookshelfDataProvider.future).then((_) {});
    } catch (e) {
      // provider 兜底错误（理论不可达，_readGroup 已吞掉组内异常）：
      // ref.listen 的 error 分支已置错误态，这里确保 loading 不会残留。
      ErrorLogger.instance.warn('书架加载兜底失败: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '书架本地数据读取异常，请重试';
        });
      }
    }
  }

  /// 尽力恢复的容错读取已迁至 bookshelfDataProvider（bookshelf_providers.dart），
  /// 页面不再持有 _readGroup/_GroupRead。

  Future<void> _onRefresh() async {
    setState(() => _refreshing = true);
    await reload();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  void dispose() {
    // 解除全局更新回调，避免页面销毁后仍被后台检查触发（context 已失效）。
    ShelfUpdater.instance.onUpdatesFound = null;
    _searchCtrl.dispose();
    _bookmarkFilterCtrl.dispose();
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

    // 六组本地数据全部读取失败（文件损坏等极端情况）且无任何可渲染内容时，
    // 用明确的错误视图替换空态：原因 + 重试入口（复用 reload）。
    // 只要还有任何一组数据可用，就正常渲染（尽力恢复，不打扰用户）。
    if (_loadError != null &&
        _items.isEmpty &&
        _recent.isEmpty &&
        _videos.isEmpty &&
        _mangaDownloads.isEmpty &&
        _animeDownloads.isEmpty &&
        _bookmarks.isEmpty) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.error.withValues(alpha: 0.1),
                    ),
                    child: Icon(Icons.error_outline_rounded,
                        size: 40, color: scheme.error),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '数据加载失败',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '本地数据读取异常，书架暂时无法显示\n$_loadError',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          height: 1.5,
                          color: T.color(scheme.onSurface, TextTier.disabled,
                              brightness: scheme.brightness),
                        ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.tonalIcon(
                    onPressed: reload,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
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
        tooltip: _checkingUpdate
            ? '停止检查${_checkProgress.isNotEmpty ? '（$_checkProgress）' : ''}'
            : '检查更新',
        onPressed: _checkUpdates,
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
          BookshelfDownloadView(
            scheme: scheme,
            mangaDownloads: _mangaDownloads,
            animeDownloads: _animeDownloads,
            onClearManga: _confirmClearMangaAll,
            onRetryAllManga: _retryAllManga,
            onOpenMangaDetail: _openDownloadDetail,
            onRetryManga: _retryMangaDownload,
            onRemoveManga: _confirmRemoveManga,
            onRemoveMangaBook: _confirmRemoveMangaBook,
            onClearAnime: _confirmClearAnimeAll,
            onOpenAnime: _openAnimeDownload,
            onRetryAnime: _retryAnimeDownload,
            onRemoveAnime: _confirmRemoveAnime,
            onRemoveAnimeTitle: _confirmRemoveAnimeTitle,
          )
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
      sliver: SliverMainAxisGroup(
        slivers: [
          // 列表头：数量 + 清空入口（最近阅读 Tab 直达清空，无需去设置页）。
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    '共 ${_recent.length} 条',
                    style: TextStyle(
                      fontSize: 12,
                      color: T.color(scheme.onSurface, TextTier.low,
                          brightness: scheme.brightness),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _confirmClearRecent,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ),
          ),
          SliverList.separated(
            itemCount: _recent.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            // 平板/大屏内容由主框架 MaxWidthContainer 统一收口（1200/1400），
            // 此处不再叠加 600 二级限宽，避免两级限宽叠加冲突。
            itemBuilder: (c, i) => _ReadingCard(
              history: _recent[i],
              progress: _progressOf(_recent[i]),
              // 小说历史无章内进度，不渲染进度条（见 _ReadingCard.showProgress）。
              showProgress:
                  SourceManager.novelById(_recent[i].book.sourceId) == null,
              onTap: () => _openFromHistory(_recent[i]),
              onLongPressDelete: () => _confirmRemoveRecent(_recent[i]),
            ),
          ),
        ],
      ),
    );
  }

  /// 书架网格
  Widget _buildShelfGrid(ColorScheme scheme) {
    if (_items.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 120),
          child: Column(
            children: [
              const _TabEmpty(
                icon: Icons.bookmark_outline_rounded,
                text: '书架还是空的，去首页收藏几部吧',
                subtitle: '在作品详情页点击收藏，就能在书架里随时找到',
              ),
              // 筛选栏（含「管理分类」chip）仅在收藏非空时显示，空态必须
              // 自带管理入口，否则无收藏用户永远建不出第一个分类。
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.onGotoHome != null)
                    FilledButton.tonalIcon(
                      onPressed: widget.onGotoHome,
                      icon: const Icon(Icons.explore_outlined, size: 18),
                      label: const Text('去首页逛逛'),
                    ),
                  if (widget.onGotoHome != null) const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _showFolderManager,
                    icon: const Icon(Icons.create_new_folder_outlined,
                        size: 18),
                    label: const Text('管理分类'),
                  ),
                ],
              ),
            ],
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
                        subtitle: _resumeTextOf(item),
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
      sliver: SliverMainAxisGroup(
        slivers: [
          // 列表头：数量 + 清空入口（与最近阅读 Tab 同款）。
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    '共 ${_videos.length} 部',
                    style: TextStyle(
                      fontSize: 12,
                      color: T.color(scheme.onSurface, TextTier.low,
                          brightness: scheme.brightness),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _confirmClearVideos,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ),
          ),
          SliverList.separated(
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
        ],
      ),
    );
  }

  /// 书签列表
  Widget _buildBookmarkList(ColorScheme scheme) {
    final filtered = filterBookmarks(_bookmarks, _bookmarkFilter);
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
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(child: _buildBookmarkSearchField(scheme)),
          if (_bookmarkFilter.trim().isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '匹配 ${filtered.length} 条书签',
                  style: TextStyle(
                    fontSize: 12,
                    color: T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                  ),
                ),
              ),
            ),
          if (filtered.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 48),
                child: _TabEmpty(
                  icon: Icons.search_off_rounded,
                  text: '没有匹配「${_bookmarkFilter.trim()}」的书签',
                ),
              ),
            )
          else ...[
            // 列表头：数量 + 清空入口（与最近阅读/动画记录 Tab 同款）。
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Row(
                  children: [
                    Text(
                      '共 ${_bookmarks.length} 条',
                      style: TextStyle(
                        fontSize: 12,
                        color: T.color(scheme.onSurface, TextTier.low,
                            brightness: scheme.brightness),
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _confirmClearBookmarks,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: const Text('清空'),
                    ),
                  ],
                ),
              ),
            ),
            SliverList.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (c, i) => _BookmarkCard(
                mark: filtered[i],
                onTap: () => _openBookmark(filtered[i]),
                onDelete: () => _deleteBookmark(filtered[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 书签 Tab 搜索框（镜像下载 Tab 搜索框样式；本地内存过滤）。
  Widget _buildBookmarkSearchField(ColorScheme scheme) {
    return TextField(
      controller: _bookmarkFilterCtrl,
      onChanged: (v) => setState(() => _bookmarkFilter = v),
      style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索书签（书名 / 章节）',
        hintStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurface.withValues(alpha: 0.4),
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 18,
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
        suffixIcon: _bookmarkFilter.isEmpty
            ? null
            : IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: () {
                  _bookmarkFilterCtrl.clear();
                  setState(() => _bookmarkFilter = '');
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

  /// 下载 Tab 由 [BookshelfDownloadView] 渲染（见 bookshelf_download_view.dart）。

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

  /// 已失败（非进行中）的漫画下载任务：未完成且计数到齐（无法完成的重试
  /// 之后中断），与卡片失败样式判定一致。进行中的任务（done < total）不算，
  /// 避免「重试 N」虚高与对进行中任务重复启动下载。
  List<DownloadRecord> get _failedManga => _mangaDownloads
      .where((d) => !d.finished && d.total > 0 && d.done >= d.total)
      .toList();

  /// 一键重试所有失败的漫画下载。
  Future<void> _retryAllManga() async {
    final failed = _failedManga;
    if (failed.isEmpty) return;
    if (!mounted) return;
    AppToast.info(context, '正在重试 ${failed.length} 话…',
        duration: const Duration(seconds: 2));
    var ok = 0;
    var keep = 0;
    for (final d in failed) {
      try {
        final source = SourceManager.byId(d.book.sourceId);
        final urls = await source.chapterPics(d.chapterId);
        final err = await DownloadManager.retry(
            d.book,
            d.chapterId,
            d.chapterTitle,
            urls);
        if (err == null) {
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
    if (keep > 0) {
      AppToast.show(context, '重试完成：成功 $ok 话，$keep 话仍失败', error: true);
    } else {
      AppToast.info(context, '已重试完成：成功 $ok 话');
    }
  }

  Future<void> _retryMangaDownload(DownloadRecord d) async {
    try {
      final source = SourceManager.byId(d.book.sourceId);
      final urls = await source.chapterPics(d.chapterId);
      final err = await DownloadManager.retry(
          d.book, d.chapterId, d.chapterTitle, urls);
      await reload();
      if (!mounted) return;
      if (err == null) {
        AppToast.info(context, '已重新加入下载');
      } else {
        AppToast.error(context, '重试失败：$err');
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '重试失败，请稍后再试');
      ErrorLogger.instance.warn('manga download retry failed: $e');
    }
  }

  Future<void> _removeMangaDownload(DownloadRecord d) async {
    await LocalStore.removeDownloadFiles(d);
    await LocalStore.removeDownload(d.key);
    await reload();
    if (!mounted) return;
    AppToast.info(context, '已删除下载记录');
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

  Future<void> _confirmRemoveMangaBook(Bookmark book) async {
    final records = _mangaDownloads.where((d) => d.book.key == book.key).toList();
    if (records.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('删除该书全部下载'),
        content: Text('确定删除《${book.name}》的全部 ${records.length} 条下载记录和文件？'),
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
    if (ok != true) return;
    for (final d in records) {
      try {
        await _removeMangaDownload(d);
      } catch (e) {
        ErrorLogger.instance.warn('remove manga book failed key=${d.localKey}: $e');
      }
    }
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
    if (kIsWeb || p == null || !File(p).existsSync()) {
      if (!mounted) return;
      AppToast.info(context, '未找到本地文件，可能无法离线播放');
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
          webChannelBuilder: animePlayerWebChannel,
        ),
      ),
    );
  }

  Future<void> _removeAnimeDownload(VideoDownloadTask t) async {
    await VideoDownloadManager.instance.remove(t.key);
    await reload();
    if (!mounted) return;
    AppToast.info(context, '已删除动漫下载');
  }

  /// 重新下载失败的动漫单集：复用任务原信息走 start 入口（key 相同会
  /// 直接恢复原任务，无需先删再下——重试即把 failed/canceled 拉回
  /// downloading）。
  Future<void> _retryAnimeDownload(VideoDownloadTask t) async {
    try {
      final started = await VideoDownloadManager.instance.retry(t.key);
      if (!mounted) return;
      if (started) {
        AppToast.info(context, '已重新加入下载队列');
      } else {
        AppToast.info(context, '该任务已在下载或已删除', duration: const Duration(seconds: 2));
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '重试失败，请稍后再试');
      ErrorLogger.instance.warn('anime download retry failed: $e');
    }
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

  Future<void> _confirmRemoveAnimeTitle(VideoDownloadTask t) async {
    final tasks = _animeDownloads.where((x) => x.title == t.title).toList();
    if (tasks.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('删除该番剧全部下载'),
        content: Text('确定删除《${t.title}》的全部 ${tasks.length} 条下载记录和文件？'),
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
      for (final x in tasks) {
        try {
          await _removeAnimeDownload(x);
        } catch (e) {
          ErrorLogger.instance.warn('remove anime title failed key=${x.key}: $e');
        }
      }
      await reload();
    }
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
                    tooltip: _checkingUpdate ? '停止检查' : '检查更新',
                    onPressed: _checkUpdates,
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
                  TextButton.icon(
                    onPressed: _checkUpdates,
                    icon: _checkingUpdate
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.system_update_alt_rounded,
                            size: 18),
                    label: Text(_checkingUpdate
                        ? (_checkProgress.isEmpty
                            ? '检查中…'
                            : _checkProgress)
                        : '检查更新'),
                    style: TextButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
              sliver: SliverMainAxisGroup(
                slivers: [
                  // 列表头：数量 + 清空入口（与平板端 _buildRecentList 同款）。
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Text(
                            '共 ${_recent.length} 条',
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  T.color(scheme.onSurface, TextTier.low,
                                      brightness: scheme.brightness),
                            ),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _confirmClearRecent,
                            icon: const Icon(Icons.delete_sweep_outlined,
                                size: 16),
                            label: const Text('清空'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverList.separated(
                    itemCount:
                        _getRecentCount() + (_recentHidden > 0 ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (c, i) {
                      if (i == _getRecentCount()) {
                        // 截断 6 条后的「查看全部」入口：展开完整列表，避免
                        // 超过 6 条的最近阅读藏在列表深处无法触达。
                        return Center(
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _recentExpanded = true),
                            icon:
                                const Icon(Icons.expand_more_rounded, size: 18),
                            label: Text('查看全部 ${_recent.length} 条'),
                          ),
                        );
                      }
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 600),
                          child: _ReadingCard(
                            history: _recent[i],
                            progress: _progressOf(_recent[i]),
                            // 小说历史无章内进度，不渲染进度条（避免 0.3 假进度）。
                            showProgress:
                                SourceManager.novelById(_recent[i]
                                    .book
                                    .sourceId) ==
                                null,
                            onTap: () => _openFromHistory(_recent[i]),
                            onLongPressDelete: () =>
                                _confirmRemoveRecent(_recent[i]),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            )
        else if (_tab == 1) ...[
          if (_items.isNotEmpty)
            SliverToBoxAdapter(child: _shelfFilterBar()),
          if (_items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: Column(
                  children: [
                    const _TabEmpty(
                      icon: Icons.bookmark_outline_rounded,
                      text: '书架还是空的，去首页收藏几部吧',
                      subtitle: '在作品详情页点击收藏，就能在书架里随时找到',
                    ),
                    // 空态自带管理入口：否则无收藏用户永远建不出第一个分类。
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.onGotoHome != null)
                          FilledButton.tonalIcon(
                            onPressed: widget.onGotoHome,
                            icon: const Icon(Icons.explore_outlined, size: 18),
                            label: const Text('去首页逛逛'),
                          ),
                        if (widget.onGotoHome != null)
                          const SizedBox(width: 12),
                        TextButton.icon(
                          onPressed: _showFolderManager,
                          icon: const Icon(Icons.create_new_folder_outlined,
                              size: 18),
                          label: const Text('管理分类'),
                        ),
                      ],
                    ),
                  ],
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
                          subtitle: _resumeTextOf(item),
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
          BookshelfDownloadView(
            scheme: scheme,
            mangaDownloads: _mangaDownloads,
            animeDownloads: _animeDownloads,
            onClearManga: _confirmClearMangaAll,
            onRetryAllManga: _retryAllManga,
            onOpenMangaDetail: _openDownloadDetail,
            onRetryManga: _retryMangaDownload,
            onRemoveManga: _confirmRemoveManga,
            onRemoveMangaBook: _confirmRemoveMangaBook,
            onClearAnime: _confirmClearAnimeAll,
            onOpenAnime: _openAnimeDownload,
            onRetryAnime: _retryAnimeDownload,
            onRemoveAnime: _confirmRemoveAnime,
            onRemoveAnimeTitle: _confirmRemoveAnimeTitle,
          )
        else
          _buildBookmarkList(scheme),
      ],
      ),
    );
  }

  /// 由书架 chapters + 历史页码计算阅读进度。
  /// 章节索引 Map 在 [_items] 更新时重建一次，避免每本历史记录
  /// 都线性扫全书架（O(n×m) → O(n+m)）。
  /// 网格书架卡的续读副标题：查该书的最近一条历史（按 book.key 聚合，
  /// `_recent` 已按时间倒序，取首条即最新），有页码显示「续读 第N话 · 第M页」，
  /// 无页码只显示章节名；无历史返回空串（卡片不渲染副标题）。
  /// key 与 _ShelfCard.hasUpdate 同款：sourceId 优先自字段，缺失回退 store 反查。
  String _resumeTextOf(ComicDetail item) {
    final key =
        '${item.sourceId ?? BookshelfStore.sourceIdOf(item.id) ?? ''}/${item.id}';
    return resumeTextOf(key, _recent);
  }

  double _progressOf(HistoryEntry h) {
    if (h.hasPage && h.chapterTotalPages > 0 && h.pageIndex >= 0) {
      return ((h.pageIndex + 1) / h.chapterTotalPages).clamp(0.0, 1.0);
    }
    final chapters = _chapterIndex[h.book.comicId];
    if (chapters == null) return 0.3;
    if (chapters.isEmpty) return 0;
    final idx = chapters.indexOf(h.chapterId);
    if (idx < 0) return 0.3;
    return ((idx + 1) / chapters.length).clamp(0.0, 1.0);
  }

  /// 根据屏幕尺寸返回最近阅读列表的最大显示数量。
  /// 手机端默认截断到 6 条，用户点「查看全部」后展开完整列表。
  int _getRecentCount() {
    final h = MediaQuery.of(context).size.height;
    if (Responsive.isTablet(context)) {
      return h > 900 ? 10 : 8;
    }
    if (_recentExpanded) return _recent.length;
    return _recent.length > 6 ? 6 : _recent.length;
  }

  /// 手机端最近阅读被截断时的显示差异（0 表示不截断）。
  int get _recentHidden => _recent.length - _getRecentCount();

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
    if (sid != null) {
      BookshelfStore.remove(sid, d.id);
      // 失效详情侧的书架态缓存：否则再进详情页 comicInShelfProvider 还
      // 缓存着「已在书架」，显示与实际相反（跨页不同步）。
      ref.invalidate(comicInShelfProvider((sid, d.id)));
    }
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

  /// 历史记录同时存漫画/小说阅读进度（视频观看进度走 [VideoRecord] 独立存储）。
  /// 按 sourceId 是否小说源分流：小说进小说详情页，其余进漫画详情页。
  void _openFromHistory(HistoryEntry h) {
    final isNovel = SourceManager.novelById(h.book.sourceId) != null;
    final page = isNovel
        ? NovelDetailPage(
            sourceId: h.book.sourceId,
            novelId: h.book.comicId,
            name: h.book.name,
            pic: h.book.pic,
          )
        : DetailPage(
            sourceId: h.book.sourceId,
            comicId: h.book.comicId,
            name: h.book.name,
            pic: h.book.pic,
          );
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  /// 长按最近阅读卡 → 删除该条历史。
  void _confirmRemoveRecent(HistoryEntry h) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('删除记录'),
        content: Text('确定删除「${h.book.name}」的这条阅读记录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _removeRecent(h);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 删除单条历史（无 confirm，由调用方弹窗确认；随后刷新最近阅读）。
  Future<void> _removeRecent(HistoryEntry h) async {
    await LocalStore.removeHistoryEntry(h);
    await reload();
    if (!mounted) return;
    AppToast.info(context, '已删除该条阅读记录');
  }

  /// 清空最近阅读（含确认；与设置页「清空阅读历史」同语义，书架内直达）。
  Future<void> _confirmClearRecent() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('清空最近阅读'),
        content: const Text('确定清空全部阅读记录？此操作不可恢复。'),
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
      await LocalStore.clearHistory();
      await reload();
      if (!mounted) return;
      AppToast.info(context, '已清空最近阅读');
    }
  }

  /// 书签直达：先向源解析该章节的目录（拿到全章节列表供连读/切章），
  /// 再携带书签页码直接进入阅读器。
  Future<void> _openBookmark(ComicBookmark m) async {
    if (_openingBookmark) return; // 防连点：detail await 期间忽略重复点击
    _openingBookmark = true;
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
          transitionDuration: context.uiStyle == UIStyle.minimalist
              ? const Duration(milliseconds: 320)
              : StyleTokens.transitionDuration(context),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
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
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '书签跳转失败，请重试');
      ErrorLogger.instance.warn('bookmark jump failed: $e');
    } finally {
      _openingBookmark = false;
    }
  }

  bool _openingBookmark = false; // 书签跳转防连点锁

  Future<void> _deleteBookmark(ComicBookmark m) async {
    await LocalStore.removeBookmark(
        m.book.sourceId, m.book.comicId, m.chapterId, m.pageIndex);
    reload();
  }

  /// 清空全部手动书签（含确认；与最近阅读/动画记录 Tab 的清空入口对称）。
  Future<void> _confirmClearBookmarks() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('清空书签'),
        content:
            Text('确定清空全部 ${_bookmarks.length} 条手动书签？此操作不可恢复。'),
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
      await LocalStore.clearBookmarks();
      await reload();
      if (!mounted) return;
      AppToast.info(context, '已清空书签');
    }
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
        AppToast.error(context, '该视频源已不可用，无法续播');
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
        ErrorLogger.instance.warn('video resume failed: $e');
        if (mounted) {
          Navigator.of(context).pop();
          AppToast.error(context, '续播失败，请检查网络后重试');
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
            webChannelBuilder: animePlayerWebChannel,
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

  /// 清空全部动画观看记录（含确认；与最近阅读/下载 Tab 的清空入口对称）。
  Future<void> _confirmClearVideos() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sheet)),
        title: const Text('清空动画记录'),
        content: Text('确定清空全部 ${_videos.length} 条动画观看记录？此操作不可恢复。'),
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
      await LocalStore.clearVideoRecords();
      await reload();
      if (!mounted) return;
      AppToast.info(context, '已清空动画记录');
    }
  }

  void _showCardAction(ComicDetail d) {
    showResponsiveBottomSheet(
      context: context,
      shape: _BookshelfStyleDecorations.topSheetShape(context),
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
      shape: _BookshelfStyleDecorations.topSheetShape(context),
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
      shape: _BookshelfStyleDecorations.topSheetShape(context),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // 弹窗内分类列表 + 页面筛选栏的同步刷新（增删改后两处一起更新）。
          Future<void> refresh() async {
            final fs = await BookshelfStore.folders();
            // 弹窗列表只展示自建分类（与初始 userFolders 一致），
            // 页面筛选栏仍用全量 fs（含「全部/默认分类」）。
            folders = fs
                .where((f) =>
                    f['id'] != BookshelfStore.allFolderId &&
                    f['id'] != BookshelfStore.defaultFolderId)
                .toList();
            setSheetState(() {});
            // 页面 _folders/_folderFilter 由 bookshelfDataProvider 经
            // foldersVersionProvider 自动失效重灌（_applyData），这里不再
            // 手动复制一份，避免双维护（增删改后 provider 链已同步）。
            if (mounted) _applyFilters();
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
      shape: _BookshelfStyleDecorations.topSheetShape(context),
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
    if (_checkingUpdate) {
      // 转圈时再点 = 停止本轮检查（书架几百本时等待过长，需要可中断）。
      _cancelUpdateCheck = true;
      return;
    }
    setState(() {
      _checkingUpdate = true;
      _cancelUpdateCheck = false;
    });
    try {
      final updated = await ShelfUpdater.checkNow(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => _checkProgress = '$done/$total');
        },
        shouldCancel: () => _cancelUpdateCheck,
      );
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      if (updated == null) return;
      _updateCount = updated.length;
      if (updated.isEmpty || _updateCount == 0) return;
      AppToast.show(
        context,
        '${updated.length} 部作品有更新${_newNames(updated)}',
        duration: const Duration(seconds: 4),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      AppToast.error(context, '检查更新失败，请稍后重试');
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
          // 切到书签/下载页时刷新（阅读器/详情页里可能刚增删了书签或下载任务）
          if (v == 4 || v == 3) reload();
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
                        tooltip: '清空搜索',
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
            itemCount: _chipList().length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _chipList()[i],
          ),
        ),
      ],
    );
  }

  /// 筛选条唯一数据源：一次性生成 widget 列表，避免 LazyList
  /// 每项都从 idx=0 线性推进（数百标签时 O(n²)）。
  List<Widget> _chipList() {
    final folderSel = _folderFilter ?? BookshelfStore.allFolderId;
    final list = <Widget>[
      _sortChip(),
      if (_allStatuses.isNotEmpty) _statusChip(),
      _chip('全部', folderSel == BookshelfStore.allFolderId, () {
        setState(() {
          _folderFilter = null;
          _applyFilters();
        });
      }),
      for (final f in _folders)
        if (f['id'] != BookshelfStore.allFolderId)
          _chip(f['name'] as String, folderSel == (f['id'] as String), () {
            setState(() {
              _folderFilter = f['id'] as String;
              _applyFilters();
            });
          })
    ];
    if (_folders.isNotEmpty) list.add(_manageFolderChip());
    list.add(_chip('全部', _tagFilter == null, () => setState(() {
      _tagFilter = null;
      _applyFilters();
    })));
    for (final tag in _allTags) {
      list.add(_chip(tag, _tagFilter == tag, () => setState(() {
        _tagFilter = tag;
        _applyFilters();
      })));
    }
    return list;
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

  /// 续读位置副标题（如「续读 第3话 · 第5页」）；空则不显示。
  /// 数据来自书架 State 的 `_recent`（历史记录聚合，按 book.key 查找）。
  final String? subtitle;
  const _ShelfCard({
    required this.item,
    required this.editing,
    required this.onTap,
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
