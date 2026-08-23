import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../net/bookshelf_store.dart';
import '../net/local_store.dart';
import 'settings_page.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 110),
          children: [
            // ── 顶栏：我的 + 设置 ─────────────────────────────
            FadeSlideIn(
              duration: const Duration(milliseconds: 380),
              child: Row(
                children: [
                  Text(
                    '我的',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: scheme.onSurface,
                    ),
                  ),
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
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(
                          color: scheme.onSurface.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Icon(Icons.settings_outlined,
                          size: 20, color: scheme.onSurface.withValues(alpha: 0.7)),
                    ),
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
          ],
        ),
      ),
    );
  }

  /// 下拉刷新统计（切 Tab 回来时由外部调用）。
  Future<void> refresh() => _load();

  void _showHistory() {
    final entries = _history.take(30).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _HistorySheet(entries: entries),
    ).then((_) {
      if (mounted) _load();
    });
  }

  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _HelpSheet(),
    );
  }

  /// 阅读周报弹窗：最近 7 天每天的阅读时长柱状图 + 汇总。
  Future<void> _showReadingReport() async {
    final days = await LocalStore.recentReadingDays(7);
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ReadingReportSheet(days: days),
    ).then((_) {
      if (mounted) _load();
    });
  }
}

/// 用户卡：本地使用提示（无账号体系）。
class _UserCard extends StatelessWidget {
  const _UserCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.onSurface.withValues(alpha: 0.06),
            ),
            child: Icon(
              Icons.person_outline_rounded,
              size: 30,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本地使用',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '收藏与阅读记录保存在本机',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
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
    if (sec < 60) return '${sec}秒';
    if (sec < 3600) return '${sec ~/ 60}分钟';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return m > 0 ? '$h小时$m分钟' : '$h小时';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.bar_chart_rounded,
                      size: 18, color: scheme.primary),
                ),
                const SizedBox(width: 10),
                Text('阅读统计',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
                const Spacer(),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: scheme.onSurface.withValues(alpha: 0.3)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _stat(scheme, _fmt(today), '今日'),
                Container(
                  width: 0.5,
                  height: 30,
                  color: scheme.onSurface.withValues(alpha: 0.08),
                ),
                _stat(scheme, _fmt(week), '本周'),
                Container(
                  width: 0.5,
                  height: 30,
                  color: scheme.onSurface.withValues(alpha: 0.08),
                ),
                _stat(scheme, _fmt(total), '累计'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(ColorScheme scheme, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.5))),
        ],
      ),
    );
  }
}

/// 三格统计卡。
class _StatsCard extends StatelessWidget {
  final int favorites;
  final int history;
  final int downloads;
  const _StatsCard({
    required this.favorites,
    required this.history,
    required this.downloads,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          _stat(scheme, favorites, '收藏'),
          _divider(scheme),
          _stat(scheme, history, '阅读记录'),
          _divider(scheme),
          _stat(scheme, downloads, '已下载'),
        ],
      ),
    );
  }

  Widget _divider(ColorScheme scheme) => Container(
        width: 0.5,
        height: 32,
        color: scheme.onSurface.withValues(alpha: 0.08),
      );

  Widget _stat(ColorScheme scheme, int value, String label) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ],
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
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _Row(
            icon: Icons.bookmark_outline_rounded,
            label: '我的收藏',
            onTap: onFavorites,
          ),
          _sep(scheme),
          _Row(
            icon: Icons.history_rounded,
            label: '阅读历史',
            onTap: onHistory,
          ),
          _sep(scheme),
          _Row(
            icon: Icons.download_outlined,
            label: '我的下载',
            onTap: onDownloads,
          ),
          _sep(scheme),
          _Row(
            icon: Icons.dark_mode_outlined,
            label: '夜间模式',
            trailing: Switch(
              value: dark,
              onChanged: onDarkChanged,
            ),
          ),
          _sep(scheme),
          _Row(
            icon: Icons.help_outline_rounded,
            label: '帮助与反馈',
            onTap: onHelp,
          ),
        ],
      ),
    );
  }

  Widget _sep(ColorScheme scheme) => Container(
        height: 0.5,
        margin: const EdgeInsets.only(left: 56),
        color: scheme.onSurface.withValues(alpha: 0.06),
      );
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;
  const _Row({
    required this.icon,
    required this.label,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurface.withValues(alpha: 0.75)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (trailing != null)
              trailing!
            else
              Icon(Icons.keyboard_arrow_right_rounded,
                  size: 20, color: scheme.onSurface.withValues(alpha: 0.3)),
          ],
        ),
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
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: entries.isEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Icon(Icons.history_rounded,
                      size: 40, color: scheme.onSurface.withValues(alpha: 0.2)),
                  const SizedBox(height: 10),
                  const Text('暂无阅读记录'),
                  const SizedBox(height: 20),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '阅读历史（最近 ${entries.length} 条）',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => Container(
                        height: 0.5,
                        color: scheme.onSurface.withValues(alpha: 0.06),
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
                              borderRadius: BorderRadius.circular(6),
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
                            style: const TextStyle(fontSize: 13.5),
                          ),
                          subtitle: Text(
                            '读到 ${e.chapterTitle.isEmpty ? '未知章节' : e.chapterTitle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '帮助与反馈',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '• 阅读某个数据源失败时，可先到「工具 → 数据源管理」检查域名是否有效\n'
              '• 数据源加载失败可尝试「切换数据源」或稍后重试\n'
              '• 发现 Bug 或有建议，欢迎反馈',
              style: TextStyle(fontSize: 13, height: 1.8),
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
    if (sec < 60) return '${sec}秒';
    if (sec < 3600) return '${sec ~/ 60}分钟';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return m > 0 ? '$h小时$m分' : '$h小时';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.insights_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('阅读周报',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
              ],
            ),
            const SizedBox(height: 4),
            Text('最近 7 天阅读时长统计',
                style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurface.withValues(alpha: 0.5))),
            const SizedBox(height: 18),
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
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _sumCell('${activeDays}天', '本周阅读'),
                  ),
                  Container(
                      width: 0.5,
                      height: 26,
                      color: scheme.onSurface.withValues(alpha: 0.1)),
                  Expanded(child: _sumCell(_fmt(total), '本周时长')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sumCell(String value, String label) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 11, color: Colors.black.withValues(alpha: 0.5))),
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          seconds > 0 ? _shortFmt(seconds) : '',
          style: TextStyle(
              fontSize: 9, fontWeight: FontWeight.w600, color: color),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          height: barH,
          decoration: BoxDecoration(
            color: color.withValues(alpha: seconds > 0 ? 1.0 : 0.15),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 6),
        Text(dayLabel,
            style: TextStyle(
                fontSize: 9.5, color: Colors.black.withValues(alpha: 0.45))),
      ],
    );
  }

  String _shortFmt(int sec) =>
      sec >= 3600 ? '${sec ~/ 3600}h' : '${sec ~/ 60}m';
}