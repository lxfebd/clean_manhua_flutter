import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/debounced_writer.dart';
import '../utils/file_backup.dart';
import 'error_logger.dart';
import 'web_persist.dart';

/// 通用本地书架存储：漫画（bookshelf.json）与小说（novel_shelf.json）共用一套
/// 条目级存储机制——按 `sourceId|id` 键分组的 JSON Map、防抖串行写盘、
/// 损坏文件备份恢复、web/io 双端装载。
///
/// 两类的差异（条目序列化、id 提取、sourceId 提取）通过 [fromMap]/[idOf]/
/// [sourceIdOf] 三个钩子注入，子类（BookshelfStore / NovelShelfStore）只保留
/// 各自领域语义（漫画分类、小说条目），存储机制不再重复。
///
/// 排序契约：条目写入时带 addedAt，[listBySource]/[listAll] 统一按 addedAt
/// 降序返回（rawAll 已排好序，listBySource 不再用 O(n) 扫描比较器）。
class ShelfStore<T> {
  ShelfStore({
    required this.webKey,
    required this.fileName,
    required this.debugName,
    required this.fromMap,
    required this.idOf,
    required this.sourceIdOf,
  });

  final String webKey;
  final String fileName;
  final String debugName;

  /// 原始 Map → 强类型条目（子类序列化差异）。
  final T Function(Map<String, dynamic> map) fromMap;

  /// 条目 id 提取（字段读取，用于 key 拼接与 addedAt 查询）。
  final String Function(T entry) idOf;

  /// 条目所属源 id 提取（条目自带 sourceId；用于 addedAt 查询）。
  final String Function(T entry) sourceIdOf;

  File? _file;
  Map<String, dynamic> _cache = {};
  /// 是否已从持久层加载（web 端避免重复读 localStorage）。
  bool _loaded = false;
  /// 防抖串行写盘（300ms 合并 + 单写盘在途）。
  late final DebouncedSerialWriter _writer =
      DebouncedSerialWriter(debugName: debugName);

  /// 注入写盘失败 UI 钩子（main 启动时接线，勿在构造期依赖 UI 层）。
  void setWriteErrorHandler(void Function(Object error, StackTrace stack) cb) =>
      _writer.onWriteError = cb;

  void bindFile(File file) {
    _file = file;
    _load();
    _loaded = true;
  }

