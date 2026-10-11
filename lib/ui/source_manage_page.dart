import 'dart:convert';

import 'package:flutter/material.dart';

import '../sources/dsl/custom_source_def.dart';
import '../sources/dsl/custom_source_store.dart';
import '../net/error_logger.dart';
import '../net/source_health_monitor.dart';
import '../sources/source_config.dart';
import '../sources/source_manager.dart';
import '../sources/source_plugin_manager.dart';
import 'responsive.dart';
import 'source_market_page.dart';
import 'widgets/app_toast.dart';
import 'widgets/state_view.dart';
import 'keyboard_shortcuts.dart';

part 'source_manage_widgets.dart';

/// 自定义源 JSON 大小上限（64 KB）：导入粘贴和编辑器共用。正常一份源定义
/// 通常几百字节到几 KB，超过这个上限基本是异常输入（或攻击面），直接拒绝
/// 可以防止 jsonDecode / DSL 校验阶段长时间占用主 Isolate（P1 修复）。
const int kCustomSourceJsonMaxBytes = 64 * 1024;

/// 数据源管理页：列出所有源，可启用/停用、编辑域名/图片CDN/代理/请求头/层级，
/// 保存后持久化（源配置免发版更新），并同步 SourceManager 的启用列表。
class SourceManagePage extends StatefulWidget {
  const SourceManagePage({super.key});

  @override
  State<SourceManagePage> createState() => _SourceManagePageState();
}

class _SourceManagePageState extends State<SourceManagePage> {
  List<SourceConfig>? _cfgs;
  String? _error;

  /// 启停切换进行中的源 id：开关禁用，防连点。
  final Set<String> _togglingIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cfgs = await SourceConfigStore.all();
      if (mounted) {
        setState(() {
          _cfgs = cfgs;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _toggleEnabled(SourceConfig cfg, bool value) async {
    if (_togglingIds.contains(cfg.id)) return; // 防连点
    setState(() => _togglingIds.add(cfg.id));
    try {
      await SourceConfigStore.save(
        SourceConfig(
          engineId: cfg.engineId,
          id: cfg.id,
          name: cfg.name,
          iconUrl: cfg.iconUrl,
          hosts: cfg.hosts,
          imageHosts: cfg.imageHosts,
          headers: cfg.headers,
          requiresLogin: cfg.requiresLogin,
          isEnabled: value,
          tier: cfg.tier,
          proxy: cfg.proxy,
        ),
      );
      await SourceManager.ensureEnabledCurrent();
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '「${cfg.name}」启停失败，请重试');
      ErrorLogger.instance.warn('source ${cfg.name} toggle failed: $e');
      await _load(); // 回弹开关到真实状态，避免 UI 与存储不一致
    } finally {
      if (mounted) setState(() => _togglingIds.remove(cfg.id));
    }
  }

  Future<void> _edit(SourceConfig cfg) async {
    final updated = await showDialog<SourceConfig>(
      context: context,
      builder: (_) => _SourceEditDialog(config: cfg),
    );
    if (updated == null) return;
    await SourceConfigStore.save(updated);
    await SourceManager.ensureEnabledCurrent();
    await _load();
    if (mounted) {
      AppToast.info(context, '已保存「${updated.name}」的配置');
    }
  }

  Future<void> _resetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: const Text('恢复默认配置'),
            content: const Text('将清空所有源的自定义域名/代理等修改，恢复内置默认。确定继续？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    await SourceConfigStore.resetToDefaults();
    await SourceManager.ensureEnabledCurrent();
    await _load();
  }

  /// 打开自定义源管理对话框（新建/导入/导出/编辑 JSON/删除）。
  Future<void> _openCustomSources() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const CustomSourceManageDialog(),
    );
    // 关闭后刷新内置列表（自定义源启用状态可能变化）
    await _load();
  }

  /// 打开源市场页（拉取远端索引，一键安装/更新自定义源）。
  void _openMarket() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SourceMarketPage()));
  }

  @override
  Widget build(BuildContext context) => EscPopScope(child: _buildRoot(context));

  Widget _buildRoot(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        // 整页限宽居中（M3 LS-U2）：本页是独立路由，桌面大屏不拉满全宽。
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
                          '数据源管理',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _openCustomSources,
                          icon: const Icon(Icons.extension_rounded, size: 16),
                          label: const Text('自定义源'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton.icon(
                          onPressed: _openMarket,
                          icon: const Icon(Icons.storefront_rounded, size: 16),
                          label: const Text('源市场'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton.icon(
                          onPressed: _resetAll,
                          icon: const Icon(Icons.restart_alt_rounded, size: 16),
                          label: const Text('恢复默认'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.primary,
                          ),
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
                      '源 = 引擎代码（随版本）+ 此配置（可改，免发版）。域名失效时在此替换即可。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.55,
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: _buildList(theme)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_error != null) {
      return StateView(
        kind: StateViewKind.error,
        message: '加载失败\n$_error',
        onRetry: _load,
      );
    }
    final cfgs = _cfgs;
    if (cfgs == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return ListView.separated(
      // 与头部用同一 pagePadding，大屏不因硬编码 14 与标题错位。
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        4,
        Responsive.pagePadding(context),
        (Responsive.isTablet(context) ? 24 : 110),
      ),
      itemCount: cfgs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder:
          (_, i) => _SourceCard(
            cfg: cfgs[i],
            busy: _togglingIds.contains(cfgs[i].id),
            onTap: () => _edit(cfgs[i]),
            onToggle: (v) => _toggleEnabled(cfgs[i], v),
          ),
    );
  }
}

