import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../net/local_store.dart';
import '../source_manager.dart';
import '../source_plugin.dart';
import '../source_plugin_manager.dart';
import 'custom_source_def.dart';
import 'dsl_comic_source.dart';

/// 自定义源（JSON DSL）的持久化与生命周期桥接。
///
/// - 定义存 `custom_sources`（JSON 数组），每个元素一份完整 [CustomSourceDef]，
///   可独立导入/导出。
/// - 每个自定义源在 install 时生成一个 [CustomSourcePlugin]（继承 [SourcePlugin]，
///   携带 [CustomSourceDef]），bind 时把 [DslComicSource] 注册进 [SourceManager]，
///   unbind 时移除。
/// - 启用/禁用走 [SourcePluginManager.setEnabled]（自定义源禁用状态落
///   `source_plugins` 的 disabled 列表）。
class CustomSourceStore {
  CustomSourceStore._();

  static const String _file = 'custom_sources';

  static List<CustomSourceDef>? _cache;

  static Future<List<CustomSourceDef>> all() async {
    if (_cache != null) return _cache!;
    final raw = await LocalStore.readJson(_file);
    if (raw is List) {
      _cache = raw
          .whereType<Map>()
          .map((m) => CustomSourceDef.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } else {
      _cache = [];
    }
    return _cache!;
  }

  static Future<CustomSourceDef?> byId(String id) async {
    final list = await all();
    for (final d in list) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 新增/更新一份定义并同步插件注册表。
  static Future<void> upsert(CustomSourceDef def) async {
    final list = await all();
    final idx = list.indexWhere((d) => d.id == def.id);
    if (idx >= 0) {
      list[idx] = def;
    } else {
      list.add(def);
    }
    _cache = list;
    await LocalStore.writeJson(
      _file,
      list.map((d) => d.toJson()).toList(),
    );
    // 已注册则卸载旧版（保实现与定义一致），再重装
    final pm = SourcePluginManager.instance;
    if (pm.byId(def.id) != null) {
      await pm.uninstall(def.id);
    }
    await pm.install(CustomSourcePlugin(def));
  }

  /// 删除一份自定义源（连同插件实现）。
  static Future<bool> remove(String id) async {
    final list = await all();
    final before = list.length;
    list.removeWhere((d) => d.id == id);
    if (list.length == before) return false;
    _cache = list;
    await LocalStore.writeJson(
      _file,
      list.map((d) => d.toJson()).toList(),
    );
    await SourcePluginManager.instance.uninstall(id);
    return true;
  }

  /// 导入 JSON 文本（单份或数组），逐份校验；全部成功返回导入数量。
  static Future<int> importJson(String json) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (e) {
      debugPrint('CustomSourceStore.importJson decode failed: $e');
      return 0;
    }
    final list = <Map<String, dynamic>>[];
    if (decoded is List) {
      list.addAll(decoded.whereType<Map>().map((m) => Map<String, dynamic>.from(m)));
    } else if (decoded is Map) {
      list.add(Map<String, dynamic>.from(decoded));
    } else {
      return 0;
    }
    var ok = 0;
    for (final m in list) {
      final def = CustomSourceDef.fromJson(m);
      final errs = def.validate();
      if (errs.isNotEmpty) {
        debugPrint('CustomSourceStore.importJson skip ${def.id}: $errs');
        continue;
      }
      await upsert(def);
      ok++;
    }
    return ok;
  }
  /// 导出某份定义为 JSON 文本。
  static Future<String> exportJson(String id) async {
    final list = await all();
    for (final d in list) {
      if (d.id == id) {
        return const JsonEncoder.withIndent('  ').convert(d.toJson());
      }
    }
    return '';
  }

  /// 启动恢复：注册全部已存自定义源为插件。
  static Future<void> restorePlugins() async {
    for (final d in await all()) {
      if (d.validate().isNotEmpty) continue;
      await SourcePluginManager.instance.install(CustomSourcePlugin(d));
    }
  }
}

/// 自定义源插件：元数据来自 [CustomSourceDef]；bind 把实现挂进 SourceManager。
class CustomSourcePlugin extends SourcePlugin {
  final CustomSourceDef def;

  DslComicSource? _impl;

  CustomSourcePlugin(this.def)
      : super(
          id: def.id,
          name: def.name,
          type: def.type,
          version: def.version,
          author: def.author,
          description: def.description,
        );

  @override
  Future<void> bind() async {
    _impl ??= DslComicSource(def);
    if (def.type == 'comic') {
      SourceManager.addSource(_impl!);
    }
  }

  @override
  Future<void> unbind() async {
    if (def.type == 'comic') {
      SourceManager.removeSource(def.id);
    }
    _impl = null;
  }
}