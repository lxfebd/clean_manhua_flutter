import 'package:flutter/foundation.dart';

import '../net/local_store.dart';
import 'ai_colorize_capability.dart';
import 'ai_frame_rife_capability.dart';
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'demo_native_capability.dart';

/// 能力插件管理器：统一注册表 + 生命周期编排 + 持久化（capability_plugins.json）。
///
/// 与 SourcePluginManager 平行（设计 §12 架构：**不往源注册表里塞**，能力插件
/// ≠ 源插件，运行边界不同）。职责边界：
/// - 注册/卸载/启用/禁用全部能力插件（内置 + 市场安装），幂等且持久化。
/// - 运行时正文（实现类实例）在 [CapabilityPlugin.bind]/[unbind] 回调里登记/
///   移出 CapabilityRuntime——本类不直接依赖运行时内部，防双向依赖。
/// - 持久化 `capability_plugins.json`：
///   `{version:2, installed:[…], disabled:[…]}`。installed 是市场安装能力的
///   元数据快照（内置能力不落盘），disabled 是禁用集合——能力没有「配置项」
///   概念只有开关，故统一走 disabled 集合（不同于源插件委托
///   SourceConfigStore 的复杂路径）。restore 时用 installed 快照重建市场能力
///   实例，实现「安装过」跨重启保留（否则市场装完杀进程就丢，一重启又显示
///   「未安装」）。
///
/// 时序：main() → `_postFirstFrameInit` 里 LocalStore.init 之后、源插件 restore
/// 同一 try 块调用 [restore]，先注册内置能力，再恢复 disabled 状态。
class CapabilityPluginManager {
  CapabilityPluginManager._();

  static final CapabilityPluginManager instance = CapabilityPluginManager._();

  static const String _file = 'capability_plugins';

  final Map<String, CapabilityPlugin> _registry = {};

  /// 禁用集合（内置与自定义统一走这里）。
  final Set<String> _disabled = {};

  /// 市场安装的能力 id 集合（持久化；批量拆除内置能力区分 builtin 标志）。
  final Set<String> _installed = {};

  /// 被用户显式卸载的预置能力 id（AI 上色/插帧元数据壳随版本预注册，
  /// 卸载后不得在下次启动被 restore 重建；重新从市场安装则解除）。
  final Set<String> _removed = {};

  bool _restored = false;
  bool get restored => _restored;

  /// 市场安装的能力 id 列表（按持久化顺序；UI 展示「已安装来源」用）。
  List<String> get installedIds => List.unmodifiable(_installed);

  /// 注册表变更通知（UI 层可监听刷新）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 已注册能力列表，按分类（ai→video→utility）再按 id 排序。
  List<CapabilityPlugin> get plugins {
    const catRank = {'ai': 0, 'video': 1, 'utility': 2};
    final list = _registry.values.toList()
      ..sort((a, b) {
        final ta = catRank[a.category] ?? 9;
        final tb = catRank[b.category] ?? 9;
        if (ta != tb) return ta.compareTo(tb);
        return a.id.compareTo(b.id);
      });
    return list;
  }

  List<CapabilityPlugin> pluginsOfCategory(String category) =>
      plugins.where((p) => p.category == category).toList();

  CapabilityPlugin? byId(String id) => _registry[id];

  /// 能力是否启用（同步版，供 UI 渲染）。
  bool isEnabledSync(String id) {
    final p = _registry[id];
    if (p == null) return false;
    return !_disabled.contains(id);
  }

  /// 能力是否启用（异步版，与源插件签名对齐）。
  Future<bool> isEnabled(String id) async => isEnabledSync(id);

  /// 注册能力（内置/市场安装统一入口）：幂等（同 id 已存在则忽略），
  /// 触发 onInstall + bind。市场安装（非 builtin）会记录到 installed 集合
  /// 并落盘——卸载/重启后仍能恢复（见 [restore]）。重新从市场安装时
  /// 解除「已卸载」标记。
  Future<void> install(CapabilityPlugin plugin) async {
    if (_registry.containsKey(plugin.id)) return;
    _registry[plugin.id] = plugin;
    if (!plugin.builtin) {
      _installed.add(plugin.id);
      _removed.remove(plugin.id);
    }
    try {
      await plugin.onInstall();
      await plugin.bind();
    } catch (e) {
      debugPrint('CapabilityPluginManager.install(${plugin.id}) failed: $e');
    }
    await persist();
    revision.value++;
  }

