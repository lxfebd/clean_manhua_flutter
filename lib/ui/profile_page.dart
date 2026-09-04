import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../net/bookshelf_store.dart';
import '../net/local_store.dart';
import '../net/update_checker.dart';
import 'responsive.dart';
import 'settings_page.dart';
import 'tokens.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';
import 'widgets/settings_row.dart';
import 'widgets/state_view.dart';
import 'widgets/tap_target.dart';

/// 我的页面（对齐 UI_v2 S8）：设置入口 + 用户卡 + 三格统计 + 功能列表。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.onSwitchTab});

  /// 跳到主导航某个 Tab（0=首页 1=书架 2=工具/下载）。
  final ValueChanged<int>? onSwitchTab;

  @override
  State<ProfilePage> createState() => ProfilePageState();
}

class ProfilePageState extends State<ProfilePage> {
  List<HistoryEntry> _history = [];
  List<DownloadRecord> _downloads = [];
  int _favorites = 0;
  bool _loaded = false;
  bool _dark = false;
  int _todaySec = 0;
  int _weekSec = 0;
  int _totalSec = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final h = await LocalStore.history();
    final d = await LocalStore.downloads();
    final fav = BookshelfStore.listAll().length;
    final dark = await LocalStore.darkMode();
    final today = await LocalStore.todayReadingSeconds();
    final week = await LocalStore.weekReadingSeconds();
    final total = await LocalStore.totalReadingSeconds();
    if (mounted) {
      setState(() {
        _history = h;
        _downloads = d;
        _favorites = fav;
        _dark = dark;
        _todaySec = today;
        _weekSec = week;
        _totalSec = total;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (!_loaded) {
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Responsive.isExpanded(context)
            ? _buildTablet(theme, scheme)
            : RefreshIndicator(
                onRefresh: _load,
                color: scheme.primary,
                child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                    Responsive.pagePadding(context), 10,
                    Responsive.pagePadding(context), 110),
                children: _buildContent(theme, scheme),
              ),
              ),
      ),
    );
  }

  Widget _buildTablet(ThemeData theme, ColorScheme scheme) {
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
                today: _todaySec,
                week: _weekSec,
                total: _totalSec,
                onTap: _showReadingReport)),
        const SizedBox(height: 14),
        FadeSlideIn(
            delay: const Duration(milliseconds: 160),
            child: _StatsCard(
                favorites: _favorites,
                history: _history.length,
                downloads: _downloads.length,
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
                      onRefresh: _load,
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
                          dark: _dark,
                          onDarkChanged: (v) async {
                            YingManHeApp.of(context)?.setDark(v);
                            await LocalStore.setDarkMode(v);
                            if (mounted) setState(() => _dark = v);
                          },
                          onFavorites: () => widget.onSwitchTab?.call(4),
                          onHistory: _showHistory,
                          onDownloads: () => widget.onSwitchTab?.call(4),
                          onHelp: _showHelp)),
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

  List<Widget> _buildContent(ThemeData theme, ColorScheme scheme) {
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
                today: _todaySec,
                week: _weekSec,
                total: _totalSec,
                onTap: _showReadingReport,
              ),
            ),
            const SizedBox(height: 14),
            // ── 三格统计：收藏 / 阅读记录 / 已下载 ──────────────
            FadeSlideIn(
              delay: const Duration(milliseconds: 160),
              child: _StatsCard(
                favorites: _favorites,
                history: _history.length,
                downloads: _downloads.length,
                onFavorites: () => widget.onSwitchTab?.call(1),
                onHistory: _showHistory,
                onDownloads: () => widget.onSwitchTab?.call(2),
              ),
            ),
            const SizedBox(height: 14),
            // ── 功能列表 ───────────────────────────────────────
            FadeSlideIn(
              delay: const Duration(milliseconds: 240),
              child: _MenuCard(
                dark: _dark,
                onDarkChanged: (v) async {
                  YingManHeApp.of(context)?.setDark(v);
                  await LocalStore.setDarkMode(v);
                  if (mounted) setState(() => _dark = v);
                },
                onFavorites: () => widget.onSwitchTab?.call(1),
                onHistory: _showHistory,
                onDownloads: () => widget.onSwitchTab?.call(2),
                onHelp: _showHelp,
              ),
            ),
        ];
  }

  /// 下拉刷新统计（切 Tab 回来时由外部调用）。
  Future<void> refresh() => _load();

  void _showHistory() {
    final entries = _history.take(30).toList();
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _HistorySheet(entries: entries),
    ).then((_) {
      if (mounted) _load();
    });
  }

  void _showHelp() {
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _HelpSheet(),
    );
  }

  /// 阅读周报弹窗：最近 7 天每天的阅读时长柱状图 + 汇总。
  Future<void> _showReadingReport() async {
    final days = await LocalStore.recentReadingDays(7);
    if (!mounted) return;
    showResponsiveBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ReadingReportSheet(days: days),
    ).then((_) {
      if (mounted) _load();
    });
  }
}

