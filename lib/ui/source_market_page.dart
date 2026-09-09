import 'package:flutter/material.dart';

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
      ),
    );
  }
}

/// 单条源市场卡片：名称/类型/版本/作者 + 安装/已安装/更新 状态。
class _SourceTile extends StatefulWidget {
  final MarketSourceEntry entry;
  final VoidCallback onInstall;

  const _SourceTile({required this.entry, required this.onInstall});

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
                  '${entry.type}源 · ${entry.provider}${entry.author.isNotEmpty ? ' · ${entry.author}' : ''}',
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
              ? Text(
                  '已安装',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.4)),
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