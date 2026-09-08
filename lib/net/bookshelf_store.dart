import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import 'local_store.dart';

/// 通用本地书架：所有漫画源统一保存在一个 JSON 文件中，
/// 按 sourceId 维度分组，避免每个源各自实现。
class BookshelfStore {
  static File? _file;
  static Map<String, dynamic> _cache = {};
  static Timer? _saveTimer;
  static Map<String, String> _idIndex = {};
  /// 串行写盘队列：防抖触发后只允许一个 writeAsString 在途，
  /// 连点收藏/移出时不会并发写坏文件。
  static Future<void> _writeTail = Future.value();

  // ---- 书架分类（文件夹） ----
  /// 分类存储文件名（独立于 bookshelf.json：书籍是条目级数据，
  /// 分类是集合级定义，混在一起会让导出备份把分类定义也按条目拷一份）。
  static const String _foldersFileName = 'shelf_folders';

  /// 分类 id 保留值：代表「全部」视图（不是真实分类，UI 过滤用）。
  static const String allFolderId = 'all';

  /// 旧数据兜底分类 id：书架里没有 folderId 的书籍归入它。
  static const String defaultFolderId = 'default';

  /// 分类显示名（id → name）。
  static Map<String, String> _folderNames = {};

  /// 分类排序（id → sort）。
  static Map<String, int> _folderSort = {};

  /// 内存缓存中是否已有分类数据（避免异步读取竞态）。
  static bool _foldersLoaded = false;

  /// 分类变更版本号（书架页 reload 用，避免每次变更后手动记。
  /// 本质是「书架数据变了」的信号，供书架页在变更后主动刷新）。
  static final ValueNotifier<int> foldersVersion = ValueNotifier(0);

  /// 读取书架分类（同步返回内存缓存；首次调用先异步装载）。
  /// 返回结构：`[{id, name, sort}]`。列表以内存合成的「全部」视图开头
  /// （id = [allFolderId]，不落盘），其后是「默认分类」+ 自建分类，按 sort 升序。
  static Future<List<Map<String, dynamic>>> folders() async {
    await _ensureFoldersLoaded();
    final list = _folderSort.keys
        .map((id) => {'id': id, 'name': _folderNames[id] ?? id, 'sort': _folderSort[id] ?? 0})
        .toList()
      ..sort((a, b) {
        // 「默认分类」恒排真实分类最前，其余按创建顺序（sort）升序。
        final aw = a['id'] == defaultFolderId ? 0 : (a['sort'] as int) + 1;
        final bw = b['id'] == defaultFolderId ? 0 : (b['sort'] as int) + 1;
        return aw.compareTo(bw);
      });
    return [
      {'id': allFolderId, 'name': '全部', 'sort': -1},
      ...list,
    ];
  }

  /// 读取全部用户自建分类（不含「全部」视图与「默认分类」——两者内置不可删）。
  static Future<List<Map<String, dynamic>>> userFolders() async {
    final all = await folders();
    return all
        .where((f) =>
            f['id'] != allFolderId && f['id'] != defaultFolderId)
        .toList();
  }

  static Future<void> _ensureFoldersLoaded() async {
    if (_foldersLoaded) return;
    _foldersLoaded = true;
    try {
      final raw = await LocalStore.readJson(_foldersFileName);
      final list = (raw is List) ? raw.whereType<Map>().toList() : <Map>[];
      final names = <String, String>{};
      final sort = <String, int>{};
      for (final m in list) {
        final id = m['id'];
        if (id is! String || id.isEmpty || id == allFolderId) continue;
        names[id] = (m['name'] as String?)?.trim() ?? id;
        sort[id] = (m['sort'] as int?) ?? 0;
      }
      _folderNames = names;
      _folderSort = sort;
    } catch (e) {
      debugPrint('shelf_folders 解析失败（数据可能已损坏）: $e');
      _folderNames = {};
      _folderSort = {};
    }
    _ensureDefaultFolder();
  }

  /// 确保「默认分类」存在（幂等；仅在内存合成，「默认分类」不落盘——
  /// 它是旧数据无 folderId 时的兜底概念，[folders] 每次读取时自动补上）。
  static void _ensureDefaultFolder() {
    if (!_folderSort.containsKey(defaultFolderId)) {
      _folderNames[defaultFolderId] = '默认分类';
      _folderSort[defaultFolderId] = 0;
    }
  }

  /// 持久化分类定义：只写用户自建分类（「默认分类」由 [folders] 内存合成）。
  static Future<void> _persistFolders() async {
    final list = _folderSort.keys
        .where((id) => id != defaultFolderId)
        .map((id) =>
            {'id': id, 'name': _folderNames[id] ?? id, 'sort': _folderSort[id] ?? 0})
        .toList();
    await LocalStore.writeJson(_foldersFileName, list);
  }

