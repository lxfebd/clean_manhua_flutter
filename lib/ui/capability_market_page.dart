import 'package:flutter/material.dart';

import '../capabilities/capability_market.dart';
import '../capabilities/capability_plugin.dart' show CapabilityWeight;
import '../capabilities/capability_plugin_manager.dart';
import '../net/error_logger.dart';
import 'responsive.dart';
import 'widgets/app_toast.dart';

/// 能力市场页：拉取远端索引展示 AI/视频/实用能力，支持一键安装/更新/卸载。
///
/// 与源市场页（SourceMarketPage）同架子：索引拉取走 CapabilityMarket
/// （RateLimiter + 缓存回退），安装构造 CapabilityPlugin 交给 Manager。
/// 能力实现正文随 App 发布（内置壳）或由插件继承类 bind 挂 FFI/权重——
/// 远端索引只分发「声明」。
class CapabilityMarketPage extends StatefulWidget {
  const CapabilityMarketPage({super.key});

  @override
  State<CapabilityMarketPage> createState() => _CapabilityMarketPageState();
}

class _CapabilityMarketPageState extends State<CapabilityMarketPage> {
  List<MarketCapabilityEntry>? _entries;
  String? _error;
  bool _loading = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

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
      final entries = await CapabilityMarket.fetchIndex();
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      ErrorLogger.instance.warn('capability market index failed: $e');
      if (mounted) {
        setState(() {
          _error = '拉取能力市场失败，请检查网络后重试';
          _loading = false;
        });
      }
    }
  }

  /// 安装/更新单个能力。
  Future<void> _install(MarketCapabilityEntry entry) async {
    if (_installingIds.contains(entry.id)) return; // 防重入：同一能力并发安装
    setState(() => _installingIds.add(entry.id));
    try {
      final ok = await CapabilityMarket.install(entry);
      if (!mounted) return;
      AppToast.show(context, ok
          ? '已安装：${entry.name} v${entry.version}'
          : '安装失败：${entry.name} 已存在或注册异常',
          error: !ok);
      setState(() {}); // 刷新 installed 状态
    } catch (e) {
      // install 内部异常：给用户明确反馈，不再静默（无任何提示用户会以为没点中）。
      ErrorLogger.instance.warn('capability install failed: $e');
      if (mounted) {
        AppToast.error(context, '安装失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _installingIds.remove(entry.id));
    }
  }

  /// 正在安装的能力 id 集合（tile 按钮转 loading，禁用防重复点击）。
  final Set<String> _installingIds = {};

  /// 卸载已安装的能力（内置能力不可卸载，返回 false）。
  Future<void> _uninstall(MarketCapabilityEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载能力'),
        content: Text(
          '卸载「${entry.name}」将移除其本地权重与配置。\n'
          '再次使用时需重新下载权重。',
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
    try {
      final removed = await CapabilityMarket.uninstall(entry.id);
      if (!mounted) return;
      AppToast.show(context, removed ? '已卸载：${entry.name}' : '卸载失败：内置能力不可卸载',
          error: !removed);
      setState(() {}); // 刷新 installed 状态
    } catch (e) {
      ErrorLogger.instance.warn('capability uninstall failed: $e');
      if (mounted) {
        AppToast.error(context, '卸载失败，请重试');
      }
    }
  }

  /// 确认安装对话框（第三方能力风险提示）。
  Future<void> _confirmInstall(MarketCapabilityEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装能力'),
        content: Text(
          '即将安装：${entry.name} v${entry.version}\n'
          '来源：${entry.author}\n\n'
          'AI 能力可能下载较大模型权重（数十~数百 MB），'
          '请确认网络环境与存储空间。',
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

  /// 能力分类的中文标签（弹窗与 tile 共用语义）。
  String _capCategory(String c) {
    switch (c) {
      case 'ai':
        return 'AI 能力';
      case 'video':
        return '视频增强';
      case 'utility':
        return '实用工具';
      default:
        return c;
    }
  }

  /// 查看能力详情：id/分类/作者/版本 + 权重清单（文件名/体积/SHA256 钉死）。
  void _showDetail(MarketCapabilityEntry entry) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          entry.name,
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
                  '${entry.id} · v${entry.version}',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_capCategory(entry.category)} · ${entry.author}',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                ),
                if (entry.description != null && entry.description!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      entry.description!,
                      style: const TextStyle(fontSize: 13, height: 1.55),
                    ),
                  ),
                if (entry.weights.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 6),
                    child: Text('依赖权重（下载后 SHA256 校验）',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.8))),
                  ),
                for (final w in entry.weights)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.storage_rounded,
                                  size: 14,
                                  color: theme.colorScheme.primary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  w.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              Text(
                                w.sizeBytes >= 1024 * 1024
                                    ? '${(w.sizeBytes / (1024 * 1024)).toStringAsFixed(1)}MB'
                                    : '${(w.sizeBytes / 1024).toStringAsFixed(0)}KB',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.55)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'SHA256 ${w.sha256}',
                            style: TextStyle(
                                fontSize: 10,
                                fontFamily: 'monospace',
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.5)),
                          ),
                        ],
                      ),
                    ),
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
                          tooltip: '返回',
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
                          '能力市场',
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
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                              style: const TextStyle(fontSize: 12.5),
                              decoration: InputDecoration(
                                hintText: '搜索能力名称/分类',
                                hintStyle: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.4)),
                                prefixIcon: Icon(Icons.search_rounded,
                                    size: 17,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.5)),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.15)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.15)),
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
                        Responsive.pagePadding(context), 2,
                        Responsive.pagePadding(context), 8),
                    child: Text(
                      'AI/视频/实用能力市场。权重按需下载，安装前请阅读风险提示。',
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
              const Text('能力市场拉取失败', style: TextStyle(fontWeight: FontWeight.w600)),
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
    final entries = _entries ?? const <MarketCapabilityEntry>[];
    if (entries.isEmpty) {
      return const Center(child: Text('暂无可用能力'));
    }
    final q = _query.toLowerCase();
    final visible = q.isEmpty
        ? entries
        : entries
            .where((e) =>
                e.name.toLowerCase().contains(q) ||
                e.category.toLowerCase().contains(q) ||
                e.id.toLowerCase().contains(q))
            .toList();
    if (visible.isEmpty) {
      return Center(
        child: Text(
          '没有匹配「$_query」的能力',
          style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _CapabilityMarketTile(
        entry: visible[i],
        onInstall: () => _confirmInstall(visible[i]),
        installing: _installingIds.contains(visible[i].id),
        onUninstall: () => _uninstall(visible[i]),
        onDetail: () => _showDetail(visible[i]),
      ),
    );
  }
}

/// 单条能力市场卡片：名称/分类/版本/作者/权重体积 + 安装/已安装/更新/卸载。
class _CapabilityMarketTile extends StatefulWidget {
  final MarketCapabilityEntry entry;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;
  final VoidCallback onDetail;
  final bool installing;

  const _CapabilityMarketTile({
    required this.entry,
    required this.onInstall,
    required this.onUninstall,
    required this.onDetail,
    this.installing = false,
  });

  @override
  State<_CapabilityMarketTile> createState() => _CapabilityMarketTileState();
}

class _CapabilityMarketTileState extends State<_CapabilityMarketTile> {
  /// 当前安装状态：null=计算中，"installed"=已安装，"update"=可更新，"new"=未安装。
  String? _state;

  @override
  void initState() {
    super.initState();
    _computeState();
    // 注册表变更（安装/卸载/启停）→ 重算本 tile 的安装状态。
    // 不监听则安装成功后按钮仍停留「安装」（tile 同 key 复用不重建）。
    CapabilityPluginManager.instance.revision.addListener(_onRevision);
  }

  @override
  void dispose() {
    CapabilityPluginManager.instance.revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (mounted) _computeState();
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

  String _categoryLabel(String c) {
    switch (c) {
      case 'ai':
        return 'AI 能力';
      case 'video':
        return '视频增强';
      case 'utility':
        return '实用工具';
      default:
        return c;
    }
  }

  String _weightSummary(List<CapabilityWeight> weights) {
    // weights 是 CapabilityWeight 列表，按体积汇总
    double totalMB = 0;
    for (final w in weights) {
      totalMB += w.sizeBytes.toDouble();
    }
    if (totalMB <= 0) return '';
    final mb = totalMB / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)}GB 权重'
        : '${mb.toStringAsFixed(0)}MB 权重';
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
              entry.category == 'ai'
                  ? Icons.auto_awesome_outlined
                  : entry.category == 'video'
                      ? Icons.slow_motion_video_outlined
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
                          color:
                              theme.colorScheme.onSurface.withValues(alpha: 0.5)),
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
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.65)),
                  ),
                const SizedBox(height: 3),
                Text(
                  '${_categoryLabel(entry.category)} · ${entry.author}'
                  '${_weightSummary(entry.weights).isNotEmpty ? ' · ${_weightSummary(entry.weights)}' : ''}',
                  style: TextStyle(
                      fontSize: 11,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.45)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '查看详情',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.info_outline_rounded,
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
              : widget.installing
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
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
