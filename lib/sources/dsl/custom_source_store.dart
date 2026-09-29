import 'dart:convert';

import '../../net/error_logger.dart';
import '../../net/local_store.dart';
import '../source_manager.dart';
import '../source_plugin.dart';
import '../source_plugin_manager.dart';
import 'custom_source_def.dart';
import 'dsl_comic_source.dart';
import 'dsl_novel_source.dart';
import 'dsl_video_source.dart';

/// 自定义源（JSON DSL）的持久化与生命周期桥接。
///
/// - 定义存 `custom_sources`（JSON 数组），每个元素一份完整 [CustomSourceDef]，
///   可独立导入/导出。
/// - 每个自定义源在 install 时生成一个 [CustomSourcePlugin]（继承 [SourcePlugin]，
///   携带 [CustomSourceDef]），bind 时按类型把 [DslComicSource]/[DslVideoSource]/
///   [DslNovelSource] 注册进 [SourceManager]，unbind 时移除。
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
  ///
  /// 安全时序（P0 修复）：卸载旧 → 尝试装新 → 装新失败则回滚旧实例 →
  /// 成功才落盘新版定义。旧实现「先落盘再 install」，一旦 install/bind
  /// 抛异常就形成「磁盘新版、内存旧版」永久错配。现在顺序反过来：任何
  /// 异常路径下磁盘与内存版本都一致（同为旧版或同为新版）。
  static Future<void> upsert(CustomSourceDef def) async {
    final pm = SourcePluginManager.instance;
    final oldDef = await byId(def.id);
    final hadOld = pm.byId(def.id) != null;
    // 已注册时先卸载旧插件，让 install 走新实例路径。
    if (hadOld) {
      await pm.uninstall(def.id);
    }
    // 装新：install 内部会回滚自己（bind 失败时移出注册表），这里再兜一层
    // ——install 抛异常时把旧实例装回去，保证内存与磁盘一致。
    bool newOk = false;
    try {
      await pm.install(CustomSourcePlugin(def));
      newOk = true;
    } catch (e) {
      ErrorLogger.instance.warn('CustomSourceStore.upsert(${def.id}) install failed: $e');
    }
    if (!newOk && oldDef != null) {
      // 尽力回滚旧实例到内存（磁盘已经是旧版，无需重写）
      try {
        await pm.install(CustomSourcePlugin(oldDef));
      } catch (e) {
        ErrorLogger.instance.warn('CustomSourceStore.upsert(${def.id}) rollback failed: $e');
      }
    }
    if (!newOk) return; // 保持磁盘旧版，不写盘
    // install 成功——现在把新版定义写入内存/磁盘缓存。
    // 用「先移除同 id 再追加」而不是 indexWhere：卸载旧插件后内存 list
    // 仍可能残留旧 def（uninstall 只动注册表，不动本 store 缓存），
    // 若只是原地替换，同 id 的重复项（旧 + 新）会造成下次 all() 拿到两份。
    final list = await all();
    list.removeWhere((d) => d.id == def.id);
    list.add(def);
    _cache = list;
    await LocalStore.writeJson(
      _file,
      list.map((d) => d.toJson()).toList(),
    );
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
      ErrorLogger.instance.warn('CustomSourceStore.importJson decode failed: $e');
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
        ErrorLogger.instance.warn('CustomSourceStore.importJson skip ${def.id}: $errs');
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

  /// 启动/恢复：注册全部已存自定义源为插件。
  /// [replaceExisting] 为 true 时先卸载内存中已注册的自定义插件（备份恢复等
  /// 场景：磁盘内容已被新数据替换，旧插件若残留会与新源并存或覆盖），再重建。
  static Future<void> restorePlugins({bool replaceExisting = false}) async {
    if (replaceExisting) _cache = null;
    if (replaceExisting) {
      final pm = SourcePluginManager.instance;
      for (final p in pm.plugins.toList()) {
        if (p.id.isNotEmpty && !p.builtin) {
          await pm.uninstall(p.id);
        }
      }
      // 卸载会触发 persist（写 disabled 集合），磁盘数据刚被覆盖，这里已被清。
    }
    for (final d in await all()) {
      if (d.validate().isNotEmpty) continue;
      await SourcePluginManager.instance.install(CustomSourcePlugin(d));
    }
  }
}

/// 自定义源插件：元数据来自 [CustomSourceDef]；bind 按类型把对应实现挂进 SourceManager。
class CustomSourcePlugin extends SourcePlugin {
  final CustomSourceDef def;

  DslComicSource? _comicImpl;
  DslVideoSource? _videoImpl;
  DslNovelSource? _novelImpl;

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
    switch (def.type) {
      case 'comic':
        SourceManager.addSource(_comicImpl ??= DslComicSource(def));
        break;
      case 'video':
        SourceManager.addVideoSource(_videoImpl ??= DslVideoSource(def));
        break;
      case 'novel':
        SourceManager.addNovelSource(_novelImpl ??= DslNovelSource(def));
        break;
    }
  }

  @override
  Future<void> unbind() async {
    switch (def.type) {
      case 'comic':
        SourceManager.removeSource(def.id);
        break;
      case 'video':
        SourceManager.removeVideoSource(def.id);
        break;
      case 'novel':
        SourceManager.removeNovelSource(def.id);
        break;
    }
    _comicImpl = null;
    _videoImpl = null;
    _novelImpl = null;
  }
}