  /// 创建分类；重名时在名字后加序号避免歧义（用户可见，不静默去重）。
  static Future<void> addFolder(String name) async {
    await _ensureFoldersLoaded();
    final t = name.trim();
    if (t.isEmpty || t == allFolderId) return;
    _ensureDefaultFolder();
    final exists = _folderNames.values.any((n) => n == t);
    final finalName = exists ? '$t ${_folderSort.length}' : t;
    final id = 'f${DateTime.now().millisecondsSinceEpoch}';
    _folderNames[id] = finalName;
    _folderSort[id] = _folderSort.length;
    await _persistFolders();
    foldersVersion.value++;
  }

  /// 重命名分类（「默认分类」/「全部」不允许重命名）。
  static Future<void> renameFolder(String id, String name) async {
    await _ensureFoldersLoaded();
    final t = name.trim();
    if (t.isEmpty || id == allFolderId || id == defaultFolderId) return;
    if (!_folderSort.containsKey(id)) return;
    _folderNames[id] = t;
    await _persistFolders();
    foldersVersion.value++;
  }

  /// 删除分类：所属书籍回落到「默认分类」（不删书）。
  static Future<void> deleteFolder(String id) async {
    await _ensureFoldersLoaded();
    if (id == allFolderId || id == defaultFolderId) return;
    if (!_folderSort.containsKey(id)) return;
    _folderSort.remove(id);
    _folderNames.remove(id);
    for (final m in _all()) {
      if (m['folderId'] == id) m['folderId'] = defaultFolderId;
    }
    _save();
    await _persistFolders();
    foldersVersion.value++;
  }

  /// 读取某本书所属分类（id）。旧数据/未设置返回 [defaultFolderId]。
  static String folderIdOf(String sourceId, String comicId) {
    final v = _cache[_key(sourceId, comicId)]?['folderId'];
    return (v is String && v.isNotEmpty) ? v : defaultFolderId;
  }

  /// 写入某本书所属分类（传 [defaultFolderId] 归入默认分类）。
  static void setFolderId(String sourceId, String comicId, String folderId) {
    final m = _cache[_key(sourceId, comicId)];
    if (m == null) return;
    m['folderId'] = folderId;
    _save();
  }

  static void bindFile(File file) {
    _file = file;
    _load();
    _rebuildIndex();
    // 新文件范围：分类内存态作废，下次访问从该文件对应目录重读。
    _foldersLoaded = false;
    _folderNames = {};
    _folderSort = {};
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
  /// 写入通过 [_writeTail] 串行排队，杜绝并发 writeAsString 交错。
  static void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      final f = _file;
      if (f == null) return;
      final snapshot = jsonEncode(_cache);
      _writeTail = _writeTail.then((_) => _writeAsync(f, snapshot));
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
      'type': d.type ?? '',
      'status': d.status ?? '',
      'chapters': d.chapters
          .map((c) => {'id': c.id, 'title': c.title})
          .toList(),
      'addedAt': DateTime.now().millisecondsSinceEpoch,
      // 新收藏书籍默认归入「默认分类」（后续可在移入分类菜单调整）。
      'folderId': defaultFolderId,
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

  /// 覆盖导入（用于恢复备份）。恢复后分类定义可能一并变化，
  /// 清掉内存缓存标记，下次 [folders] 从磁盘重新读取。
  static void importData(Map<String, dynamic> data) {
    _cache = Map.from(data);
    _save();
    _foldersLoaded = false;
    _folderNames = {};
    _folderSort = {};
    foldersVersion.value++;
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
      type: (m['type'] as String?) ?? '',
      status: (m['status'] as String?) ?? '',
      sourceId: (m['sourceId'] as String?) ?? '',
    );
  }

  /// 书架的「最近更新时间」：优先取阅读历史里该作品的最后阅读时间，
  /// 无阅读记录时回退到收藏时间（addedAt）。供排序/展示用。
  static int updateTimeOf(ComicDetail d, List<HistoryEntry> history) {
    final sid = d.sourceId ?? '';
    final key = '$sid::${d.id}';
    for (final h in history) {
      if (h.book.key == key) return h.timestamp;
    }
    // 兜底：同 comicId 跨源也可能命中（历史 key 含源 id，此处放宽）
    for (final h in history) {
      if (h.book.comicId == d.id) return h.timestamp;
    }
    return addedAtOf(d);
  }

  /// 读取某本书的收藏时间（addedAt），无记录返回 0。
  static int addedAtOf(ComicDetail d) {
    final sid = d.sourceId ?? '';
    final v = _cache[_key(sid, d.id)]?['addedAt'];
    return (v as int?) ?? 0;
  }
}
