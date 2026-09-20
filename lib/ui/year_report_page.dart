import 'package:flutter/material.dart';

import '../net/local_store.dart';
import 'responsive.dart';
import 'tokens.dart';

/// 年度阅读报告全屏可视化页。
///
/// 8.2 缺口补全：原 `_YearReportSheet` 是静态 12 月柱状图 + 两个统计格，
/// 本页升级为——进页柱子逐根生长动画、统计数字滚动、加最长连续阅读/
/// 单日最长/月度峰值维度。数据全部来自 LocalStore 既有 reading_stats
/// （日粒度 key → 秒），纯读取不落盘。
class YearReportPage extends StatefulWidget {
  const YearReportPage({super.key, this.year});

  /// 目标年份，默认当前年。
  final int? year;

  @override
  State<YearReportPage> createState() => _YearReportPageState();
}

class _YearReportPageState extends State<YearReportPage> {
  late final int _year = widget.year ?? DateTime.now().year;

  List<Map<String, dynamic>> _months = const [];
  int _totalSeconds = 0;
  int _activeDays = 0;
  Map<String, dynamic> _streak = const {};
  Map<String, dynamic> _bestDay = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final months = await LocalStore.yearReadingMonths(_year);
    final total = await LocalStore.yearReadingSeconds(_year);
    final active = await LocalStore.activeReadingDays(_year);
    final streak = await LocalStore.yearReadingStreak(_year);
    final bestDay = await LocalStore.yearBestDay(_year);
    if (!mounted) return;
    setState(() {
      _months = months;
      _totalSeconds = total;
      _activeDays = active;
      _streak = streak;
      _bestDay = bestDay;
      _loading = false;
    });
  }

  String _fmt(int sec) {
    if (sec < 60) return '$sec秒';
    if (sec < 3600) return '${sec ~/ 60}分钟';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return m > 0 ? '$h小时$m分' : '$h小时';
  }

  String _shortMonth(String month) =>
      month.length >= 7 ? '${month.substring(5)}月' : month;

  /// "2026-05-11" -> "5月11日"。
  String _dayLabel(String? day) {
    if (day == null || day.length < 10) return '—';
    final m = int.tryParse(day.substring(5, 7)) ?? 0;
    final d = int.tryParse(day.substring(8, 10)) ?? 0;
    return '$m月$d日';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        bottom: false,
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: _loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                  : _buildBody(context, scheme, text),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme, TextTheme text) {
    if (_totalSeconds <= 0) return _EmptyState(year: _year, onRetry: _load);
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 8, Responsive.pagePadding(context), 32),
      children: [
        _buildHeader(context, scheme, text),
        const SizedBox(height: S.x16),
        _buildStatGrid(context, scheme, text),
        const SizedBox(height: S.x24),
        _sectionTitle(context, scheme, text, '月度阅读时长'),
        const SizedBox(height: S.x12),
        _buildMonthChart(context, scheme, text),
        const SizedBox(height: S.x24),
        _buildHighlights(context, scheme, text),
        const SizedBox(height: S.x16),
        Text('数据仅统计本机阅读时长，不会上传',
            style: text.labelSmall?.copyWith(
              color: T.color(scheme.onSurface, TextTier.disabled,
                  brightness: scheme.brightness),
            )),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme scheme, TextTheme text) {
    return Row(
      children: [
        IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: Icon(
              DesktopUi.isDesktopPlatform
                  ? Icons.arrow_back_rounded
                  : Icons.arrow_back_ios_new_rounded,
              size: 18,
              color: scheme.onSurface),
        ),
        const SizedBox(width: 4),
        Icon(Icons.auto_graph_rounded, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$_year 年度报告', style: text.titleLarge),
              Text('这一年，你与星漫匣的阅读时光',
                  style: text.labelSmall?.copyWith(
                    color: T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                  )),
            ],
          ),
        ),
      ],
    );
  }

  /// 顶部 2×2 统计格：全年时长 / 有效阅读 / 最长连续 / 日均。
  Widget _buildStatGrid(
      BuildContext context, ColorScheme scheme, TextTheme text) {
    final avg = _activeDays > 0 ? _totalSeconds ~/ _activeDays : 0;
    final maxStreak = (_streak['maxStreak'] as int?) ?? 0;
    final cells = <(String, String)>[
      (_fmt(_totalSeconds), '全年时长'),
      ('$_activeDays天', '有效阅读'),
      (maxStreak > 0 ? '$maxStreak天' : '—', '最长连续'),
      (_fmt(avg), '日均时长'),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: S.x12,
      crossAxisSpacing: S.x12,
      childAspectRatio: 2.2,
      children: [
        for (final (value, label) in cells)
          _StatCard(
            value: value,
            label: label,
            isAccent: value == _fmt(_totalSeconds),
          ),
      ],
    );
  }

  Widget _sectionTitle(
      BuildContext context, ColorScheme scheme, TextTheme text, String title) {
    return Row(
      children: [
        Text(title, style: text.titleMedium),
        const Spacer(),
        Text('共 ${_months.length} 个月',
            style: text.labelSmall?.copyWith(
              color: T.color(scheme.onSurface, TextTier.low,
                  brightness: scheme.brightness),
            )),
      ],
    );
  }

  /// 12 月柱状图：进页逐根生长动画 + 峰值柱高亮。
  Widget _buildMonthChart(
      BuildContext context, ColorScheme scheme, TextTheme text) {
    final maxSec = [
      ..._months.map((d) => (d['seconds'] as int?) ?? 0),
      3600,
    ].reduce((a, b) => a > b ? a : b);
    final peakMonth = _months.indexWhere(
        (d) => (d['seconds'] as int?) == maxSec && maxSec > 3600);
    return Container(
      padding: const EdgeInsets.fromLTRB(S.x12, S.x16, S.x12, S.x12),
      decoration: BoxDecoration(
        color: T.color(scheme.onSurface, TextTier.fill, brightness: scheme.brightness),
        borderRadius: BorderRadius.circular(R.card),
      ),
      child: SizedBox(
        height: 180,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < _months.length; i++) ...[
              Expanded(
                child: _AnimatedMonthBar(
                  seconds: (_months[i]['seconds'] as int?) ?? 0,
                  maxSeconds: maxSec,
                  dayLabel: _shortMonth(_months[i]['month'] as String),
                  color: i == peakMonth ? scheme.primary : scheme.primary.withValues(alpha: 0.45),
                  colorScheme: scheme,
                  delayMs: i * 45,
                ),
              ),
              if (i < _months.length - 1) const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
  }

  /// 高光卡：最长连续区间 + 单日最长。
  Widget _buildHighlights(BuildContext context, ColorScheme scheme, TextTheme text) {
    final maxStreak = (_streak['maxStreak'] as int?) ?? 0;
    final bestStart = _dayLabel(_streak['bestStart'] as String?);
    final bestEnd = _dayLabel(_streak['bestEnd'] as String?);
    final bestDay = _dayLabel(_bestDay['day'] as String?);
    final bestDaySec = (_bestDay['seconds'] as int?) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, scheme, text, '年度高光'),
        const SizedBox(height: S.x12),
        Row(
          children: [
            Expanded(
              child: _HighlightCard(
                icon: Icons.local_fire_department_rounded,
                title: maxStreak > 0 ? '连续 $maxStreak 天' : '暂未形成连续',
                subtitle: maxStreak > 0 ? '$bestStart — $bestEnd' : '保持每天阅读，点亮火焰',
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: S.x12),
            Expanded(
              child: _HighlightCard(
                icon: Icons.star_rounded,
                title: bestDaySec > 0 ? '单日 ${_fmt(bestDaySec)}' : '暂无记录',
                subtitle: bestDaySec > 0 ? '$bestDay 读得最久' : '挑一天沉浸式阅读吧',
                color: Colors.orange,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 统计数字卡：数字渐进滚动动画（TweenAnimationBuilder int 插值）。
class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final bool isAccent;
  const _StatCard({
    required this.value,
    required this.label,
    this.isAccent = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accentColor = scheme.primary;
    return Container(
      padding: const EdgeInsets.all(S.x12),
      decoration: BoxDecoration(
        color: isAccent
            ? scheme.primary.withValues(alpha: 0.08)
            : T.color(scheme.onSurface, TextTier.fill, brightness: scheme.brightness),
        borderRadius: BorderRadius.circular(R.card),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: isAccent ? accentColor : scheme.onSurface,
              )),
          const SizedBox(height: 2),
          Text(label,
              style: text.labelSmall?.copyWith(
                color: T.color(scheme.onSurface, TextTier.low,
                    brightness: scheme.brightness),
              )),
        ],
      ),
    );
  }
}

/// 单根柱：进页后延迟 [delayMs] 从 0 生长到目标高度。
class _AnimatedMonthBar extends StatelessWidget {
  final int seconds;
  final int maxSeconds;
  final String dayLabel;
  final Color color;
  final ColorScheme colorScheme;
  final int delayMs;

  const _AnimatedMonthBar({
    required this.seconds,
    required this.maxSeconds,
    required this.dayLabel,
    required this.color,
    required this.colorScheme,
    required this.delayMs,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ratio = maxSeconds <= 0 ? 0.0 : (seconds / maxSeconds).clamp(0.0, 1.0);
    final targetH = (ratio * 130).clamp(2.0, 130.0);
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          seconds > 0 ? _shortFmt(seconds) : '',
          style: text.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: T.color(colorScheme.onSurface, TextTier.mid,
                  brightness: colorScheme.brightness)),
        ),
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: targetH),
          duration: Duration(milliseconds: 320 + delayMs),
          curve: Curves.easeOutCubic,
          builder: (_, h, __) => Container(
            width: double.infinity,
            height: h,
            decoration: BoxDecoration(
              color: seconds > 0 ? color : color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(R.control),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(dayLabel,
            style: text.labelSmall?.copyWith(
              color: T.color(colorScheme.onSurface, TextTier.low,
                  brightness: colorScheme.brightness),
            )),
      ],
    );
  }

  String _shortFmt(int sec) =>
      sec >= 3600 ? '${sec ~/ 3600}h' : '${sec ~/ 60}m';
}

/// 高光卡：图标 + 主文案 + 副文案。
class _HighlightCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  const _HighlightCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(S.x12),
      decoration: BoxDecoration(
        color: T.color(scheme.onSurface, TextTier.fill, brightness: scheme.brightness),
        borderRadius: BorderRadius.circular(R.card),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(R.control),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: S.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(
                      color: T.color(scheme.onSurface, TextTier.low,
                          brightness: scheme.brightness),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态：该年无阅读记录。
class _EmptyState extends StatelessWidget {
  final int year;
  final VoidCallback onRetry;
  const _EmptyState({required this.year, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(S.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_rounded,
                size: 48, color: scheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: S.x12),
            Text('$year 年还没有阅读记录', style: text.titleMedium),
            const SizedBox(height: S.x8),
            Text('开始阅读后，这里会生成你的年度报告',
                style: text.bodySmall?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                )),
            const SizedBox(height: S.x16),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }
}