/// 统一设置入口按钮：浅底 + 圆角。
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 视觉保持 36×36，命中区由 TapTargetMin 补到 44×44。
    return TapTargetMin(
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color:
              T.color(scheme.onSurface, TextTier.fill, brightness: scheme.brightness),
          borderRadius: BorderRadius.circular(R.control),
        ),
        child: Icon(
          Icons.settings_rounded,
          size: 19,
          color: T.color(scheme.onSurface, TextTier.low,
              brightness: scheme.brightness),
        ),
      ),
    );
  }
}

/// 用户卡：本地使用提示（无账号体系）。
class _UserCard extends StatelessWidget {
  const _UserCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(S.x16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(R.hero),
        border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness)),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.1),
            ),
            child: Icon(
              Icons.person_rounded,
              size: 28,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本地使用', style: text.titleLarge),
                const SizedBox(height: 3),
                Text(
                  '收藏与阅读记录保存在本机',
                  style: text.bodySmall?.copyWith(
                    color: T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: T.color(scheme.onSurface, TextTier.fill,
                  brightness: scheme.brightness),
              borderRadius: BorderRadius.circular(R.pill),
            ),
            child: Text(
              '本地模式',
              style: text.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: T.color(scheme.onSurface, TextTier.low,
                    brightness: scheme.brightness),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 阅读统计卡：今日/本周/累计 + 点击进入周报。
class _ReadingStatsCard extends StatelessWidget {
  final int today;
  final int week;
  final int total;
  final VoidCallback onTap;
  const _ReadingStatsCard({
    required this.today,
    required this.week,
    required this.total,
    required this.onTap,
  });

  String _fmt(int sec) {
    if (sec < 60) return '$sec秒';
    if (sec < 3600) return '${sec ~/ 60}分钟';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return m > 0 ? '$h小时$m分钟' : '$h小时';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.all(S.x16),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.hero),
          border: Border.all(
              color: T.color(scheme.onSurface, TextTier.hairline,
                  brightness: scheme.brightness)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(R.control),
                  ),
                  child: Icon(Icons.bar_chart_rounded,
                      size: 17, color: scheme.primary),
                ),
                const SizedBox(width: 10),
                Text('阅读统计', style: text.titleMedium),
                const Spacer(),
                Text(
                  '查看周报',
                  style: text.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness),
                ),
              ],
            ),
            const SizedBox(height: S.x16),
            Container(
              padding: const EdgeInsets.symmetric(vertical: S.x12),
              decoration: BoxDecoration(
                color: T.color(scheme.onSurface, TextTier.fill,
                    brightness: scheme.brightness),
                borderRadius: BorderRadius.circular(R.card),
              ),
              child: Row(
                children: [
                  _animStat(context, scheme, today, '今日'),
                  Container(
                    width: 0.5,
                    height: 34,
                    color: T.color(scheme.onSurface, TextTier.hairline,
                        brightness: scheme.brightness),
                  ),
                  _animStat(context, scheme, week, '本周'),
                  Container(
                    width: 0.5,
                    height: 34,
                    color: T.color(scheme.onSurface, TextTier.hairline,
                        brightness: scheme.brightness),
                  ),
                  _animStat(context, scheme, total, '累计'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _animStat(
      BuildContext context, ColorScheme scheme, int seconds, String label) {
    return Expanded(
      child: Column(
        children: [
          _AnimatedStat(
            value: seconds,
            formatter: _fmt,
            color: scheme.onSurface,
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                ),
          ),
        ],
      ),
    );
  }
}

/// 带 count-up 动画的统计数值。
class _AnimatedStat extends StatelessWidget {
  final int value;
  final String Function(int) formatter;
  final Color color;
  const _AnimatedStat({
    required this.value,
    required this.formatter,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: 0, end: value),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          formatter(v),
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800, color: color),
        ),
      ),
    );
  }
}

