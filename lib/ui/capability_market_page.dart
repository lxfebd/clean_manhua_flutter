import 'package:flutter/material.dart';

import '../capabilities/capability_market.dart';
import '../capabilities/capability_plugin.dart' show CapabilityWeight;
import '../capabilities/capability_plugin_manager.dart';
import 'responsive.dart';

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
      final entries = await CapabilityMarket.fetchIndex();
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

  /// 安装/更新单个能力。
  Future<void> _install(MarketCapabilityEntry entry) async {
    final ok = await CapabilityMarket.install(entry);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '已安装：${entry.name} v${entry.version}'
          : '安装失败：${entry.name} 已存在或注册异常'),
      duration: const Duration(seconds: 2),
    ));
    setState(() {}); // 刷新 installed 状态
  }

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
    final removed = await CapabilityMarket.uninstall(entry.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(removed ? '已卸载：${entry.name}' : '卸载失败：内置能力不可卸载'),
      duration: const Duration(seconds: 2),
    ));
    setState(() {}); // 刷新 installed 状态
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
                          '能力市场',
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
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _CapabilityMarketTile(
        entry: entries[i],
        onInstall: () => _confirmInstall(entries[i]),
        onUninstall: () => _uninstall(entries[i]),
      ),
    );
  }
}

/// 单条能力市场卡片：名称/分类/版本/作者/权重体积 + 安装/已安装/更新/卸载。
class _CapabilityMarketTile extends StatefulWidget {
  final MarketCapabilityEntry entry;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;

  const _CapabilityMarketTile({
    required this.entry,
    required this.onInstall,
    required this.onUninstall,
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