  void _load() {
    final f = _file;
    if (f == null || !f.existsSync()) {
      _cache = {};
      return;
    }
    try {
      _cache = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (e) {
      ErrorLogger.instance.warn('$fileName 数据损坏，已备份原文件: $e');
      if (!f.backupCorrupt()) {
        ErrorLogger.instance.warn('$fileName 备份失败: $e');
      }
      _cache = {};
    }
  }

  /// 首次访问时确保已从持久层装载（web 端无 bindFile，用 localStorage）。
  bool _ensureLoaded() {
    if (_cache.isNotEmpty || _loaded) return true;
    if (kIsWeb) {
      final raw = WebPersist.read(webKey);
      if (raw != null) {
        try {
          _cache = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          _cache = {};
        }
      } else {
        _cache = {};
      }
      _loaded = true;
      return true;
    }
    return false;
  }

  /// 防抖异步写盘：300ms 内多次调用合并为一次写入。
  void _save() {
    _writer.schedule(() async {
      final snapshot = jsonEncode(_cache);
      if (kIsWeb) {
        WebPersist.write(webKey, snapshot);
        return;
      }
      final f = _file;
      if (f == null) return;
      await f.writeAsString(snapshot, flush: true);
    });
  }

  /// 立即触发一次写盘（供子类直接修改共享 Map 后落盘）。
  void persist() => _save();

  static String _key(String sourceId, String id) => '$sourceId|$id';

  List<Map<String, dynamic>> _all() =>
      _cache.values.cast<Map<String, dynamic>>().toList();

  void add(String sourceId, String id, Map<String, dynamic> entry) {
    _ensureLoaded();
    _cache[_key(sourceId, id)] = entry;
    _save();
  }

  void remove(String sourceId, String id) {
    _ensureLoaded();
    _cache.remove(_key(sourceId, id));
    _save();
  }

  bool contains(String sourceId, String id) {
    _ensureLoaded();
    return _cache.containsKey(_key(sourceId, id));
  }

  /// 列出某个源的书架条目（原始 Map，子类负责转强类型）。
  List<Map<String, dynamic>> rawBySource(String sourceId) {
    _ensureLoaded();
    return _all().where((m) => m['sourceId'] == sourceId).toList();
  }

  /// 列出全部条目（原始 Map，子类负责转强类型），按 addedAt 降序。
  List<Map<String, dynamic>> rawAll() {
    _ensureLoaded();
    final list = _all()
      ..sort((a, b) =>
          ((b['addedAt'] as int?) ?? 0).compareTo((a['addedAt'] as int?) ?? 0));
    return list;
  }

  /// 列出某个源的书架（强类型），按 addedAt 降序。
  ///
  /// 排序直接用 [rawBySource] 的 addedAt 字段一次比较，不进入 O(n) 扫描比较器。
  List<T> listBySource(String sourceId) {
    _ensureLoaded();
    final list = rawBySource(sourceId)
        .map(fromMap)
        .toList()
      ..sort((a, b) => addedAtOf(b).compareTo(addedAtOf(a)));
    return list;
  }

  /// 列出全部书架（强类型），按 addedAt 降序（rawAll 已排好序）。
  List<T> listAll() {
    _ensureLoaded();
    return rawAll().map(fromMap).toList();
  }

  /// 读取某条目的字段值（无则返回 null）。
  dynamic field(String sourceId, String id, String field) {
    _ensureLoaded();
    return _cache[_key(sourceId, id)]?[field];
  }

  /// 写入某条目字段并落盘；条目不存在则忽略。
  void setField(String sourceId, String id, String field, dynamic value) {
    _ensureLoaded();
    final m = _cache[_key(sourceId, id)];
    if (m == null) return;
    m[field] = value;
    _save();
  }

  /// 导出原始数据（用于备份）。
  Map<String, dynamic> exportData() => Map.from(_cache);

  /// 覆盖导入（用于恢复备份）。
  void importData(Map<String, dynamic> data) {
    _ensureLoaded();
    _cache = Map.from(data);
    _save();
  }

  /// 上次检查更新时记录的章节数（-1 = 尚未检查过，不报更新）。
  int lastSeenChapters(String sourceId, String id) =>
      (_cache[_key(sourceId, id)]?['lastChapters'] as int?) ?? -1;

  /// 写入上次检查到的章节数。
  void setLastSeenChapters(String sourceId, String id, int count) {
    final m = _cache[_key(sourceId, id)];
    if (m == null) return;
    m['lastChapters'] = count;
    _save();
  }

  /// 是否有更新：当前章节数 > 上次记录。
  bool hasUpdate(String sourceId, String id, int currentChapters) {
    final last = lastSeenChapters(sourceId, id);
    if (last < 0) return false;
    return currentChapters > last;
  }

  /// 新增章节数（current - last）。
  int newChapterCount(String sourceId, String id, int currentChapters) {
    final last = lastSeenChapters(sourceId, id);
    if (last < 0) return 0;
    final diff = currentChapters - last;
    return diff > 0 ? diff : 0;
  }

  /// 读取某条目的收藏时间（addedAt），无记录返回 0。
  ///
  /// 直接按条目 id+sourceId 查字段，不扫描全表（原 _readAddedAt 在排序
  /// 比较器里 O(n) 扫描 = O(n² log n)，这里 O(1)）。
  int addedAtOf(T entry) =>
      (_cache[_key(sourceIdOf(entry), idOf(entry))]?['addedAt'] as int?) ?? 0;
}
