import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';

/// 通用本地书架：所有漫画源统一保存在一个 JSON 文件中，
/// 按 sourceId 维度分组，避免每个源各自实现。
class BookshelfStore {
  static File? _file;
  static Map<String, dynamic> _cache = {};
  static Timer? _saveTimer;
  static Map<String, String> _idIndex = {};

  static void bindFile(File file) {
    _file = file;
    _load();
    _rebuildIndex();
  }

  static void _load() {
    final f = _file;
    if (f == null || !f.existsSync()) {
      _cache = {};
      return;
    }
    try {
      _cache = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (e) {
      // 数据损坏（写入中断/磁盘错误）：备份损坏文件再从空开始，
      // 避免静默清空导致用户书架"凭空消失"且无法追溯。
      debugPrint('bookshelf 数据损坏，已备份原文件: $e');
      try {
        f.renameSync(
            '${f.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      } catch (e2) {
        debugPrint('bookshelf 备份失败: $e2');
      }
      _cache = {};
    }
  }

  static void _rebuildIndex() {
    _idIndex = {};
    for (final m in _cache.values) {
      if (m is Map<String, dynamic>) {
        final id = m['id'];
        final sid = m['sourceId'];
        if (id is String && sid is String) _idIndex[id] = sid;
      }
    }
  }

  /// 防抖异步写盘：300ms 内多次调用合并为一次写入。
  static void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      final f = _file;
      if (f == null) return;
      final snapshot = jsonEncode(_cache);
      _writeAsync(f, snapshot);
    });
  }

  static Future<void> _writeAsync(File f, String data) async {
    try {
      await f.writeAsString(data, flush: true);
    } catch (e) {
      // 写盘失败（磁盘满/权限）需可观测，否则内存已更新但磁盘没落盘，下次启动丢失
      debugPrint('bookshelf 写盘失败: $e');
    }
  }

  static String _key(String sourceId, String comicId) => '$sourceId|$comicId';

  static List<Map<String, dynamic>> _all() {
    return _cache.values.cast<Map<String, dynamic>>().toList();
  }

  static void add(String sourceId, ComicDetail d) {
    final k = _key(sourceId, d.id);
    _cache[k] = {
      'sourceId': sourceId,
      'id': d.id,
      'name': d.name,
      'pic': d.pic ?? '',
      'author': d.author ?? d.comic.author ?? '',
      'description': d.description ?? '',
      'chapters': d.chapters
          .map((c) => {'id': c.id, 'title': c.title})
          .toList(),
      'addedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _idIndex[d.id] = sourceId;
    _save();
  }

  static void remove(String sourceId, String comicId) {
    _cache.remove(_key(sourceId, comicId));
    _idIndex.remove(comicId);
    _save();
  }

  static bool contains(String sourceId, String comicId) =>
      _cache.containsKey(_key(sourceId, comicId));

  /// 根据 comicId 反查所属 sourceId（书架统一视图中使用）。
  static String? sourceIdOf(String comicId) => _idIndex[comicId];

  /// 列出某个源的书架。
  static List<ComicDetail> listBySource(String sourceId) {
    return _all()
        .where((m) => m['sourceId'] == sourceId)
        .map((m) => _fromMap(m))
        .toList()
      ..sort((a, b) {
        final ma = _readAddedAt(a, defaultSourceId: sourceId);
        final mb = _readAddedAt(b, defaultSourceId: sourceId);
        return mb.compareTo(ma);
      });
  }

  /// 列出全部书架（用于统一书架视图）。
  static List<ComicDetail> listAll() {
    return _all().map(_fromMap).toList()
      ..sort((a, b) {
        final ma = _readAddedAt(a);
        final mb = _readAddedAt(b);
        return mb.compareTo(ma);
      });
  }

  static int _readAddedAt(ComicDetail d, {String? defaultSourceId}) {
    final sid = defaultSourceId ?? (_cache.values
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (m) => m['id'] == d.id,
          orElse: () => {'addedAt': 0},
    ))['sourceId'] as String? ?? '';
    final v = _cache[_key(sid, d.id)]?['addedAt'];
    return (v as int?) ?? 0;
  }

  /// 导出原始数据（用于备份）。
  static Map<String, dynamic> exportData() => Map.from(_cache);

  /// 覆盖导入（用于恢复备份）。
  static void importData(Map<String, dynamic> data) {
    _cache = Map.from(data);
    _save();
  }

  /// 预设标签。
  static const presetTags = ['日漫', '国漫', '韩漫', '热血', '恋爱', '奇幻', '悬疑', '完结'];

  /// 读取某本书的书架标签。
  static List<String> tagsOf(String sourceId, String comicId) {
    final v = _cache[_key(sourceId, comicId)]?['tags'];
    if (v is List) return v.cast<String>().toList();
    return const [];
  }

  /// 写入某本书的书架标签（去重保序）。
  static void setTags(String sourceId, String comicId, List<String> tags) {
    final k = _key(sourceId, comicId);
    final m = _cache[k];
    if (m == null) return;
    m['tags'] = tags.toSet().toList();
    _save();
  }

  /// 当前书架使用过的全部标签（含预设，按使用频率降序）。
  static List<String> allTags() {
    final count = <String, int>{};
    for (final m in _all()) {
      final tags = (m['tags'] as List?)?.cast<String>() ?? const <String>[];
      for (final t in tags) {
        count[t] = (count[t] ?? 0) + 1;
      }
    }
    final sorted = count.keys.toList()
      ..sort((a, b) => (count[b] ?? 0).compareTo(count[a] ?? 0));
    final used = sorted.toSet();
    return [...presetTags.where((t) => !used.contains(t)), ...sorted];
  }

  /// 上次检查更新时记录的章节数（用于判断是否有新章节）。
  /// 存储结构：shelf_update -> { "src|cid": 173, ... }。
  static int lastSeenChapters(String sourceId, String comicId) =>
      (_cache[_key(sourceId, comicId)]?['lastChapters'] as int?) ?? -1;

  /// 写入上次检查到的章节数。
  static void setLastSeenChapters(
      String sourceId, String comicId, int count) {
    final k = _key(sourceId, comicId);
    final m = _cache[k];
    if (m == null) return;
    m['lastChapters'] = count;
    _save();
  }

  /// 判断某本书是否有更新：当前章节数 > 上次记录。
  static bool hasUpdate(String sourceId, String comicId, int currentChapters) {
    final last = lastSeenChapters(sourceId, comicId);
    if (last < 0) return false;
    return currentChapters > last;
  }

  /// 新增章节数（current - last）。
  static int newChapterCount(
      String sourceId, String comicId, int currentChapters) {
    final last = lastSeenChapters(sourceId, comicId);
    if (last < 0) return 0;
    final diff = currentChapters - last;
    return diff > 0 ? diff : 0;
  }

  static ComicDetail _fromMap(Map<String, dynamic> m) {
    final comic = ComicItem(m['id'] as String, m['name'] as String,
            (m['pic'] as String?) ?? '')
        ..author = (m['author'] as String?) ?? '';
    final chapters = ((m['chapters'] as List?) ?? [])
        .map((e) => Chapter(
            (e as Map<String, dynamic>)['id'] as String, (e['title'] as String?) ?? ''))
        .toList();
    return ComicDetail(
      comic,
      chapters,
      author: (m['author'] as String?) ?? '',
      description: (m['description'] as String?) ?? '',
    );
  }
}
