import 'package:flutter/foundation.dart';

import '../net/local_store.dart';
import 'source_config.dart';
import 'source_plugin.dart';

/// 插件管理器：统一注册表 + 生命周期编排 + 持久化（source_plugins.json）。
///
/// 职责边界：
/// - 注册/卸载/启用/禁用全部源插件（内置 + 自定义 DSL），幂等且持久化。
/// - 运行时正文（实现类实例）在 [SourcePlugin.bind]/[unbind] 回调里登记/移出
///   各自的源管理器——本类不直接依赖 SourceManager，防止双向 import。
/// - 启用状态与 `sources_config` 保持单一事实源：内置源复用 [SourceConfigStore.data]
///   （isEnabled/tier），自定义源在 `source_plugins.json` 的 `disabled` 列表记录。
///
/// 时序：main() → `_postFirstFrameInit` 里 LocalStore.init 之后调用 [restore]，
/// 先注册内置插件（幂等），再恢复 disabled 状态。
class SourcePluginManager {
  SourcePluginManager._();

  static final SourcePluginManager instance = SourcePluginManager._();

  static const String _file = 'source_plugins';

  final Map<String, SourcePlugin> _registry = {};

  /// 自定义插件禁用集合（内置源禁用走 SourceConfigStore，不落这里）。
  final Set<String> _disabledCustom = {};

  bool _restored = false;
  bool get restored => _restored;

  /// 注册表变更通知（UI 层可监听刷新）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 已注册插件列表，按类型（comic→video→novel）再按 id 排序。
  List<SourcePlugin> get plugins {
    const typeRank = {'comic': 0, 'video': 1, 'novel': 2, 'custom': 3};
    final list = _registry.values.toList()
      ..sort((a, b) {
        final ta = typeRank[a.type] ?? 9;
        final tb = typeRank[b.type] ?? 9;
        if (ta != tb) return ta.compareTo(tb);
        return a.id.compareTo(b.id);
      });
    return list;
  }

  List<SourcePlugin> pluginsOfType(String type) =>
      plugins.where((p) => p.type == type).toList();

  SourcePlugin? byId(String id) => _registry[id];

  /// 插件是否启用（同步版，供 UI 渲染）。
  bool isEnabledSync(String id) {
    final p = _registry[id];
    if (p == null) return false;
    if (p.builtin) return true; // 内置源禁用走 SourceConfigStore，UI 用异步版
    return !_disabledCustom.contains(id);
  }

  /// 插件是否启用：内置源委托 SourceConfigStore；自定义源查本地禁用集合。
  Future<bool> isEnabled(String id) async {
    final p = _registry[id];
    if (p == null) return false;
    if (p.builtin) return _builtinEnabled(id);
    return !_disabledCustom.contains(id);
  }

  Future<bool> _builtinEnabled(String engineId) async {
    try {
      final c = await SourceConfigStore.byEngine(engineId);
      return c.isEnabled && c.tier != SourceTier.disabled;
    } catch (_) {
      return true;
    }
  }

  /// 注册插件：幂等（同 id 已存在则忽略），触发 onInstall + bind。
  Future<void> install(SourcePlugin plugin) async {
    if (_registry.containsKey(plugin.id)) return;
    _registry[plugin.id] = plugin;
    try {
      await plugin.onInstall();
      await plugin.bind();
    } catch (e) {
      debugPrint('SourcePluginManager.install(${plugin.id}) failed: $e');
    }
    revision.value++;
  }

  /// 卸载插件（内置源不可卸载）：bind 收回 + onUninstall + 移出注册表。
  Future<bool> uninstall(String id) async {
    final p = _registry[id];
    if (p == null) return true;
    if (p.builtin) return false;
    _registry.remove(id);
    _disabledCustom.remove(id);
    try {
      await p.unbind();
      await p.onUninstall();
    } catch (e) {
      debugPrint('SourcePluginManager.uninstall($id) failed: $e');
    }
    await persist();
    revision.value++;
    return true;
  }

  /// 启用/禁用：内置源写入 SourceConfigStore（复用源管理页逻辑），
  /// 自定义源记录到本地禁用集合；切换触发 onEnable/onDisable。
  Future<void> setEnabled(String id, bool enabled) async {
    final p = _registry[id];
    if (p == null) return;
    if (p.builtin) {
      try {
        var c = await SourceConfigStore.byEngine(id);
        await SourceConfigStore.save(SourceConfig(
          engineId: c.engineId,
          id: c.id,
          name: c.name,
          iconUrl: c.iconUrl,
          hosts: c.hosts,
          imageHosts: c.imageHosts,
          headers: c.headers,
          requiresLogin: c.requiresLogin,
          isEnabled: enabled,
          tier: c.tier,
          proxy: c.proxy,
        ));
      } catch (_) {
        // 无既有配置：新建一条
        await SourceConfigStore.save(SourceConfig(
          engineId: id,
          id: id,
          name: p.name,
          isEnabled: enabled,
          tier: enabled ? SourceTier.fallback : SourceTier.disabled,
        ));
      }
    } else {
      if (enabled) {
        if (_disabledCustom.remove(id)) await p.onEnable();
      } else {
        if (_disabledCustom.add(id)) await p.onDisable();
      }
      await persist();
    }
    revision.value++;
  }

  /// 持久化自定义插件状态（禁用集合 + 版本）。
  Future<void> persist() async {
    await LocalStore.writeJson(
      _file,
      <String, dynamic>{
        'version': 1,
        'disabled': _disabledCustom.toList()..sort(),
      },
    );
  }

  /// 恢复上次会话：先注册全部内置插件，再恢复禁用状态。幂等。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    await _registerBuiltin();
    try {
      final raw = await LocalStore.readJson(_file);
      if (raw is Map && raw['disabled'] is List) {
        _disabledCustom
          ..clear()
          ..addAll((raw['disabled'] as List).whereType<String>());
      }
    } catch (e) {
      debugPrint('SourcePluginManager.restore disabled failed: $e');
    }
  }

  /// 内置插件：仅元数据壳（正文随版本代码发布，bind 空实现），
  /// 不落盘、不可卸载。注册闪存索引，供源管理页/健康监控统一枚举。
  Future<void> _registerBuiltin() async {
    const comics = <String, String>{
      'dm5': '动漫屋',
      'doubao': '豆包漫画',
      'jm': '禁漫天堂',
      'mangadex': 'MangaDex',
    };
    const videos = <String, String>{
      'agedm': 'AGE 动漫',
      'tvtfun': 'TvTFun',
      'xifan': '希范动漫',
      'anime1': 'Anime1',
    };
    const novels = <String, String>{
      'biquge': '笔趣阁',
      'xbiquge': '新笔趣阁',
      'local_novel': '本地小说',
    };
    var rank = 0;
    void addAll(Map<String, String> map, String type) {
      for (final e in map.entries) {
        final id = e.key;
        final name = e.value;
        rank++;
        final p = SourcePlugin(
          id: id,
          name: name,
          type: type,
          version: '1.0.0',
          author: '星漫匣内置',
          description: '随版本发布的$type源',
          builtin: true,
          rank: rank,
        );
        _registry[p.id] = p;
      }
    }

    addAll(comics, 'comic');
    addAll(videos, 'video');
    addAll(novels, 'novel');
  }
}