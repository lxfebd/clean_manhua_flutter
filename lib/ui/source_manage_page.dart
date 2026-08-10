import 'package:flutter/material.dart';

import '../sources/source_config.dart';
import '../sources/source_manager.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.arrow_back_ios_new_rounded,
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
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
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
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 110),
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
