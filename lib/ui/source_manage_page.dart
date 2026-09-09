import 'dart:convert';

import 'package:flutter/material.dart';

import '../sources/dsl/custom_source_def.dart';
import '../sources/dsl/custom_source_store.dart';
import '../net/source_health_monitor.dart';
import '../sources/source_config.dart';
import '../sources/source_manager.dart';
import '../sources/source_plugin_manager.dart';
import 'responsive.dart';
import 'source_market_page.dart';

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
    await SourceConfigStore.save(SourceConfig(
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
    ));
    await SourceManager.ensureEnabledCurrent();
    await _load();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存「${updated.name}」的配置')),
      );
    }
  }

  Future<void> _resetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SourceMarketPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                        size: 18, color: theme.colorScheme.onSurface),
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
                  Responsive.pagePadding(context), 2,
                  Responsive.pagePadding(context), 8),
              child: Text(
                '源 = 引擎代码（随版本）+ 此配置（可改，免发版）。域名失效时在此替换即可。',
                style: TextStyle(
                  fontSize: 11.5,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
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
      return Center(child: Text('加载失败\n$_error'));
    }
    final cfgs = _cfgs;
    if (cfgs == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return ListView.separated(
      // 与头部用同一 pagePadding，大屏不因硬编码 14 与标题错位。
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 4,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
      itemCount: cfgs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _SourceCard(
        cfg: cfgs[i],
        onTap: () => _edit(cfgs[i]),
        onToggle: (v) => _toggleEnabled(cfgs[i], v),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  final SourceConfig cfg;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  const _SourceCard({required this.cfg, required this.onTap, required this.onToggle});

  String _tierLabel() {
    switch (cfg.tier) {
      case SourceTier.primary:
        return '首选';
      case SourceTier.fallback:
        return '兜底';
      case SourceTier.disabled:
        return '已停用';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = cfg.isEnabled && cfg.tier != SourceTier.disabled;
    final firstHost = cfg.hosts.isNotEmpty ? cfg.hosts.first : '未配置域名';
    return ValueListenableBuilder<int>(
      valueListenable: SourceHealthMonitor.instance.revision,
      builder: (_, __, ___) {
        final health = SourceHealthMonitor.instance.healthOf(cfg.engineId);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: enabled
                      ? scheme.primary.withValues(alpha: 0.12)
                      : scheme.onSurface.withValues(alpha: 0.06),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: enabled
                            ? [scheme.primary, scheme.secondary]
                            : [scheme.onSurface.withValues(alpha: 0.25), scheme.onSurface.withValues(alpha: 0.25)],
                      ),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      Icons.public_rounded,
                      size: 20,
                      color: enabled ? Colors.white : scheme.onSurface.withValues(alpha: 0.6),
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
                                cfg.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: cfg.tier == SourceTier.primary
                                    ? scheme.primary.withValues(alpha: 0.14)
                                    : cfg.tier == SourceTier.disabled
                                        ? scheme.error.withValues(alpha: 0.12)
                                        : scheme.onSurface.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _tierLabel(),
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: cfg.tier == SourceTier.primary
                                      ? scheme.primary
                                      : cfg.tier == SourceTier.disabled
                                          ? scheme.error
                                          : scheme.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                            if (cfg.requiresLogin)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Icon(Icons.lock_outline_rounded,
                                    size: 12, color: scheme.onSurface.withValues(alpha: 0.4)),
                              ),
                            const SizedBox(width: 6),
                            _HealthDot(health: health),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          firstHost,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: enabled
                                ? scheme.onSurface.withValues(alpha: 0.55)
                                : scheme.error.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: enabled,
                    onChanged: onToggle,
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 20, color: scheme.onSurface.withValues(alpha: 0.3)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 健康状态灯：绿=健康，黄=一般/较差，红=不可用，灰=未检测。
class _HealthDot extends StatelessWidget {
  final SourceHealth? health;
  const _HealthDot({this.health});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (health == null) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.onSurface.withValues(alpha: 0.2),
        ),
      );
    }
    final Color color;
    if (health!.score >= 80) {
      color = Colors.green;
    } else if (health!.score >= 50) {
      color = Colors.orange;
    } else if (health!.score >= 25) {
      color = Colors.deepOrange;
    } else {
      color = scheme.error;
    }
    return Tooltip(
      message:
          '健康度 ${health!.score}/100（${health!.scoreLabel}）\n延迟 ${health!.latencyMs}ms · 成功率 ${(health!.successRate * 100).round()}%',
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}

/// 编辑单个源的对话框：hosts / imageHosts / proxy / headers / requiresLogin / tier。
class _SourceEditDialog extends StatefulWidget {
  final SourceConfig config;
  const _SourceEditDialog({required this.config});

  @override
  State<_SourceEditDialog> createState() => _SourceEditDialogState();
}

class _SourceEditDialogState extends State<_SourceEditDialog> {
  late final TextEditingController _hosts;
  late final TextEditingController _imageHosts;
  late final TextEditingController _proxy;
  late final TextEditingController _headers;
  late bool _requiresLogin;
  late SourceTier _tier;

  static const List<String> _tierNames = ['首选', '兜底', '停用'];

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _hosts = TextEditingController(text: c.hosts.join('\n'));
    _imageHosts = TextEditingController(text: c.imageHosts.join('\n'));
    _proxy = TextEditingController(text: c.proxy ?? '');
    _headers = TextEditingController(
        text: c.headers.entries.map((e) => '${e.key}=${e.value}').join('\n'));
    _requiresLogin = c.requiresLogin;
    _tier = c.tier;
  }

  @override
  void dispose() {
    _hosts.dispose();
    _imageHosts.dispose();
    _proxy.dispose();
    _headers.dispose();
    super.dispose();
  }

  List<String> _lines(TextEditingController c) => c.text
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Map<String, String> _parseHeaders() {
    final out = <String, String>{};
    for (final line in _lines(_headers)) {
      final idx = line.indexOf('=');
      if (idx > 0) out[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text('编辑「${widget.config.name}」'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field('域名 hosts（每行一个，可多个镜像）', _hosts, maxLines: 5),
            const SizedBox(height: 10),
            _field('图片 CDN imageHosts（每行一个，可选）', _imageHosts, maxLines: 3),
            const SizedBox(height: 10),
            _field('代理 proxy（可选，如 socks5://127.0.0.1:1080）', _proxy, maxLines: 1),
            const SizedBox(height: 10),
            _field('请求头 headers（每行 key=value，可选）', _headers, maxLines: 3),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('需要登录', style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface)),
                Switch(
                  value: _requiresLogin,
                  onChanged: (v) => setState(() => _requiresLogin = v),
                ),
                const SizedBox(width: 16),
                Text('层级', style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface)),
                const SizedBox(width: 8),
                DropdownButton<SourceTier>(
                  value: _tier,
                  items: [
                    for (var i = 0; i < _tierNames.length; i++)
                      DropdownMenuItem(
                        value: SourceTier.values[i],
                        child: Text(_tierNames[i]),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _tier = v);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final c = widget.config;
            Navigator.pop(context, SourceConfig(
              engineId: c.engineId,
              id: c.id,
              name: c.name,
              iconUrl: c.iconUrl,
              hosts: _lines(_hosts),
              imageHosts: _lines(_imageHosts),
              headers: _parseHeaders(),
              requiresLogin: _requiresLogin,
              isEnabled: _tier == SourceTier.disabled ? false : c.isEnabled,
              tier: _tier,
              proxy: _proxy.text.trim().isEmpty ? null : _proxy.text.trim(),
            ));
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController c, {required int maxLines}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: c,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 12.5),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }
}

/// 自定义源（JSON DSL）管理对话框：列表 + 导入/导出/新建/删除/编辑。
class CustomSourceManageDialog extends StatefulWidget {
  const CustomSourceManageDialog({super.key});

  @override
  State<CustomSourceManageDialog> createState() => _CustomSourceManageDialogState();
}

class _CustomSourceManageDialogState extends State<CustomSourceManageDialog> {
  List<CustomSourceDef>? _defs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final defs = await CustomSourceStore.all();
      if (mounted) {
        setState(() {
          _defs = defs;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 打开 JSON 编辑器（新建或编辑）。
  Future<void> _openEditor([CustomSourceDef? def]) async {
    final result = await showDialog<CustomSourceDef>(
      context: context,
      builder: (_) => CustomSourceEditorDialog(def: def),
    );
    if (result != null) await _load();
  }

  Future<void> _import() async {
    final text = await _promptText(
      '导入自定义源',
      '粘贴 JSON（单份或数组）。校验通过后立即生效。',
    );
    if (text == null) return;
    final ok = await CustomSourceStore.importJson(text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok > 0 ? '成功导入 $ok 个自定义源' : '导入失败：JSON 无效或未通过校验'),
      ));
    }
    await _load();
  }

  Future<void> _export(CustomSourceDef def) async {
    final json = await CustomSourceStore.exportJson(def.id);
    if (json.isEmpty) return;
    await _showJson('导出「${def.name}」', json);
  }

  Future<void> _remove(CustomSourceDef def) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('删除自定义源'),
        content: Text('删除「${def.name}」将移除其解析规则，书架中的收藏不受影响。确定？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await CustomSourceStore.remove(def.id);
    await _load();
  }

  Future<void> _toggle(CustomSourceDef def, bool enabled) async {
    await SourcePluginManager.instance.setEnabled(def.id, enabled);
    await _load();
  }

  Future<String?> _promptText(String title, String label) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title),
        content: TextField(
          controller: c,
          maxLines: 8,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
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
    final text = c.text.trim();
    c.dispose();
    return ok == true ? text : null;
  }

  Future<void> _showJson(String title, String json) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace', height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defs = _defs;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.extension_rounded, size: 20),
          const SizedBox(width: 8),
          const Text('自定义源'),
          const Spacer(),
          TextButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.file_download_rounded, size: 16),
            label: const Text('导入'),
          ),
          TextButton.icon(
            onPressed: () => _openEditor(null),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('新建'),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 360,
        child: _error != null
            ? Center(child: Text('加载失败\n$_error'))
            : defs == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : defs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.extension_off_rounded,
                                size: 40, color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
                            const SizedBox(height: 10),
                            Text('暂无自定义源', style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: defs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, i) => _CustomSourceTile(
                          def: defs[i],
                          enabled: SourcePluginManager.instance.isEnabledSync(defs[i].id),
                          onToggle: (v) => _toggle(defs[i], v),
                          onEdit: () => _openEditor(defs[i]),
                          onExport: () => _export(defs[i]),
                          onRemove: () => _remove(defs[i]),
                        ),
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _CustomSourceTile extends StatelessWidget {
  final CustomSourceDef def;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onExport;
  final VoidCallback onRemove;

  const _CustomSourceTile({
    required this.def,
    required this.enabled,
    required this.onToggle,
    required this.onEdit,
    required this.onExport,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onEdit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      def.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      def.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: scheme.onSurface.withValues(alpha: 0.5)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Switch(value: enabled, onChanged: onToggle),
          IconButton(
            tooltip: '导出',
            iconSize: 17,
            onPressed: onExport,
            icon: Icon(Icons.ios_share_rounded, color: scheme.onSurface.withValues(alpha: 0.5)),
          ),
          IconButton(
            tooltip: '删除',
            iconSize: 17,
            onPressed: onRemove,
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }
}

/// JSON DSL 编辑器：文本域 + 校验提示 + 示例模板。
class CustomSourceEditorDialog extends StatefulWidget {
  final CustomSourceDef? def;
  const CustomSourceEditorDialog({super.key, this.def});

  @override
  State<CustomSourceEditorDialog> createState() => _CustomSourceEditorDialogState();
}

class _CustomSourceEditorDialogState extends State<CustomSourceEditorDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.def == null
          ? _template()
          : const JsonEncoder.withIndent('  ').convert(widget.def!.toJson()),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _template() => const JsonEncoder.withIndent('  ').convert({
        'id': 'my_source',
        'name': '我的漫画源',
        'type': 'comic',
        'version': '1.0.0',
        'author': 'me',
        'baseUrl': 'https://example.com',
        'headers': {'User-Agent': 'Mozilla/5.0'},
        'categoryListUrl': 'https://example.com/list/{page}.html',
        'categoryList': {
          'css': 'ul.book-list li',
          'name': 'a',
          'id': 'r1',
          'url': 'href',
          'pic': 'img',
        },
        'detailUrl': 'https://example.com/book/{id}.html',
        'detail': {
          'title': 'h1.book-title',
          'cover': '.book-cover img',
          'coverAttr': 'src',
          'author': '.book-author',
          'description': '.book-desc',
          'chapters': '.chapter-list a',
          'picListUrl': 'https://example.com/chapter/{id}.html',
          'picListCss': '.read-img img',
          'picAttr': 'src',
        },
      });

  Future<void> _save() async {
    final def = decodeCustomSourceDef(_controller.text);
    if (def == null) {
      setState(() => _error = 'JSON 解析失败，请检查格式');
      return;
    }
    final errs = def.validate();
    if (errs.isNotEmpty) {
      setState(() => _error = errs.join('\n'));
      return;
    }
    await CustomSourceStore.upsert(def);
    if (mounted) Navigator.pop(context, def);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(widget.def == null ? '新建自定义源' : '编辑「${widget.def!.name}」'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 11.5, color: theme.colorScheme.error),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.45),
                decoration: InputDecoration(
                  isDense: true,
                  alignLabelWithHint: true,
                  hintText: 'JSON DSL 定义，字段说明见提示',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '占位符：{id} 详情ID / {page} 页码 / {keyword} 搜索词 / {categoryId} 分类。\n'
              '抽取：css 或 regex；解密链 decrypt：b64 | aes:KEY,IV | replace:OLD>NEW | re:PATTERN|REPL。',
              style: TextStyle(fontSize: 10.5, color: theme.colorScheme.onSurface.withValues(alpha: 0.5), height: 1.4),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