  /// 卸载能力（内置能力不可卸载）：bind 收回 + onUninstall + 本地构件
  /// （artifact/权重）清理 + 移出注册表。预置能力（AI 上色/插帧壳）卸载
  /// 后记入 _removed，防止 restore 下次启动重建。
  Future<bool> uninstall(String id) async {
    final p = _registry[id];
    if (p == null) return true;
    if (p.builtin) return false;
    _registry.remove(id);
    _disabled.remove(id);
    _installed.remove(id);
    _removed.add(id);
    try {
      await p.unbind();
      await p.onUninstall();
      // 卸载即清理本地构件（artifact / 权重），避免「卸载了还占几十~数百 MB」。
      await CapabilityArtifactStore.instance.purge(id);
    } catch (e) {
      debugPrint('CapabilityPluginManager.uninstall($id) failed: $e');
    }
    await persist();
    revision.value++;
    return true;
  }

  /// 启用/禁用：切换触发 onEnable/onDisable，状态落本地禁用集合。
  Future<void> setEnabled(String id, bool enabled) async {
    final p = _registry[id];
    if (p == null) return;
    if (enabled) {
      if (_disabled.remove(id)) await p.onEnable();
    } else {
      if (_disabled.add(id)) await p.onDisable();
    }
    await persist();
    revision.value++;
  }

  /// 持久化能力状态：已安装能力元数据快照（非 builtin）+ 禁用集合 + 版本。
  Future<void> persist() async {
    final snap = _snapshot();
    await LocalStore.writeJson(
      _file,
      <String, dynamic>{
        'version': 2,
        'installed': snap.map((p) => p.toJson()).toList(),
        'disabled': _disabled.toList()..sort(),
        'removed': _removed.toList()..sort(),
      },
    );
  }

  /// 当前已安装市场能力的元数据快照（内置能力不落盘）。
  List<CapabilityPlugin> _snapshot() =>
      _installed.map((id) => _registry[id]).whereType<CapabilityPlugin>().toList();

  /// 恢复上次会话：先注册全部内置能力，再重建市场安装能力（installed
  /// 快照）与禁用状态。幂等。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    await _registerBuiltin();
    // AI 上色/插帧的元数据壳随版本预注册（不经 install、不落盘、不进
    // installed）：保证能力中心能看到、id 稳定，用户从市场安装/更新后才
    // 持久化。用户已显式卸载的（_removed）不重建。
    if (!_removed.contains(AiColorizePlugin().id)) {
      _registry[AiColorizePlugin().id] = AiColorizePlugin();
    }
    if (!_removed.contains(AiFrameRifePlugin().id)) {
      _registry[AiFrameRifePlugin().id] = AiFrameRifePlugin();
    }
    try {
      final raw = await LocalStore.readJson(_file);
      if (raw is Map) {
        // v2：installed 快照重建（先于 disabled 应用，快照只含市场能力）。
        final inst = raw['installed'];
        if (inst is List) {
          for (final item in inst) {
            if (item is! Map) continue;
            try {
              final p = CapabilityPlugin.fromJson(Map<String, dynamic>.from(item));
              if (p != null && !p.builtin && !_registry.containsKey(p.id)) {
                _installed.add(p.id);
                _removed.remove(p.id);
                _registry[p.id] = p;
                // 静默 bind：重建失败不阻断启动（实现正文恢复不了等重启
                // 或重新安装，能力中心照常列出）。
                try {
                  await p.bind();
                } catch (e) {
                  debugPrint('CapabilityPluginManager restore bind(${p.id}) failed: $e');
                }
              }
            } catch (e) {
              debugPrint('CapabilityPluginManager restore item failed: $e');
            }
          }
        }
        // v1/v2 兼容：disabled 集合（旧文件只有 disabled，新文件两者都有）。
        final dis = raw['disabled'];
        if (dis is List) {
          _disabled
            ..clear()
            ..addAll(dis.whereType<String>());
        }
        final rem = raw['removed'];
        if (rem is List) {
          _removed.addAll(rem.whereType<String>());
        }
      }
    } catch (e) {
      debugPrint('CapabilityPluginManager.restore disabled failed: $e');
    }
  }

  /// 内置能力：仅元数据壳（正文随版本代码发布，bind 空实现），
  /// 不落盘、不可卸载。注册闪存索引，供能力中心 UI 统一枚举。
  Future<void> _registerBuiltin() async {
    void add(CapabilityPlugin p) {
      _registry[p.id] = p;
    }

    // 内置能力（纯 Dart 壳，无原生依赖）。
    // 注：AI 上色/插帧等原生能力由独立 agent 专项（红线 M4 前不碰 colorizer），
    // 上线后作为市场能力而非内置注册。
    add(const CapabilityPlugin(
      id: 'utility.stats',
      name: '阅读统计',
      category: 'utility',
      version: '1.0.0',
      author: '星漫匣内置',
      description: '本地阅读统计（纯本地计算，不上传）',
      builtin: true,
    ));
    // M2 演示原生能力：FFI 加载真实动态库（走 artifact 下载→SHA256→Isolate）。
    add(DemoNativePlugin());
  }
}
