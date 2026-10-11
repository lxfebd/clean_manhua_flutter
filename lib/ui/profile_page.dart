import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../net/bookshelf_store.dart';
import '../net/error_logger.dart';
import '../net/image_cache.dart';
import '../sources/comic_source.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../utils/booklist_text.dart';
import '../net/local_store.dart';
import '../net/update_checker.dart';
import 'novel_reader_page.dart';
import 'profile_providers.dart';
import 'reader_page.dart';
import 'responsive.dart';
import 'settings_page.dart';
import 'style_scope.dart';
import 'style_tokens.dart';
import 'theme_controller.dart';
import 'tokens.dart';
import 'year_report_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/squircle.dart';
import 'widgets/app_toast.dart';
import 'widgets/motion.dart';
import 'widgets/row_separator.dart';
import 'widgets/settings_row.dart';
import 'widgets/state_view.dart';
import 'widgets/tap_target.dart';

part 'profile_widgets.dart';

/// 我的页三风格 helper：为 _UserCard / _ReadingStatsCard / _StatsCard / _MenuCard
/// 及所有 BottomSheet 容器提供按风格分派的装饰属性。
///
/// 极简分支完全等价于历史实现（BoxShape.circle / hairline 0.08 描边 / 圆角=R.hero / R.sheet）；
/// 小米/苹果只影响视觉属性（圆角档、描边/阴影、渐变底），不碰布局/热区。
class _CardD {
  const _CardD._();

  /// 四张主卡片统一装饰：圆角 + 描边 + 小米彩色阴影 + 小米渐变底。
  /// 主卡是大卡 → hero 槽位：极简锁 R.hero=16（现状），小米 28 / 苹果 16；
  /// 描边极简 hairline 0.08，小米无描边靠彩色阴影，苹果 0.5px 细线。
  static BoxDecoration cardDeco(BuildContext c, ColorScheme s) {
    final r = StyleTokens.heroRadius(c, R.hero);
    Border? b;
    if (c.uiStyle == UIStyle.minimalist) {
      b = Border.all(
        color: T.color(s.onSurface, TextTier.hairline,
            brightness: s.brightness),
        width: 1,
      );
    } else {
      final side = StyleTokens.cardBorder(c);
      b = side == null ? null : Border.fromBorderSide(side);
    }
    return BoxDecoration(
      gradient: StyleTokens.cardGradient(c),
      color: s.surface,
      borderRadius: BorderRadius.circular(r),
      border: b,
      boxShadow: StyleTokens.cardShadow(c),
    );
  }
}

/// 我的页面（对齐 UI_v2 S8）：设置入口 + 用户卡 + 三格统计 + 功能列表。
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key, this.onSwitchTab});

  /// 跳到主导航某个 Tab（0=首页 1=书架 2=工具/下载）。
  final ValueChanged<int>? onSwitchTab;

  @override
  ConsumerState<ProfilePage> createState() => ProfilePageState();
}

