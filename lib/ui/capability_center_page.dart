import 'package:flutter/material.dart';

import '../capabilities/ai_colorize_capability.dart';
import '../capabilities/ai_frame_rife_capability.dart';
import '../capabilities/capability_plugin.dart';
import '../capabilities/capability_plugin_manager.dart';
import '../capabilities/capability_runtime.dart';
import '../capabilities/demo_native_capability.dart';
import 'capability_market_page.dart';
import 'tokens.dart';

/// 能力中心：查看/启用/禁用已安装的能力插件（内置 + 市场）。
///
/// M1 阶段仅展示内置能力（阅读统计等），市场条目（AI 上色/插帧）后续接入
/// CapabilityMarket 后在此列表上方合并展示。每个能力卡片：
/// - 启用/禁用开关（setEnabled → onEnable/onDisable + persist）
/// - 卸载按钮（仅非 builtin 显示；内置能力不可卸载）
/// - 描述 / 作者 / 版本 / 分类
class CapabilityCenterPage extends StatefulWidget {
  const CapabilityCenterPage({super.key});

  @override
  State<CapabilityCenterPage> createState() => _CapabilityCenterPageState();
}

class _CapabilityCenterPageState extends State<CapabilityCenterPage> {
  @override
  void initState() {
    super.initState();
    // 监听注册表变更（安装/卸载/启停）刷新列表。
    CapabilityPluginManager.instance.revision.addListener(_onRevision);
  }

  @override
  void dispose() {
    CapabilityPluginManager.instance.revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle(CapabilityPlugin p, bool enabled) async {
    await CapabilityPluginManager.instance.setEnabled(p.id, enabled);
  }

  /// 原生构件自测：调用演示能力 sum()，展示结果或失败原因。
  /// M2/M3 运行期验证入口（桌面 FFI / Android jniLibs 全链路）。
  Future<void> _selfTestNative() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('原生构件自测中…')));
    final r = await DemoNativePlugin.sum(40, 2);
    messenger.hideCurrentSnackBar();
    if (r is CapabilityOk) {
      final d = r.data as Map<String, dynamic>;
      messenger.showSnackBar(SnackBar(
        content: Text('自测通过：sum(40,2)=${d['sum']} · version=${d['version']}'),
      ));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text('自测失败：${(r as CapabilityFailure).reason}'),
      ));
    }
  }

  /// AI 上色模型权重：下载 + SHA256 校验 + 载入 colorizer（M4 契约 §5 过渡期）。
  Future<void> _handleModelAction() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('模型权重下载/载入中…')));
    final err = await AiColorizePlugin.ensureModel();
    messenger.hideCurrentSnackBar();
    if (err == null) {
      messenger.showSnackBar(const SnackBar(content: Text('模型已就绪')));
    } else {
      messenger.showSnackBar(SnackBar(content: Text('模型未就绪：$err')));
    }
  }

  /// AI 插帧引擎：下载引擎包（zip）+ SHA256 校验 + 解压。
  Future<void> _handleEngineAction() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('引擎下载/解压中…')));
    final err = await AiFrameRifePlugin.ensureEngine();
    messenger.hideCurrentSnackBar();
    if (err == null) {
      messenger.showSnackBar(const SnackBar(content: Text('引擎已就绪')));
    } else {
      messenger.showSnackBar(SnackBar(content: Text('引擎未就绪：$err')));
    }
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plugins = CapabilityPluginManager.instance.plugins;
    return Scaffold(
      appBar: AppBar(
        title: const Text('能力中心'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CapabilityMarketPage()),
            ),
            icon: const Icon(Icons.storefront_outlined, size: 18),
            label: const Text('能力市场'),
          ),
        ],
      ),
      body: plugins.isEmpty
          ? Center(
              child: Text(
                '暂无能力插件',
                style: TextStyle(
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(S.x16),
              itemCount: plugins.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final p = plugins[i];
                final enabled =
                    CapabilityPluginManager.instance.isEnabledSync(p.id);
                return _CapabilityCard(
                  plugin: p,
                  enabled: enabled,
                  categoryLabel: _categoryLabel(p.category),
                  onToggle: (v) => _toggle(p, v),
                  onSelfTest: p.id == 'utility.native' ? _selfTestNative : null,
                  onModelAction: p.id == 'ai.colorize.ddcolor'
                      ? _handleModelAction
                      : null,
                  onEngineAction: p.id == 'ai.frame.rife'
                      ? _handleEngineAction
                      : null,
                );
              },
            ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  final CapabilityPlugin plugin;
  final bool enabled;
  final String categoryLabel;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onSelfTest;
  final VoidCallback? onModelAction;
  final VoidCallback? onEngineAction;

  const _CapabilityCard({
    required this.plugin,
    required this.enabled,
    required this.categoryLabel,
    required this.onToggle,
    this.onSelfTest,
    this.onModelAction,
    this.onEngineAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(S.x16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(R.card),
        border: Border.all(
          color: T.color(scheme.onSurface, TextTier.hairline,
              brightness: scheme.brightness),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(R.control),
            ),
            child: Icon(
              _iconFor(plugin.category),
              size: 24,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: S.x16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        plugin.name,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      categoryLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: T.color(scheme.onSurface, TextTier.low,
                                brightness: scheme.brightness),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (plugin.description != null)
                  Text(
                    plugin.description!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                        ),
                  ),
                const SizedBox(height: 2),
                Text(
                  'v${plugin.version} · ${plugin.author}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: T.color(scheme.onSurface, TextTier.disabled,
                            brightness: scheme.brightness),
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: S.x12),
          if (onSelfTest != null)
            Padding(
              padding: const EdgeInsets.only(right: S.x8),
              child: IconButton(
                tooltip: '原生构件自测',
                icon: const Icon(Icons.play_circle_outline),
                onPressed: onSelfTest,
              ),
            ),
          if (onModelAction != null)
            Padding(
              padding: const EdgeInsets.only(right: S.x8),
              child: IconButton(
                tooltip: '下载/载入模型权重',
                icon: const Icon(Icons.download_rounded),
                onPressed: onModelAction,
              ),
            ),
          if (onEngineAction != null)
            Padding(
              padding: const EdgeInsets.only(right: S.x8),
              child: IconButton(
                tooltip: '下载插帧引擎',
                icon: const Icon(Icons.download_rounded),
                onPressed: onEngineAction,
              ),
            ),
          Switch(
            value: enabled,
            // 内置能力可禁用（与源插件先例一致：启用状态持久化），仅卸载不可。
            onChanged: onToggle,
          ),
        ],
      ),
    );
  }

  IconData _iconFor(String category) {
    switch (category) {
      case 'ai':
        return Icons.auto_awesome_outlined;
      case 'video':
        return Icons.slow_motion_video_outlined;
      case 'utility':
        return Icons.build_outlined;
      default:
        return Icons.extension_outlined;
    }
  }
}
