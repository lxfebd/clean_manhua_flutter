import 'package:flutter/material.dart';

import '../sources/dsl/custom_source_def.dart';
import '../sources/dsl/custom_source_store.dart';
import '../sources/dsl/source_market.dart';
import '../net/error_logger.dart';
import 'responsive.dart';
import 'widgets/app_toast.dart';
import 'keyboard_shortcuts.dart';

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
  String? _error;
  bool _loading = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// 本地已安装的自定义源版本表（id → 版本），供卡片同步判断
  /// 安装/可更新/未安装，避免每卡异步查询造成按钮跳变闪烁。
  final Map<String, String> _localVersions = {};

  /// 正在安装/卸载的源 id：该卡按钮禁用并显示 spinner，防连点。
  String? _busyId;

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
      // 并行：拉索引 + 读本地已装版本表；本地读取失败只回退空表，不阻塞市场。
      final entriesF = SourceMarket.fetchIndex();
      final localsF = _loadLocals();
      final locals = await localsF;
      final entries = await entriesF;
      if (mounted) {
        setState(() {
          _localVersions
            ..clear()
            ..addEntries(locals.map((d) => MapEntry(d.id, d.version)));
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      ErrorLogger.instance.warn('source market index failed: $e');
      if (mounted) {
        setState(() {
          _error = '拉取源市场失败，请检查网络后重试';
          _loading = false;
        });
      }
    }
  }

  /// 读取本地已装源版本表（快，先于索引就绪），卡片同步拿到状态。
  Future<List<CustomSourceDef>> _loadLocals() async {
    try {
      return await CustomSourceStore.all();
    } catch (e) {
      // 本地版本表读失败只回退空表（卡片全部显示未安装），但需可观测
      ErrorLogger.instance.warn('read local custom sources failed: $e');
      return const <CustomSourceDef>[];
    }
  }

  /// 安装/更新单个源。
  Future<void> _install(MarketSourceEntry entry) async {
    if (_busyId != null) return; // 防连点：一次只处理一个源
    setState(() => _busyId = entry.id);
    try {
      final ok = await SourceMarket.install(entry);
      if (!mounted) return;
      AppToast.show(
        context,
        ok ? '已安装：${entry.name} v${entry.version}' : '安装失败：${entry.name} 校验未通过',
        error: !ok,
      );
      setState(() => _localVersions[entry.id] = entry.version); // 刷新安装态
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// 卸载已安装的源（移除解析规则，书架收藏不受影响）。
  Future<void> _uninstall(MarketSourceEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
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
    if (_busyId != null) return; // 防连点
    setState(() => _busyId = entry.id);
    try {
      final removed = await CustomSourceStore.remove(entry.id);
      if (!mounted) return;
      AppToast.show(
        context,
        removed ? '已卸载：${entry.name}' : '卸载失败：${entry.name} 未找到',
        error: !removed,
      );
      if (removed) setState(() => _localVersions.remove(entry.id)); // 刷新安装态
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// 确认安装对话框（第三方源风险提示）。
  Future<void> _confirmInstall(MarketSourceEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
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
      ('分类列表', Icons.list_alt_rounded, (def.categoryListUrl ?? '').isNotEmpty),
      ('排行榜', Icons.leaderboard_rounded, (def.rankUrl ?? '').isNotEmpty),
      ('详情/章节', Icons.menu_book_rounded, (def.detailUrl ?? '').isNotEmpty),
    ];

    // 抽取方式摘要：列表通道 selector/regex，详情章节/pic 同理。
    String method(DslListRule? r) =>
        r == null
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
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                    ),
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
                  if (def.picHeaders.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '图片防盗链：${def.picHeaders.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 6),
                    child: Text(
                      '能力',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (label, icon, ok) in cap)
                        Chip(
                          avatar: Icon(
                            icon,
                            size: 14,
                            color:
                                ok
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface.withValues(
                                      alpha: 0.3,
                                    ),
                          ),
                          label: Text(
                            label,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: ok ? 0.85 : 0.4,
                              ),
                            ),
                          ),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          backgroundColor:
                              ok
                                  ? theme.colorScheme.primary.withValues(
                                    alpha: 0.08,
                                  )
                                  : theme.colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.4),
                          side: BorderSide.none,
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 6),
                    child: Text(
                      '抽取方式',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ),
                  _detailRow(theme, '列表', method(def.categoryListRule)),
                  _detailRow(theme, '搜索', method(def.searchRule)),
                  _detailRow(
                    theme,
                    '分类',
                    def.categoriesRule == null
                        ? '—'
                        : 'CSS ${def.categoriesRule!.selector}',
                  ),
                  _detailRow(
                    theme,
                    '章节',
                    d == null
                        ? '—'
                        : d.chapters.isNotEmpty
                        ? 'CSS ${d.chapters}'
                        : d.chaptersRe.isNotEmpty
                        ? '正则（命名组 href/title）'
                        : '—',
                  ),
                  _detailRow(
                    theme,
                    '图片/播放',
                    d == null
                        ? '—'
                        : d.picListCss.isNotEmpty
                        ? 'CSS ${d.picListCss}'
                        : d.picListRe.isNotEmpty
                        ? '正则（捕获组 1）'
                        : '—',
                  ),
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
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => EscPopScope(child: _buildRoot(context));

  Widget _buildRoot(BuildContext context) {
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
                      Responsive.pagePadding(context),
                      10,
                      Responsive.pagePadding(context),
                      0,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '返回',
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                            DesktopUi.isDesktopPlatform
                                ? Icons.arrow_back_rounded
                                : Icons.arrow_back_ios_new_rounded,
                            size: 18,
                            color: theme.colorScheme.onSurface,
                          ),
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
                        if (Responsive.isLarge(context))
                          SizedBox(
                            width: 200,
                            height: 34,
                            child: TextField(
                              controller: _searchCtrl,
                              onChanged:
                                  (v) => setState(() => _query = v.trim()),
                              style: const TextStyle(fontSize: 12.5),
                              decoration: InputDecoration(
                                hintText: '搜索源名称/类型',
                                hintStyle: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  size: 17,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.15),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.15),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
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
                      Responsive.pagePadding(context),
                      2,
                      Responsive.pagePadding(context),
                      8,
                    ),
                    child: Text(
                      '第三方自定义源市场。安装前请阅读风险提示。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.55,
                        ),
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
              Icon(
                Icons.cloud_off_rounded,
                size: 42,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 12),
              const Text(
                '源市场拉取失败',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final entries = _entries ?? const <MarketSourceEntry>[];
    if (entries.isEmpty) {
      return const Center(child: Text('暂无可用来源'));
    }
    final q = _query.toLowerCase();
    final visible =
        q.isEmpty
            ? entries
            : entries
                .where(
                  (e) =>
                      e.name.toLowerCase().contains(q) ||
                      e.type.toLowerCase().contains(q) ||
                      e.id.toLowerCase().contains(q),
                )
                .toList();
    if (visible.isEmpty) {
      return Center(
        child: Text(
          '没有匹配「$_query」的来源',
          style: TextStyle(
            fontSize: 13,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder:
          (_, i) => _SourceTile(
            entry: visible[i],
            localVersion: _localVersions[visible[i].id],
            busy: _busyId == visible[i].id,
            onInstall: () => _confirmInstall(visible[i]),
            onUninstall: () => _uninstall(visible[i]),
            onDetail: () => _showDetail(visible[i]),
          ),
    );
  }
}

/// 单条源市场卡片：名称/类型/版本/作者 + 安装/已安装/更新/卸载 状态。
class _SourceTile extends StatelessWidget {
  final MarketSourceEntry entry;

  /// 本地已装版本（null=未安装），由页面预取同步传入，杜绝状态跳变。
  final String? localVersion;

  /// 安装/卸载进行中：按钮禁用并显示小 spinner，防连点。
  final bool busy;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;
  final VoidCallback onDetail;

  const _SourceTile({
    required this.entry,
    required this.localVersion,
    this.busy = false,
    required this.onInstall,
    required this.onUninstall,
    required this.onDetail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = this.entry;
    final isInstalled = localVersion == entry.version;
    final isUpdate = localVersion != null && !isInstalled;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
        ),
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
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'v${entry.version}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                if (entry.description != null && entry.description!.isNotEmpty)
                  Text(
                    entry.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                const SizedBox(height: 3),
                Text(
                  '${entry.type}源 · ${entry.provider}${entry.author.isNotEmpty ? ' · ${entry.author}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '查看规则',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.rule_rounded,
              size: 17,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            onPressed: onDetail,
          ),
          const SizedBox(width: 8),
          isInstalled
              ? TextButton(
                onPressed: busy ? null : onUninstall,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
                child:
                    busy
                        ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Text('卸载', style: TextStyle(fontSize: 12)),
              )
              : FilledButton.tonal(
                onPressed: busy ? null : onInstall,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
                child:
                    busy
                        ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Text(
                          isUpdate ? '更新' : '安装',
                          style: const TextStyle(fontSize: 12.5),
                        ),
              ),
        ],
      ),
    );
  }
}