/// 三格统计卡。
class _StatsCard extends StatelessWidget {
  final int favorites;
  final int history;
  final int downloads;
  final VoidCallback? onFavorites;
  final VoidCallback? onHistory;
  final VoidCallback? onDownloads;
  const _StatsCard({
    required this.favorites,
    required this.history,
    required this.downloads,
    this.onFavorites,
    this.onHistory,
    this.onDownloads,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTablet = Responsive.isTablet(context);

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(R.hero),
        border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          _stat(context, scheme, favorites, '收藏', isTablet, onFavorites),
          _divider(scheme),
          _stat(context, scheme, history, isTablet ? '记录' : '阅读记录', isTablet,
              onHistory),
          _divider(scheme),
          _stat(context, scheme, downloads, '已下载', isTablet, onDownloads),
        ],
      ),
    );
  }

  Widget _divider(ColorScheme scheme) => Container(
        width: 0.5,
        height: 30,
        color: T.color(scheme.onSurface, TextTier.hairline,
            brightness: scheme.brightness),
      );

  Widget _stat(
      BuildContext context, ColorScheme scheme, int value, String label, bool isTablet,
      VoidCallback? onTap) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        // 点击目标 ≥44dp，避免触控过小
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Column(
            children: [
              Text(
                '$value',
                style: (isTablet ? text.displaySmall : text.titleLarge)
                    ?.copyWith(
                        fontWeight: FontWeight.w800, color: scheme.onSurface),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: (isTablet ? text.bodySmall : text.labelSmall)
                    ?.copyWith(
                        color: T.color(scheme.onSurface, TextTier.low,
                            brightness: scheme.brightness)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 功能列表：我的收藏 / 阅读历史 / 我的下载 / 夜间模式 / 帮助与反馈。
class _MenuCard extends StatelessWidget {
  final bool dark;
  final ValueChanged<bool> onDarkChanged;
  final VoidCallback onFavorites;
  final VoidCallback onHistory;
  final VoidCallback onDownloads;
  final VoidCallback onHelp;
  const _MenuCard({
    required this.dark,
    required this.onDarkChanged,
    required this.onFavorites,
    required this.onHistory,
    required this.onDownloads,
    required this.onHelp,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(R.hero),
        border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SettingsRow(
            icon: Icons.bookmark_rounded,
            title: '我的收藏',
            onTap: onFavorites,
          ),
          SettingsRow(
            icon: Icons.history_rounded,
            title: '阅读历史',
            onTap: onHistory,
            showDivider: true,
          ),
          SettingsRow(
            icon: Icons.download_rounded,
            title: '我的下载',
            onTap: onDownloads,
            showDivider: true,
          ),
          SettingsRow(
            icon: Icons.dark_mode_rounded,
            title: '夜间模式',
            trailing: _ModernSwitch(value: dark, onChanged: onDarkChanged),
            showDivider: true,
          ),
          SettingsRow(
            icon: Icons.help_rounded,
            title: '帮助与反馈',
            onTap: onHelp,
            showDivider: true,
          ),
        ],
      ),
    );
  }
}

/// 现代感开关：主色选中轨道、无边框、略小尺寸。
class _ModernSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ModernSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Transform.scale(
      scale: 0.88,
      child: Switch(
        value: value,
        onChanged: onChanged,
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.1),
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.surface,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        thumbIcon: WidgetStateProperty.all(const Icon(Icons.circle, size: 14)),
      ),
    );
  }
}