class ProfilePageState extends ConsumerState<ProfilePage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = ref.watch(profileProvider);
    return stats.when(
      loading: () => Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (_, __) => Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 44, color: scheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              Text('个人页数据加载失败',
                  style: TextStyle(
                      fontSize: 14,
                      color: scheme.onSurface.withValues(alpha: 0.6))),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: refresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
      data: (data) => Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          bottom: false,
          child: Responsive.isExpanded(context)
              ? _buildTablet(theme, scheme, data)
              : RefreshIndicator(
                  onRefresh: refresh,
                  color: scheme.primary,
                  child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                      Responsive.pagePadding(context), 10,
                      Responsive.pagePadding(context), 110),
                  children: _buildContent(theme, scheme, data),
                ),
                ),
        ),
      ),
    );
  }

  Widget _buildTablet(ThemeData theme, ColorScheme scheme, ProfileStats data) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    final bottomPad = isDesktop ? 24.0 : (Responsive.isTablet(context) ? 24.0 : 110.0);

    // 左右两栏作为一个整体居中（避免各自散落、中间留白过大）。
    // 二级限宽已移除：主框架 main_shell 已用 MaxWidthContainer 统一收口
    // （1200/1400），本页不再叠加 maxWidth 800，避免大屏内容被压窄。
    // 桌面信息密度更高，左右栏各加宽一档。
    final leftPanelWidth = isDesktop ? 384.0 : 360.0;
    final rightPanelWidth = isDesktop ? 420.0 : 380.0;

    final settingsButton = PressableScale(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsPage()),
        );
      },
      scale: 0.92,
      child: const _SettingsButton(),
    );
    final leftList = ListView(
      physics: isDesktop
          ? const ClampingScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, isDesktop ? 4 : 10, 8, bottomPad),
      children: [
        // 桌面页头不在此列（改为整页顶部），仅平板保留内联标题行。
        if (!isDesktop)
          FadeSlideIn(
            duration: const Duration(milliseconds: 380),
            child: Row(
              children: [
                Text('我的', style: theme.textTheme.displaySmall),
                const Spacer(),
                settingsButton,
              ],
            ),
          ),
        if (!isDesktop) const SizedBox(height: 18),
        const FadeSlideIn(
            delay: Duration(milliseconds: 80), child: _UserCard()),
        const SizedBox(height: 14),
        FadeSlideIn(
            delay: const Duration(milliseconds: 120),
            child: _ReadingStatsCard(
                today: data.todaySeconds,
                week: data.weekSeconds,
                total: data.totalSeconds,
                onTap: _showReadingReport)),
        const SizedBox(height: 14),
        FadeSlideIn(
            delay: const Duration(milliseconds: 160),
            child: _StatsCard(
                favorites: data.favorites,
                history: data.history.length,
                downloads: data.downloads.length,
                onFavorites: () => widget.onSwitchTab?.call(4),
                onHistory: _showHistory,
                onDownloads: () => widget.onSwitchTab?.call(4))),
      ],
    );

    final twoColumns = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 左侧：用户卡 + 统计 ──────────────────────
            SizedBox(
              width: leftPanelWidth,
              // 桌面去掉下拉刷新（右上角已有刷新入口）。
              child: isDesktop
                  ? leftList
                  : RefreshIndicator(
                      onRefresh: refresh,
                      color: scheme.primary,
                      child: leftList,
                    ),
            ),
            const SizedBox(width: 24),
            // ── 右侧：功能列表 ─────────────────────────
            SizedBox(
              width: rightPanelWidth,
              child: ListView(
                physics: isDesktop
                    ? const ClampingScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(8, isDesktop ? 4 : 10, 16, bottomPad),
                children: [
                  FadeSlideIn(
                      delay: const Duration(milliseconds: 240),
                      child: _MenuCard(
                          dark:
                              ref.watch(themeControllerProvider).themeMode ==
                                  ThemeMode.dark,
                          onDarkChanged: (v) {
                            ref
                                .read(themeControllerProvider.notifier)
                                .setDark(v);
                            LocalStore.setDarkMode(v);
                          },
                          onFavorites: () => widget.onSwitchTab?.call(4),
                          onHistory: _showHistory,
                          onDownloads: () => widget.onSwitchTab?.call(4),
                          onHelp: _showHelp,
                          onExportBooklist: _exportBooklist,
                          onExportBooklistImage: _exportBooklistImage,
                          onImportBooklist: _importBooklist)),
                ],
              ),
            ),
          ],
    );

    if (!isDesktop) return twoColumns;
    // 桌面：Fluent 页头（大标题 + 设置命令按钮）置于两栏之上。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopPageHeader(
          title: '我的',
          subtitle: '账户 · 阅读统计 · 设置',
          actions: [settingsButton],
        ),
        Expanded(child: twoColumns),
      ],
    );
  }

  List<Widget> _buildContent(ThemeData theme, ColorScheme scheme,
      ProfileStats data) {
    return [
            // ── 顶栏：我的 + 设置 ─────────────────────────────
            FadeSlideIn(
              duration: const Duration(milliseconds: 380),
              child: Row(
                children: [
                  Text('我的', style: theme.textTheme.displaySmall),
                  const Spacer(),
                  PressableScale(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SettingsPage()),
                      );
                    },
                    scale: 0.92,
                    child: const _SettingsButton(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // ── 用户卡 ─────────────────────────────────────────
            FadeSlideIn(
              delay: const Duration(milliseconds: 80),
              child: const _UserCard(),
            ),
            const SizedBox(height: 14),
            // ── 阅读统计 ───────────────────────────────────────
            FadeSlideIn(
              delay: const Duration(milliseconds: 120),
              child: _ReadingStatsCard(
                today: data.todaySeconds,
                week: data.weekSeconds,
                total: data.totalSeconds,
                onTap: _showReadingReport,
              ),
            ),
            const SizedBox(height: 14),
            // ── 三格统计：收藏 / 阅读记录 / 已下载 ──────────────
            FadeSlideIn(
              delay: const Duration(milliseconds: 160),
              child: _StatsCard(
                favorites: data.favorites,
                history: data.history.length,
                downloads: data.downloads.length,
                onFavorites: () => widget.onSwitchTab?.call(4),
                onHistory: _showHistory,
                onDownloads: () => widget.onSwitchTab?.call(4),
              ),
            ),
            const SizedBox(height: 14),
            // ── 功能列表 ───────────────────────────────────────
            FadeSlideIn(
              delay: const Duration(milliseconds: 240),
              child: _MenuCard(
                dark:
                    ref.watch(themeControllerProvider).themeMode ==
                        ThemeMode.dark,
                onDarkChanged: (v) {
                  ref.read(themeControllerProvider.notifier).setDark(v);
                  LocalStore.setDarkMode(v);
                },
                onFavorites: () => widget.onSwitchTab?.call(4),
                onHistory: _showHistory,
                onDownloads: () => widget.onSwitchTab?.call(4),
                onHelp: _showHelp,
                onExportBooklist: _exportBooklist,
                onExportBooklistImage: _exportBooklistImage,
                onImportBooklist: _importBooklist,
              ),
            ),
        ];
  }

  /// 下拉刷新统计（切 Tab 回来时由外部调用）。
  Future<void> refresh() => _refresh();

  void _showHistory() {
    final data = ref.read(profileProvider).value;
    // 历史存储上限 200 条，弹窗全量展示（原只取最近 30，翻旧记录要
    // 反复退出重进）。条数不多，轻量 ListTile 全 build 无压力。
    final entries = data?.history ?? const <HistoryEntry>[];
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _HistorySheet(
        entries: entries,
        onTap: _openHistoryEntry,
      ),
    ).then((_) {
      if (mounted) _refresh();
    });
  }

  /// 历史直达进行中：防止 detail 解析期间连点其他条目叠出双阅读器。
  bool _historyJumping = false;

  /// 阅读历史直达：先向源解析该作品目录（拿章节列表供阅读器连读/切章），
  /// 再携带上次读到的位置直接进入阅读器。漫画/小说按源类型分流。
  /// 网络失败不阻塞浏览：历史面板照常展示，仅对失败项提示。
  Future<void> _openHistoryEntry(HistoryEntry h) async {
    // 收起历史弹窗：detail 解析可能耗时（15s 超时），期间 sheet 停留
    // 会让用户误以为还能再点其他条目（连点会叠双阅读器）。先关面板
    // 再解析，解析失败由 toast 提示，不打扰浏览。
    Navigator.of(context).pop();
    if (_historyJumping) return;
    _historyJumping = true;
    try {
      await _openHistoryEntryInner(h);
    } finally {
      _historyJumping = false;
    }
  }

  Future<void> _openHistoryEntryInner(HistoryEntry h) async {
    final b = h.book;
    // 按 sourceId 是否小说源分流（与书架 _openFromHistory 同规则）。
    if (SourceManager.novelById(b.sourceId) != null) {
      final src = SourceManager.novelById(b.sourceId);
      if (src == null) {
        if (mounted) AppToast.error(context, '该小说源已不可用');
        return;
      }
      try {
        final detail = await src
            .detail(b.comicId)
            .timeout(const Duration(seconds: 15));
        if (!mounted) return;
        final ch = detail.chapters.isNotEmpty
            ? detail.chapters.firstWhere(
                (c) => c.id == h.chapterId,
                orElse: () => detail.chapters.first,
              )
            : NovelChapter(h.chapterId, h.chapterTitle);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NovelReaderPage(
              sourceId: b.sourceId,
              novelId: b.comicId,
              chapterId: ch.id,
              title: ch.title,
              novelName: detail.name,
              novelPic: detail.pic ?? '',
              novelAuthor: detail.author ?? '',
              initialOffset: h.scrollOffset,
            ),
          ),
        );
      } catch (e) {
        ErrorLogger.instance.warn('history novel jump failed: $e');
        if (mounted) AppToast.error(context, '跳转失败，该作品可能已下架');
      }
      return;
    }
    final src = SourceManager.byId(b.sourceId);
    try {
      final detail = await src.detail(b.comicId).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final chapters = detail.chapters;
      final ch = chapters.isNotEmpty
          ? chapters.firstWhere((c) => c.id == h.chapterId,
              orElse: () => chapters.first)
          : Chapter(h.chapterId, h.chapterTitle);
      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, __, ___) => ReaderPage(
            sourceId: b.sourceId,
            comicId: b.comicId,
            chapterId: ch.id,
            title: ch.title,
            comicName: detail.name,
            comicPic: detail.pic ?? '',
            comicAuthor: detail.author ?? '',
            chapters: chapters,
            initialPage: h.pageIndex,
            initialOffset: h.scrollOffset,
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
      ErrorLogger.instance.warn('history comic jump failed: $e');
      if (mounted) AppToast.error(context, '跳转失败，该作品可能已下架');
    }
  }

  void _showHelp() {
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _HelpSheet(),
    );
  }

  /// 阅读报告弹窗：周报（最近 7 天柱状图）/ 年度报告（12 个月柱状图）。
  Future<void> _showReadingReport() async {
    final days = await LocalStore.recentReadingDays(7);
    if (!mounted) return;
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ReadingReportSheet(
        days: days,
        onYearTap: _showYearReport,
      ),
    ).then((_) {
      if (mounted) _refresh();
    });
  }

  /// 年度阅读报告：跳转全屏可视化页（YearReportPage）。
  Future<void> _showYearReport() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const YearReportPage()),
    );
    if (mounted) _refresh();
  }

  /// 刷新统计：使 profileProvider 失效并等待新数据灌入。
  /// 供下拉刷新、main_shell 与测试复用。
  Future<void> _refresh() async {
    ref.invalidate(profileProvider);
    try {
      await ref.read(profileProvider.future).then((_) {});
    } catch (_) {
      // 聚合失败：错误态已由 build 的 when(error) 呈现，这里无需额外处理。
    }
  }

  /// 书单文本导出：书架全部条目转纯文本，写入剪贴板并提示。
  Future<void> _exportBooklist() async {
    final books = BookshelfStore.listAll();
    if (books.isEmpty) {
      if (!mounted) return;
      AppToast.info(context, '书架为空，暂无内容可导出');
      return;
    }
    final sb = StringBuffer()
      ..writeln('星漫匣 · 我的书单（共 ${books.length} 本）')
      ..writeln('导出时间：${DateTime.now().toString().substring(0, 16)}')
      ..writeln('─────────────');
    for (var i = 0; i < books.length; i++) {
      final b = books[i];
      final author = (b.author?.isNotEmpty ?? false) ? b.author : null;
      final status = (b.status?.isNotEmpty ?? false) ? b.status : null;
      sb.writeln('${i + 1}. ${b.name}'
          '${author != null ? ' — $author' : ''}'
          '${status != null ? '（$status）' : ''}');
    }
    final text = sb.toString();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppToast.show(
      context,
      '书单已复制到剪贴板',
      action: SnackBarAction(label: '查看', onPressed: () => _previewBooklist(text)),
    );
  }

  /// 书单文本预览弹窗。
  void _previewBooklist(String text) {
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TextExportSheet(title: '我的书单', text: text),
    );
  }

  /// 书单图片导出：预加载全部封面 → 渲染海报网格 → 截图为 PNG 存到应用目录。
  Future<void> _exportBooklistImage() async {
    final books = BookshelfStore.listAll();
    if (books.isEmpty) {
      if (!mounted) return;
      AppToast.info(context, '书架为空，暂无内容可导出');
      return;
    }
    if (!mounted) return;
    // 先展示生成中弹窗，再开并行预加载封面（超时 8s/张，失败置空走占位图）。
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ImageLoadingSheet(),
    );
    // 按 books 顺序填位（covers[i] = 第 i 本书封面）：Future.wait 是并发完成，
    // 直接 add 会按完成先后而非书架顺序，导致海报 books[i] 配到别书封面。
    final covers = List<Uint8List?>.filled(books.length, null);
    await Future.wait([
      for (var i = 0; i < books.length; i++)
        (() async {
          try {
            final url = books[i].pic;
            if (url == null || url.isEmpty) return;
            covers[i] = await ImageCacheManager.load(url).timeout(
                const Duration(seconds: 8));
          } catch (_) {}
        })(),
    ]);
    if (!mounted) return;
    final boundaryKey = GlobalKey();
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ImageExportSheet(
        books: books,
        covers: covers,
        boundaryKey: boundaryKey,
        onSave: () async => _savePoster(boundaryKey),
      ),
    );
  }

  /// 把海报 [boundaryKey] 截图保存为 PNG，返回保存路径（失败返回 null）。
  Future<String?> _savePoster(GlobalKey boundaryKey) async {
    final renderObject =
        boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (renderObject == null) return null;
    try {
      final image = await renderObject.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      final dir = await getApplicationSupportDirectory();
      final outDir = Directory('${dir.path}/exports');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final f = File('${outDir.path}/booklist_'
          '${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// 书单导入：读剪贴板文本 → 解析条目 → 逐本跨源搜索 → 确认后一键入书架。
  Future<void> _importBooklist() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text ?? '';
    final entries = BooklistText.parse(text);
    if (entries.isEmpty) {
      if (!mounted) return;
      AppToast.info(context, '剪贴板中没有可识别的书单文本（格式：1. 书名 — 作者）');
      return;
    }
    if (!mounted) return;
    // 预览 + 逐本搜索在弹窗内进行，便于展示过程与失败项。
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ImportBooklistSheet(entries: entries),
    );
  }
}

/// 统一设置入口按钮：浅底 + 圆角。
