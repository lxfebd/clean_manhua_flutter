import 'package:flutter/foundation.dart';

import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../utils/colorizer_manager.dart';
import 'ai_colorize_capability.dart';
import 'ai_frame_rife_capability.dart';
import 'builtin_capabilities.dart';
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

  /// 预置能力壳（随版本发布的实现类，如 AI 上色/插帧）：平台支持判定与
  /// 版本语义的事实源。restore 只在平台支持时把它们注册进 _registry；
  /// 市场条目安装前也查这里（远端条目不携带平台声明）。
  static final Map<String, CapabilityPlugin> _presetShells = () {
    final c = AiColorizePlugin();
    final r = AiFrameRifePlugin();
    return <String, CapabilityPlugin>{c.id: c, r.id: r};
  }();

  /// 当前平台是否支持指定能力：注册实例优先，未注册查预置壳
  /// （平台不支持时壳不注册），都无则默认支持（纯 Dart/全平台能力）。
  bool isSupportedOnCurrentPlatform(String id) =>
      (_registry[id] ?? _presetShells[id])?.isSupportedOnCurrentPlatform ??
      true;

  /// 注册能力（内置/市场安装统一入口）：幂等（同 id 已存在则忽略），
  /// 触发 onInstall + bind。市场安装（非 builtin）会记录到 installed 集合
  /// 并落盘——卸载/重启后仍能恢复（见 [restore]）。重新从市场安装时
  /// 解除「已卸载」标记。
  Future<void> install(CapabilityPlugin plugin) async {
    if (_registry.containsKey(plugin.id)) return;
    // 平台门闸：当前平台不支持的能力不注册（能力中心/市场不可见的最后防线；
    // 内置/市场全平台能力默认 supported=true 不受影响）。
    if (!plugin.isSupportedOnCurrentPlatform) return;
    _registry[plugin.id] = plugin;
    if (!plugin.builtin) {
      _installed.add(plugin.id);
      _removed.remove(plugin.id);
    }
    try {
      await plugin.onInstall();
      await plugin.bind();
    } catch (e) {
      ErrorLogger.instance.warn(
          'CapabilityPluginManager.install(${plugin.id}) failed: $e');
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
    } catch (e) {
      ErrorLogger.instance.warn(
          'CapabilityPluginManager.uninstall($id) hooks failed: $e');
    }
    // 构件清理放在独立 try（不能与 unbind/onUninstall 同一个 try）：
    // 钩子抛异常时仍要清 artifact/权重，否则「卸载了还占几十~数百 MB」，
    // 且注册表已移除、下次 restore 不会重建，构件永久孤儿化。
    try {
      await CapabilityArtifactStore.instance.purge(id);
      // AI 上色额外联动：能力卸载时同步清理 colorizer 私有模型目录
      // （`colorizer/model.tflite`）并释放后端，避免「卸载了但功能仍可用」——
      // 只清 `.model_cache/<id>/` 会让 `ColorizerManager.isAvailable` 保持
      // true，reader 侧仍显示上色入口。按 id 判断，不引入与 colorizer 的
      // 双向依赖（colorizer_manager 已 import 到本文件；反向不 import）。
      if (id == AiColorizePlugin().id) {
        await ColorizerManager.instance.deleteModelFile();
      }
    } catch (e) {
      ErrorLogger.instance.warn(
          'CapabilityPluginManager.uninstall($id) purge failed: $e');
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
    await registerBuiltinCapabilities();
    // AI 上色/插帧的元数据壳随版本预注册（不经 install、不落盘、不进
    // installed）：保证能力中心能看到、id 稳定，用户从市场安装/更新后才
    // 持久化。用户已显式卸载的（_removed）不重建。当前平台不支持的
    // （isSupportedOnCurrentPlatform 门闸，如插帧仅 Windows）不注册——
    // 手机/Web 能力中心不显示，也不可被卸载记入 removed（那会静默删掉
    // 桌面端壳）。
    if (!_removed.contains(AiColorizePlugin().id) &&
        AiColorizePlugin().isSupportedOnCurrentPlatform) {
      _registry[AiColorizePlugin().id] = AiColorizePlugin();
    }
    // AI 插帧：RIFE 引擎恢复为可注册能力（2026-09-18 由「mpv interpolation
    // 显示同步」错误路线改回独立引擎插件——mpv 那条会按显示时钟变速，见
    // native_player_page._applySync 注释）。用户已显式卸载的不重建。
    if (!_removed.contains(AiFrameRifePlugin().id) &&
        AiFrameRifePlugin().isSupportedOnCurrentPlatform) {
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
              // 平台门闸：快照可能来自旧版本（桌面卸载过/手机装过），当前
              // 平台不支持则不恢复注册（也不记 installed，市场重新显示可安装）。
              if (p != null && !p.builtin && !_registry.containsKey(p.id) &&
                  p.isSupportedOnCurrentPlatform) {
                _installed.add(p.id);
                _removed.remove(p.id);
                _registry[p.id] = p;
                // 静默 bind：重建失败不阻断启动（实现正文恢复不了等重启
                // 或重新安装，能力中心照常列出）。
                try {
                  await p.bind();
                } catch (e) {
                  ErrorLogger.instance.warn(
                      'CapabilityPluginManager restore bind(${p.id}) failed: $e');
                }
              }
            } catch (e) {
              ErrorLogger.instance
                  .warn('CapabilityPluginManager restore item failed: $e');
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
      ErrorLogger.instance.warn('CapabilityPluginManager.restore disabled failed: $e');
    }
  }

  /// 内置能力：仅元数据壳（正文随版本代码发布，bind 空实现），
  /// 不落盘、不可卸载。注册闪存索引，供能力中心 UI 统一枚举。幂等。
  ///
  /// 平台门闸：与 install/restore 路径对齐——`isSupportedOnCurrentPlatform`
  /// 为 false 的内置能力不注册（如未来某内置能力仅桌面可用，Web/手机侧
  /// 能力中心不应展示）。全平台能力默认 true 不受影响（`utility.stats`）。
  /// 单一事实源：utility.stats 的正文本体在 [ChapterStatsPlugin]，仅此处注册。
  Future<void> registerBuiltinCapabilities() async {
    void add(CapabilityPlugin p) {
      // 平台门闸：与 install()/restore() 一致，避免「市场安装路径查门闸，
      // 但内置注册路径不查」导致同一条能力在不同平台显示不一致。
      if (!p.isSupportedOnCurrentPlatform) return;
      _registry[p.id] = p;
    }

    // 内置能力（纯 Dart 壳，无原生依赖）：正文由 [ChapterStatsPlugin] 提供，
    // 注册单一事实源在 `builtin_capabilities.dart`，仅此一处不被其它入口重复建。
    // 注：AI 上色/插帧等原生能力由独立 agent 专项（红线 M4 前不碰 colorizer），
    // 上线后作为市场能力而非内置注册。
    add(ChapterStatsPlugin());
    // M2 演示原生能力：FFI 加载真实动态库（走 artifact 下载→SHA256→Isolate）。
    add(DemoNativePlugin());
  }
}