/// 阅读历史底部弹窗（最近 30 条）。
class _HistorySheet extends StatelessWidget {
  final List<HistoryEntry> entries;
  const _HistorySheet({required this.entries});

@override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(S.x12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.sheet),
        ),
        child: entries.isEmpty
            ? StateView(
                kind: StateViewKind.empty,
                message: '暂无阅读记录',
                icon: Icons.history_rounded,
                onRetry: () => Navigator.pop(context),
                retryLabel: '关闭',
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SheetHandle(),
                  const SizedBox(height: 12),
                  Text('阅读历史（最近 ${entries.length} 条）',
                      style: text.titleMedium),
                  const SizedBox(height: S.x8),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => Container(
                        height: 0.5,
                        color: T.color(scheme.onSurface, TextTier.hairline,
                            brightness: scheme.brightness),
                      ),
                      itemBuilder: (_, i) {
                        final e = entries[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: SizedBox(
                            width: 42,
                            height: 56,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(R.control),
                              child: (e.book.pic.isEmpty)
                                  ? Container(color: scheme.surfaceContainerHighest)
                                  : CachedImage(e.book.pic,
                                      fit: BoxFit.cover, radius: 0),
                            ),
                          ),
                          title: Text(
                            e.book.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium,
                          ),
                          subtitle: Text(
                            '读到 ${e.chapterTitle.isEmpty ? '未知章节' : e.chapterTitle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                              color: T.color(scheme.onSurface, TextTier.low,
                                  brightness: scheme.brightness),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 帮助与反馈弹窗。
class _HelpSheet extends StatelessWidget {
  const _HelpSheet();

  static String _issuesUrl() {
    final body = Uri.encodeComponent(
      '请描述遇到的问题：\n\n'
      '版本：${UpdateChecker.currentVersion()}\n'
      '设备：\n'
      '复现步骤：\n'
      '1. \n'
      '2. \n'
      '3. \n'
      '\n'
      '（如有截图请附上）',
    );
    final title = Uri.encodeComponent('[Bug] ');
    return 'https://github.com/lxfebd/clean_manhua_flutter/issues/new'
        '?title=$title&body=$body';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(S.x12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.sheet),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHandle(),
            const SizedBox(height: 12),
            Text('帮助与反馈', style: text.titleLarge),
            const SizedBox(height: 12),
            Text(
              '• 阅读某个数据源失败时，可先到「工具 → 数据源管理」检查域名是否有效\n'
              '• 数据源加载失败可尝试「切换数据源」或稍后重试\n'
              '• 发现 Bug 或有建议，欢迎反馈',
              style: text.bodyMedium?.copyWith(height: 1.8),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(context);
                  // 用系统浏览器打开 GitHub Issues（WebView 内登录态不可靠，
                  // OAuth 重定向/Cookie 隔离会导致用户无法登录提交）。
                  final uri = Uri.parse(_issuesUrl());
                  try {
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    }
                  } catch (_) {}
                },
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: const Text('提交反馈 / 报告 Bug'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(R.card),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 阅读周报弹窗：最近 7 天柱状图 + 汇总数据。
class _ReadingReportSheet extends StatelessWidget {
  final List<Map<String, dynamic>> days;
  const _ReadingReportSheet({required this.days});

  String _fmt(int sec) {
    if (sec < 60) return '$sec秒';
    if (sec < 3600) return '${sec ~/ 60}分钟';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return m > 0 ? '$h小时$m分' : '$h小时';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final maxSec = [
      ...days.map((d) => (d['seconds'] as int?) ?? 0),
      60
    ].reduce((a, b) => a > b ? a : b);
    final total = days.fold<int>(
        0, (s, d) => s + ((d['seconds'] as int?) ?? 0));
    final activeDays =
        days.where((d) => ((d['seconds'] as int?) ?? 0) > 0).length;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(S.x12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.sheet),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHandle(),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.insights_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('阅读周报', style: text.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
            Text('最近 7 天阅读时长统计',
                style: text.bodySmall?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                )),
            const SizedBox(height: S.x16),
            SizedBox(
              height: 130,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < days.length; i++) ...[
                    Expanded(
                      child: _Bar(
                        seconds: (days[i]['seconds'] as int?) ?? 0,
                        maxSeconds: maxSec,
                        dayLabel: _shortDay(days[i]['day'] as String),
                        color: scheme.primary,
                      ),
                    ),
                    if (i < days.length - 1) const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
            const SizedBox(height: S.x16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(R.card),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _sumCell(context, scheme, '$activeDays天', '本周阅读'),
                  ),
                  Container(
                      width: 0.5,
                      height: 26,
                      color: T.color(scheme.onSurface, TextTier.hairline,
                          brightness: scheme.brightness)),
                  Expanded(child: _sumCell(context, scheme, _fmt(total), '本周时长')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sumCell(BuildContext context, ColorScheme scheme, String value, String label) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(value,
            style: text.titleLarge?.copyWith(
                fontWeight: FontWeight.w700, color: scheme.onSurface)),
        const SizedBox(height: 2),
        Text(label,
            style: text.labelSmall?.copyWith(
              color: T.color(scheme.onSurface, TextTier.low,
                  brightness: scheme.brightness),
            )),
      ],
    );
  }

  /// "2026-08-23" -> "08-23"。
  String _shortDay(String day) =>
      day.length >= 10 ? day.substring(5) : day;
}

/// 单根柱子：高度按 seconds/maxSeconds 比例，下方显示日期。
class _Bar extends StatelessWidget {
  final int seconds;
  final int maxSeconds;
  final String dayLabel;
  final Color color;
  const _Bar({
    required this.seconds,
    required this.maxSeconds,
    required this.dayLabel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = maxSeconds <= 0 ? 0.0 : (seconds / maxSeconds).clamp(0.0, 1.0);
    final barH = (ratio * 90).clamp(2.0, 90.0);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          seconds > 0 ? _shortFmt(seconds) : '',
          style: text.labelSmall?.copyWith(
              fontWeight: FontWeight.w600, color: color),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          height: barH,
          decoration: BoxDecoration(
            color: color.withValues(alpha: seconds > 0 ? 1.0 : 0.15),
            borderRadius: BorderRadius.circular(R.control),
          ),
        ),
        const SizedBox(height: 6),
        Text(dayLabel,
            style: text.labelSmall?.copyWith(
              color: T.color(scheme.onSurface, TextTier.low,
                  brightness: scheme.brightness),
            )),
      ],
    );
  }

  String _shortFmt(int sec) =>
      sec >= 3600 ? '${sec ~/ 3600}h' : '${sec ~/ 60}m';
}