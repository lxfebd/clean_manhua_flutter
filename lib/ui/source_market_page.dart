import 'package:flutter/material.dart';

import '../sources/dsl/custom_source_def.dart';
import '../sources/dsl/custom_source_store.dart';
import '../sources/dsl/source_market.dart';
import 'responsive.dart';

/// 源市场页：拉取远端索引展示社区/官方自定义源，支持一键安装/更新/查看详情。
///
/// 安装走 CustomSourceStore.importJson（校验+落盘+插件注册），
/// 失败回退展示错误信息，不破坏已有源。
class SourceMarketPage extends StatefulWidget {
  const SourceMarketPage({super.key});

  @override
  State<SourceMarketPage> createState() => _SourceMarketPageState();
}

class _SourceMarketPageState extends State<SourceMarketPage> {
  List<MarketSourceEntry>? _entries;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await SourceMarket.fetchIndex();
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  /// 安装/更新单个源。
  Future<void> _install(MarketSourceEntry entry) async {
    final ok = await SourceMarket.install(entry);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '已安装：${entry.name} v${entry.version}'
          : '安装失败：${entry.name} 校验未通过'),
      duration: const Duration(seconds: 2),
    ));
    setState(() {}); // 刷新 installed 状态
  }

  /// 卸载已安装的源（移除解析规则，书架收藏不受影响）。
  Future<void> _uninstall(MarketSourceEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载来源'),
        content: Text(
          '卸载「${entry.name}」将移除其解析规则。\n'
          '书架中已收藏的作品不受影响，但将无法继续更新/阅读新章节。',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final removed = await CustomSourceStore.remove(entry.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(removed ? '已卸载：${entry.name}' : '卸载失败：${entry.name} 未找到'),
      duration: const Duration(seconds: 2),
    ));
    setState(() {}); // 刷新 installed 状态
  }

  /// 确认安装对话框（第三方源风险提示）。
  Future<void> _confirmInstall(MarketSourceEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装来源'),
        content: Text(
          '即将安装：${entry.name} v${entry.version}\n'
          '来源：${entry.provider}\n\n'
          '自定义源由社区开发，未经官方审计。'
          '请确认你信任该来源后再安装。',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (ok == true) await _install(entry);
  }

  /// 查看源详情：能力矩阵 + 各抽取通道方式（CSS/正则），装前预览。
  void _showDetail(MarketSourceEntry entry) {
    final def = entry.def;
    final cap = <(String, IconData, bool)>[
      ('搜索', Icons.search_rounded, (def.searchUrl ?? '').isNotEmpty),
      ('分类导航', Icons.category_rounded, (def.categoriesUrl ?? '').isNotEmpty),
      ('分类列表', Icons.list_alt_rounded,
          (def.categoryListUrl ?? '').isNotEmpty),
      ('排行榜', Icons.leaderboard_rounded, (def.rankUrl ?? '').isNotEmpty),
      ('详情/章节', Icons.menu_book_rounded, (def.detailUrl ?? '').isNotEmpty),
    ];

    // 抽取方式摘要：列表通道 selector/regex，详情章节/pic 同理。
    String method(DslListRule? r) => r == null
        ? '—'
        : (r.selector.isNotEmpty
            ? 'CSS ${r.selector}'
            : r.regex.isNotEmpty
                ? '正则（捕获组 ${r.regex.length > 28 ? '${r.regex.substring(0, 28)}…' : r.regex}）'
                : '—');
    final d = def.detailRule;
    showDialog(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text(
            '${entry.name} v${entry.version}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${entry.type}源 · ${entry.provider}'
                    '${entry.author.isNotEmpty ? ' · ${entry.author}' : ''}',
                    style: TextStyle(
                        fontSize: 12,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                  ),
                  if (entry.description != null &&
                      entry.description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        entry.description!,
                        style: const TextStyle(fontSize: 13, height: 1.55),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 6),
                    child: Text('能力',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: theme
                                .colorScheme.onSurface.withValues(alpha: 0.8))),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (label, icon, ok) in cap)
                        Chip(
                          avatar: Icon(icon,
                              size: 14,
                              color: ok
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface
                                      .withValues(alpha: 0.3)),
                          label: Text(
                            label,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: ok ? 0.85 : 0.4)),
                          ),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          backgroundColor: ok
                              ? theme.colorScheme.primary.withValues(alpha: 0.08)
                              : theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.4),
                          side: BorderSide.none,
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 6),
                    child: Text('抽取方式',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: theme
                                .colorScheme.onSurface.withValues(alpha: 0.8))),
                  ),
                  _detailRow(theme, '列表', method(def.categoryListRule)),
                  _detailRow(theme, '搜索', method(def.searchRule)),
                  _detailRow(
                      theme,
                      '分类',
                      def.categoriesRule == null
                          ? '—'
                          : 'CSS ${def.categoriesRule!.selector}'),
                  _detailRow(
                      theme,
                      '章节',
                      d == null
                          ? '—'
                          : d.chapters.isNotEmpty
                              ? 'CSS ${d.chapters}'
                              : d.chaptersRe.isNotEmpty
                                  ? '正则（命名组 href/title）'
                                  : '—'),
                  _detailRow(
                      theme,
                      '图片/播放',
                      d == null
                          ? '—'
                          : d.picListCss.isNotEmpty
                              ? 'CSS ${d.picListCss}'
                              : d.picListRe.isNotEmpty
                                  ? '正则（捕获组 1）'
                                  : '—'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  /// 详情对话框里的一行「通道 → 方式」。
  Widget _detailRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        Responsive.pagePadding(context), 10,
                        Responsive.pagePadding(context), 0),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                              DesktopUi.isDesktopPlatform
                                  ? Icons.arrow_back_rounded
                                  : Icons.arrow_back_ios_new_rounded,
                              size: 18,
                              color: theme.colorScheme.onSurface),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '源市场',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _loading ? null : _load,
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('刷新'),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        Responsive.pagePadding(context), 2,
                        Responsive.pagePadding(context), 8),
                    child: Text(
                      '第三方自定义源市场。安装前请阅读风险提示。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  Expanded(child: _buildBody(theme)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading && _entries == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded,
                  size: 42,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              const Text('源市场拉取失败', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('$_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
              const SizedBox(height: 14),
              FilledButton.tonal(
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final entries = _entries ?? const <MarketSourceEntry>[];
    if (entries.isEmpty) {
      return const Center(child: Text('暂无可用来源'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _SourceTile(
        entry: entries[i],
        onInstall: () => _confirmInstall(entries[i]),
        onUninstall: () => _uninstall(entries[i]),
        onDetail: () => _showDetail(entries[i]),
      ),
    );
  }
}

/// 单条源市场卡片：名称/类型/版本/作者 + 安装/已安装/更新/卸载 状态。
class _SourceTile extends StatefulWidget {
  final MarketSourceEntry entry;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;
  final VoidCallback onDetail;

  const _SourceTile({
    required this.entry,
    required this.onInstall,
    required this.onUninstall,
    required this.onDetail,
  });

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  /// 当前安装状态：null=计算中，"installed"=已安装，"update"=可更新，"new"=未安装。
  String? _state;

  @override
  void initState() {
    super.initState();
    _computeState();
  }

  Future<void> _computeState() async {
    final installed = await widget.entry.installed();
    if (!mounted) return;
    if (installed) {
      setState(() => _state = 'installed');
      return;
    }
    final needs = await widget.entry.needsUpdate();
    if (!mounted) return;
    setState(() => _state = needs ? 'update' : 'new');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final isInstalled = _state == 'installed';
    final isUpdate = _state == 'update';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              entry.type == 'video'
                  ? Icons.play_circle_rounded
                  : entry.type == 'novel'
                      ? Icons.menu_book_rounded
                      : Icons.extension_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                entry.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'v${entry.version}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        if (entry.description != null &&
                            entry.description!.isNotEmpty)
                          Text(
                            entry.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.65)),
                          ),
                        const SizedBox(height: 3),
                        Text(
                          '${entry.type}源 · ${entry.provider}${entry.author.isNotEmpty ? ' · ${entry.author}' : ''}',
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.45)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '查看规则',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.rule_rounded,
                        size: 17,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                    onPressed: widget.onDetail,
                  ),
                  const SizedBox(width: 8),
          isInstalled
              ? TextButton(
                  onPressed: widget.onUninstall,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                  ),
                  child: const Text('卸载', style: TextStyle(fontSize: 12)),
                )
              : FilledButton.tonal(
                  onPressed: widget.onInstall,
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  child: Text(isUpdate ? '更新' : '安装',
                      style: const TextStyle(fontSize: 12.5)),
                ),
        ],
      ),
    );
  }
}