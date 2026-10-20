part of 'profile_page.dart';

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
  Widget build(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    final text = Theme.of(c).textTheme;
    final ui = c.uiStyle;
    return Container(
      padding: const EdgeInsets.all(S.x16),
      decoration: _CardD.cardDeco(c, scheme),
      child: Row(
        children: [
          // 头像：极简锁圆形（现状）；小米换超椭圆（SquircleClipper 14dp 半径）。
          // 苹果保持圆形（iOS 头像惯例）。
          _UserAvatar(ui, scheme),
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

/// 用户卡头像：极简/苹果=圆形；小米=超椭圆（SquircleClipper 半径 14dp，方中带圆）。
class _UserAvatar extends StatelessWidget {
  const _UserAvatar(this.ui, this.scheme);
  final UIStyle ui;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final isCircle = ui != UIStyle.xiaomi;
    final avatar = Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        color: scheme.primary.withValues(alpha: 0.1),
      ),
      child: Icon(
        Icons.person_rounded,
        size: 28,
        color: scheme.primary,
      ),
    );
    if (isCircle) return avatar;
    return ClipPath(
      clipper: const SquircleClipper(radius: R.controlXiaomi),
      child: avatar,
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
        decoration: _CardD.cardDeco(context, scheme),
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
      decoration: _CardD.cardDeco(context, scheme),
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
  final VoidCallback onExportBooklist;
  final VoidCallback onExportBooklistImage;
  final VoidCallback onImportBooklist;
  const _MenuCard({
    required this.dark,
    required this.onDarkChanged,
    required this.onFavorites,
    required this.onHistory,
    required this.onDownloads,
    required this.onHelp,
    required this.onExportBooklist,
    required this.onExportBooklistImage,
    required this.onImportBooklist,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: _CardD.cardDeco(context, scheme),
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
            icon: Icons.ios_share_rounded,
            title: '导出书单',
            subtitle: '书架清单复制为文本',
            onTap: onExportBooklist,
            showDivider: true,
          ),
          SettingsRow(
            icon: Icons.photo_rounded,
            title: '导出书单海报',
            subtitle: '封面网格 → PNG 图片',
            onTap: onExportBooklistImage,
            showDivider: true,
          ),
          SettingsRow(
            icon: Icons.playlist_add_rounded,
            title: '导入书单',
            subtitle: '剪贴板文本一键入书架',
            onTap: onImportBooklist,
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


/// 阅读历史底部弹窗（最近 30 条）。条目可点：直达阅读器续读上次位置。
/// 阅读历史过滤纯函数（历史弹窗搜索框用；独立便于单元测试）。
/// [filter] 按书名或章节标题模糊匹配（空 = 原列表原样）。
List<HistoryEntry> filterHistoryEntries(List<HistoryEntry> entries, String filter) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return entries;
  return [
    for (final e in entries)
      if (e.book.name.toLowerCase().contains(f) ||
          e.chapterTitle.toLowerCase().contains(f))
        e,
  ];
}

class _HistorySheet extends StatefulWidget {
  final List<HistoryEntry> entries;
  final ValueChanged<HistoryEntry> onTap;
  const _HistorySheet({required this.entries, required this.onTap});

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  final _filterCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

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
          borderRadius:
              BorderRadius.circular(R.of(R.sheet, style: context.uiStyle)),
        ),
        child: widget.entries.isEmpty
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
                  Text('阅读历史（最近 ${widget.entries.length} 条）',
                      style: text.titleMedium),
                  const SizedBox(height: S.x8),
                  TextField(
                    controller: _filterCtrl,
                    onChanged: (v) => setState(() => _filter = v),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索书名 / 章节',
                      hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                      fillColor:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          StyleTokens.controlRadiusOr(context, 8),
                        ),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: S.x8),
                  Flexible(
                    child: _HistoryList(
                      entries: filterHistoryEntries(widget.entries, _filter),
                      filter: _filter,
                      onTap: widget.onTap,
                      scheme: scheme,
                      text: text,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 历史条目列表（过滤空态 / 条目复用，减少 _HistorySheet build 膨胀）。
class _HistoryList extends StatelessWidget {
  final List<HistoryEntry> entries;
  final String filter;
  final ValueChanged<HistoryEntry> onTap;
  final ColorScheme scheme;
  final TextTheme text;
  const _HistoryList({
    required this.entries,
    required this.filter,
    required this.onTap,
    required this.scheme,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            '没有匹配「$filter」的记录',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: entries.length,
      separatorBuilder: (_, __) => RowSeparator(tier: TextTier.hairline),
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
                  : CachedImage(e.book.pic, fit: BoxFit.cover, radius: 0),
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
          trailing: Icon(
            Icons.play_circle_outline_rounded,
            size: 18,
            color: scheme.primary.withValues(alpha: 0.55),
          ),
          onTap: () => onTap(e),
        );
      },
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
          borderRadius:
              BorderRadius.circular(R.of(R.sheet, style: context.uiStyle)),
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

/// 阅读周报弹窗：最近 7 天柱状图 + 汇总数据，底部可进入年度报告。
class _ReadingReportSheet extends StatelessWidget {
  final List<Map<String, dynamic>> days;
  final VoidCallback? onYearTap;
  const _ReadingReportSheet({required this.days, this.onYearTap});

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
          borderRadius:
              BorderRadius.circular(R.of(R.sheet, style: context.uiStyle)),
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
            if (total <= 0)
              Container(
                height: 130,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: T.color(scheme.onSurface, TextTier.fill,
                      brightness: scheme.brightness),
                  borderRadius: BorderRadius.circular(R.card),
                ),
                child: Text('最近 7 天还没有阅读记录',
                    style: text.bodySmall?.copyWith(
                      color: T.color(scheme.onSurface, TextTier.low,
                          brightness: scheme.brightness),
                    )),
              )
            else
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
            if (onYearTap != null) ...[
              const SizedBox(height: S.x12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onYearTap,
                  icon: const Icon(Icons.calendar_month_rounded, size: 16),
                  label: const Text('查看年度报告'),
                ),
              ),
            ],
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

/// 文本导出预览弹窗：展示导出的文本，支持复制/关闭。
class _TextExportSheet extends StatelessWidget {
  final String title;
  final String text;
  const _TextExportSheet({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(S.x12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius:
              BorderRadius.circular(R.of(R.sheet, style: context.uiStyle)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHandle(),
            const SizedBox(height: 12),
            Text(title, style: textTheme.titleLarge),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: T.color(scheme.onSurface, TextTier.fill,
                    brightness: scheme.brightness),
                borderRadius: BorderRadius.circular(R.card),
              ),
              child: SingleChildScrollView(
                child: Text(text,
                    style: textTheme.bodySmall?.copyWith(height: 1.6)),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  AppToast.info(context, '已复制到剪贴板');
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制文本'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await SharePlus.instance
                      .share(ShareParams(text: text, subject: '我的书单'));
                  if (!context.mounted) return;
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.ios_share_rounded, size: 16),
                label: const Text('分享到…'),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
/// 书单海报生成中的占位弹窗。
class _ImageLoadingSheet extends StatelessWidget {
  const _ImageLoadingSheet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(S.x12),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius:
              BorderRadius.circular(R.of(R.sheet, style: context.uiStyle)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 14),
            Text('正在加载封面、生成海报…'),
          ],
        ),
      ),
    );
  }
}

/// 书单海报预览 + 保存弹窗。海报由 [boundaryKey] 的 RepaintBoundary 截图。
class _ImageExportSheet extends StatefulWidget {
  final List<ComicDetail> books;
  final List<Uint8List?> covers;
  final GlobalKey boundaryKey;
  final Future<String?> Function() onSave;
  const _ImageExportSheet({
    required this.books,
    required this.covers,
    required this.boundaryKey,
    required this.onSave,
  });

  @override
  State<_ImageExportSheet> createState() => _ImageExportSheetState();
}

class _ImageExportSheetState extends State<_ImageExportSheet> {
  bool _saving = false;
  String? _savedPath;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final p = await widget.onSave();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _savedPath = p;
    });
  }

  /// 把已保存的海报 PNG 丢进系统分享面板。
  Future<void> _sharePoster() async {
    final p = _savedPath;
    if (p == null) return;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(p, mimeType: 'image/png')],
      subject: '我的书单海报',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(S.x12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius:
              BorderRadius.circular(R.of(R.sheet, style: context.uiStyle)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHandle(),
            const SizedBox(height: 12),
            Text('书单海报', style: textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '共 ${widget.books.length} 本 · 保存为 PNG 图片',
              style: textTheme.bodySmall?.copyWith(
                color: T.color(scheme.onSurface, TextTier.low,
                    brightness: scheme.brightness),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              constraints: const BoxConstraints(maxHeight: 360),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                borderRadius: BorderRadius.circular(R.card),
                border: Border.all(
                  color: T.color(scheme.onSurface, TextTier.hairline,
                      brightness: scheme.brightness),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                child: RepaintBoundary(
                  key: widget.boundaryKey,
                  child: _BooklistPoster(
                    books: widget.books,
                    covers: widget.covers,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _savedPath != null
                    ? () => Navigator.pop(context)
                    : (_saving ? null : _save),
                icon: Icon(_savedPath != null
                    ? Icons.check_rounded
                    : Icons.image_rounded,
                    size: 16),
                label: Text(_saving
                    ? '保存中…'
                    : _savedPath != null
                        ? '完成'
                        : '保存图片'),
              ),
            ),
            if (_saving) ...[
              const SizedBox(height: 12),
              const Center(
                child: SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              ),
            ] else if (_savedPath != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.check_circle_rounded,
                      size: 16, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已保存：$_savedPath',
                      style: textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sharePoster,
                  icon: const Icon(Icons.ios_share_rounded, size: 16),
                  label: const Text('分享图片'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 书单海报：固定白色底、780 宽、3 列封面网格，用于截图导出。
class _BooklistPoster extends StatelessWidget {
  final List<ComicDetail> books;
  final List<Uint8List?> covers;
  const _BooklistPoster({required this.books, required this.covers});

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFFFFFFFF);
    const fg = Color(0xFF1A1A1A);
    const sub = Color(0xFF757575);
    final count = books.length;
    return Container(
      width: 780,
      color: bg,
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                '星漫匣 · 我的书单',
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: fg,
                    height: 1.2),
              ),
              const Spacer(),
              Text(
                '共 $count 本',
                style: const TextStyle(fontSize: 15, color: sub),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '导出时间：${DateTime.now().toString().substring(0, 16)}',
            style: const TextStyle(fontSize: 12, color: sub),
          ),
          const SizedBox(height: 20),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              childAspectRatio: 0.62,
            ),
            itemCount: count,
            itemBuilder: (_, i) => _PosterCard(
              book: books[i],
              cover: i < covers.length ? covers[i] : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 海报单本卡片：封面 + 书名 + 作者。
class _PosterCard extends StatelessWidget {
  final ComicDetail book;
  final Uint8List? cover;
  const _PosterCard({required this.book, required this.cover});

  @override
  Widget build(BuildContext context) {
    final author = (book.author?.isNotEmpty ?? false) ? book.author : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(R.of(R.control, style: context.uiStyle)),
            child: cover != null
                ? Image.memory(
                    cover!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  )
                : Container(
                    color: const Color(0xFFECECEC),
                    child: const Icon(Icons.image_not_supported_rounded,
                        color: Color(0xFFBDBDBD)),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          book.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
        ),
        if (author != null) ...[
          const SizedBox(height: 2),
          Text(
            author,
maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Color(0xFF757575)),
          ),
        ],
      ],
    );
  }
}

/// 书单导入弹窗：预览解析出的书名 → 跨源搜索定位 → 一键加入书架。
class _ImportBooklistSheet extends StatefulWidget {
  final List<BooklistEntry> entries;
  const _ImportBooklistSheet({required this.entries});

  @override
  State<_ImportBooklistSheet> createState() => _ImportBooklistSheetState();
}

class _ImportBooklistSheetState extends State<_ImportBooklistSheet> {
  bool _running = false;
  int _hit = 0;
  int _miss = 0;
  final List<String> _missed = [];
  String _log = '';

  Future<void> _runImport() async {
    if (_running) return;
    setState(() {
      _running = true;
      _hit = _miss = 0;
      _missed.clear();
      _log = '';
    });
    final sources = await SourceManager.enabledSources();
    var done = 0;
    for (final e in widget.entries) {
      final found = await _findAndAdd(e, sources);
      if (!mounted) return; // 弹窗被滑掉后 State 已销毁，停止后台导入
      if (found) {
        _hit++;
      } else {
        _miss++;
        _missed.add(e.name);
      }
      done++;
      setState(() => _log = '$done/${widget.entries.length}');
    }
    if (mounted) setState(() => _running = false);
  }

  /// 跨已启用源按书名精确搜索（取第一个完全同名的结果），命中即写入书架。
  Future<bool> _findAndAdd(
      BooklistEntry e, List<ComicSource> sources) async {
    for (final s in sources) {
      try {
        final results = await s
            .search(e.name, 1)
            .timeout(const Duration(seconds: 12));
        for (final r in results) {
          if (r.name == e.name) {
            final detail = await s
                .detail(r.id)
                .timeout(const Duration(seconds: 12));
            BookshelfStore.add(s.id, detail);
            return true;
          }
        }
      } catch (_) {
        // 单源搜索失败不影响其他源
      }
    }
    return false;
  }

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
          borderRadius:
              BorderRadius.circular(R.of(R.sheet, style: context.uiStyle)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHandle(),
            const SizedBox(height: 12),
            Text('导入书单', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('识别到 ${widget.entries.length} 本：',
                style: text.bodySmall?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                )),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: T.color(scheme.onSurface, TextTier.fill,
                    brightness: scheme.brightness),
                borderRadius: BorderRadius.circular(R.card),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in widget.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '· ${e.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(height: 1.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_missed.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(R.card),
                ),
                child: Text(
                  '未找到（${_missed.length}）：${_missed.join('、')}',
                  style: text.bodySmall?.copyWith(color: scheme.onErrorContainer),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : _runImport,
                    icon: const Icon(Icons.playlist_add_rounded, size: 16),
                    label: Text(_running
                        ? '搜索中 $_log…'
                        : (_hit + _miss > 0
                            ? '完成：命中 $_hit，未找到 $_miss'
                            : '开始导入')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
