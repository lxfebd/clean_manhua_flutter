import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/comic_item.dart';
import '../sources/novel_source.dart';
import 'web_persist.dart';

/// 小说本地书架：与漫画 [BookshelfStore] 分离，独立 JSON 文件，避免与漫画条目混淆。
/// 同样按 sourceId 维度分组。
class NovelShelfStore {
  static File? _file;
  static Map<String, dynamic> _cache = {};
  static Timer? _saveTimer;
  /// 串行写盘队列：防抖触发后只允许一个 writeAsString 在途，杜绝并发写坏文件。
  static Future<void> _writeTail = Future.value();
  /// 是否已从持久层加载（web 端避免重复读 localStorage）。
  static bool _loaded = false;

  static void bindFile(File file) {
    _file = file;
    _load();
    _loaded = true;
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
      debugPrint('novel_shelf 数据损坏，已备份原文件: $e');
      try {
        f.renameSync(
            '${f.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      } catch (e2) {
        debugPrint('novel_shelf 备份失败: $e2');
      }
      _cache = {};
    }
  }

  /// 首次访问时确保已从持久层装载（web 端无 bindFile，用 localStorage）。
  static void _ensureLoaded() {
    if (_cache.isNotEmpty || _loaded) return;
    if (kIsWeb) {
      final raw = WebPersist.read('novel_shelf');
      if (raw != null) {
        try {
          _cache = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          _cache = {};
        }
      }
      _loaded = true;
    }
  }

  /// 防抖异步写盘：300ms 内多次调用合并为一次写入。
  /// 写入通过 [_writeTail] 串行排队，杜绝并发 writeAsString 交错。
  static void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      final snapshot = jsonEncode(_cache);
      if (kIsWeb) {
        WebPersist.write('novel_shelf', snapshot);
        return;
      }
      final f = _file;
      if (f == null) return;
      _writeTail = _writeTail.then((_) => _writeAsync(f, snapshot));
    });
  }

  static Future<void> _writeAsync(File f, String data) async {
    try {
      await f.writeAsString(data, flush: true);
    } catch (e) {
      debugPrint('novel_shelf 写盘失败: $e');
    }
  }

  static String _key(String sourceId, String novelId) => '$sourceId|$novelId';

  static List<Map<String, dynamic>> _all() {
    return _cache.values.cast<Map<String, dynamic>>().toList();
  }

  static void add(String sourceId, NovelDetail d) {
    _ensureLoaded();
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
    _ensureLoaded();
    _cache.remove(_key(sourceId, novelId));
    _save();
  }

  static bool contains(String sourceId, String novelId) {
    _ensureLoaded();
    return _cache.containsKey(_key(sourceId, novelId));
  }

  /// 列出某个源的书架。
  static List<NovelDetail> listBySource(String sourceId) {
    _ensureLoaded();
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
    _ensureLoaded();
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
    _ensureLoaded();
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
      sourceId: (m['sourceId'] as String?) ?? '',
    );
  }
}
