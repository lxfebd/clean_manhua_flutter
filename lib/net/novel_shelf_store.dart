import 'dart:convert';
import 'dart:io';

import '../models/comic_item.dart';
import '../sources/novel_source.dart';

/// 小说本地书架：与漫画 [BookshelfStore] 分离，独立 JSON 文件，避免与漫画条目混淆。
/// 同样按 sourceId 维度分组。
class NovelShelfStore {
  static File? _file;
  static Map<String, dynamic> _cache = {};

  static void bindFile(File file) {
    _file = file;
    _load();
  }

  static void _load() {
    final f = _file;
    if (f == null || !f.existsSync()) {
      _cache = {};
      return;
    }
    try {
      _cache = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      _cache = {};
    }
  }

  static void _save() {
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync(jsonEncode(_cache));
    } catch (_) {}
  }

  static String _key(String sourceId, String novelId) => '$sourceId|$novelId';

  static List<Map<String, dynamic>> _all() {
    return _cache.values.cast<Map<String, dynamic>>().toList();
  }

  static void add(String sourceId, NovelDetail d) {
    final k = _key(sourceId, d.id);
    _cache[k] = {
      'sourceId': sourceId,
      'id': d.id,
      'name': d.name,
      'pic': d.pic ?? '',
      'author': d.author ?? d.comic.author ?? '',
      'description': d.description ?? '',
      'chapters': d.chapters
          .map((c) => {'id': c.id, 'title': c.title, 'index': c.index})
          .toList(),
      'addedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _save();
  }

  static void remove(String sourceId, String novelId) {
    _cache.remove(_key(sourceId, novelId));
    _save();
  }

  static bool contains(String sourceId, String novelId) =>
      _cache.containsKey(_key(sourceId, novelId));

  /// 列出某个源的书架。
  static List<NovelDetail> listBySource(String sourceId) {
    return _all()
        .where((m) => m['sourceId'] == sourceId)
        .map(_fromMap)
        .toList()
      ..sort((a, b) {
        final ma = _readAddedAt(a, defaultSourceId: sourceId);
        final mb = _readAddedAt(b, defaultSourceId: sourceId);
        return mb.compareTo(ma);
      });
  }

  /// 列出全部书架（用于统一书架视图）。
  static List<NovelDetail> listAll() {
    return _all().map(_fromMap).toList()
      ..sort((a, b) {
        final ma = _readAddedAt(a);
        final mb = _readAddedAt(b);
        return mb.compareTo(ma);
      });
  }

  static int _readAddedAt(NovelDetail d, {String? defaultSourceId}) {
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

  static NovelDetail _fromMap(Map<String, dynamic> m) {
    final comic = ComicItem(m['id'] as String, m['name'] as String,
            (m['pic'] as String?) ?? '')
        ..author = (m['author'] as String?) ?? '';
    final chapters = ((m['chapters'] as List?) ?? [])
        .map((e) => NovelChapter(
            (e as Map<String, dynamic>)['id'] as String,
            (e['title'] as String?) ?? '',
            index: (e['index'] as int?) ?? 0))
        .toList();
    return NovelDetail(
      comic,
      chapters,
      author: (m['author'] as String?) ?? '',
      description: (m['description'] as String?) ?? '',
    );
  }
}
