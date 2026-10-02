import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import 'error_logger.dart';
import 'local_store.dart';
import 'shelf_store_base.dart';

/// 通用本地书架：所有漫画源统一保存在一个 JSON 文件中，
/// 按 sourceId 维度分组。存储机制（装载/写盘/损坏恢复/章节更新计数）
/// 由 [ShelfStoreBase] 提供，本类扩展书架分类、标签、id→sourceId 索引。
class BookshelfStore {
  BookshelfStore._();

  static final ShelfStoreBase _base = ShelfStoreBase(
    webKey: 'bookshelf',
    fileName: 'bookshelf',
    debugName: 'bookshelf',
  );

  /// comicId → sourceId 索引（统一书架视图反查源用，随 add/remove/import 维护）。
  static Map<String, String> _idIndex = {};

  /// 注入写盘失败 UI 钩子（main 启动时接线，勿在构造期依赖 UI 层）。
  static void setWriteErrorHandler(
          void Function(Object error, StackTrace stack) cb) =>
      _base.setWriteErrorHandler(cb);

  static void bindFile(File file) {
    _base.bindFile(file);
    _rebuildIndex();
    // 新文件范围：分类内存态作废，下次访问从该文件对应目录重读。
    _foldersLoaded = false;
    _folderNames = {};
    _folderSort = {};
  }

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
      ErrorLogger.instance.warn('shelf_folders 解析失败（数据可能已损坏）: $e');
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
    // 毫秒时间戳在同一毫秒内连续创建会撞 id（Map 覆盖丢分类），冲突时加后缀。
    var id = 'f${DateTime.now().millisecondsSinceEpoch}';
    while (_folderSort.containsKey(id)) {
      id = '$id+';
    }
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
    for (final m in _base.exportData().values.cast<Map<String, dynamic>>()) {
      if (m['folderId'] == id) m['folderId'] = defaultFolderId;
    }
    _base.persist();
    await _persistFolders();
    foldersVersion.value++;
  }

  /// 读取某本书所属分类（id）。旧数据/未设置返回 [defaultFolderId]。
  static String folderIdOf(String sourceId, String comicId) {
    final v = _base.field(sourceId, comicId, 'folderId');
    return (v is String && v.isNotEmpty) ? v : defaultFolderId;
  }

  /// 写入某本书所属分类（传 [defaultFolderId] 归入默认分类）。
  static void setFolderId(String sourceId, String comicId, String folderId) {
    _base.setField(sourceId, comicId, 'folderId', folderId);
  }

  // ---- 书架条目 ----
  static void add(String sourceId, ComicDetail d) {
    _base.add(sourceId, d.id, {
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
    });
    _idIndex[d.id] = sourceId;
  }

  static void remove(String sourceId, String comicId) {
    _base.remove(sourceId, comicId);
    _idIndex.remove(comicId);
  }

  static bool contains(String sourceId, String comicId) =>
      _base.contains(sourceId, comicId);

  /// 根据 comicId 反查所属 sourceId（书架统一视图中使用）。
  static String? sourceIdOf(String comicId) {
    _base.rawAll();
    return _idIndex[comicId];
  }

  /// 列出某个源的书架。
  static List<ComicDetail> listBySource(String sourceId) {
    return _base.rawBySource(sourceId).map(_fromMap).toList()
      ..sort((a, b) {
        final ma = _readAddedAt(a, defaultSourceId: sourceId);
        final mb = _readAddedAt(b, defaultSourceId: sourceId);
        return mb.compareTo(ma);
      });
  }

  /// 列出全部书架（用于统一书架视图）。
  static List<ComicDetail> listAll() {
    return _base.rawAll().map(_fromMap).toList();
  }

  static void _rebuildIndex() {
    _idIndex = {};
    for (final m in _base.exportData().values) {
      if (m is Map<String, dynamic>) {
        final id = m['id'];
        final sid = m['sourceId'];
        if (id is String && sid is String) _idIndex[id] = sid;
      }
    }
  }

  static int _readAddedAt(ComicDetail d, {String? defaultSourceId}) {
    final sid = defaultSourceId ??
        (_base.exportData().values
            .cast<Map<String, dynamic>>()
            .firstWhere(
              (m) => m['id'] == d.id,
              orElse: () => {'addedAt': 0},
            ))['sourceId'] as String? ??
        '';
    return (_base.field(sid, d.id, 'addedAt') as int?) ?? 0;
  }

  /// 导出原始数据（用于备份）。
  static Map<String, dynamic> exportData() => _base.exportData();

  /// 覆盖导入（用于恢复备份）。恢复后分类定义可能一并变化，
  /// 清掉内存缓存标记，下次 [folders] 从磁盘重新读取。
  static void importData(Map<String, dynamic> data) {
    _base.importData(data);
    _rebuildIndex(); // 替换缓存后必须重建 id→sourceId 索引，否则恢复后 sourceIdOf 失效
    _foldersLoaded = false;
    _folderNames = {};
    _folderSort = {};
    foldersVersion.value++;
  }

  /// 预设标签。
  static const presetTags = ['日漫', '国漫', '韩漫', '热血', '恋爱', '奇幻', '悬疑', '完结'];

  /// 读取某本书的书架标签。
  static List<String> tagsOf(String sourceId, String comicId) {
    final v = _base.field(sourceId, comicId, 'tags');
    if (v is List) return v.cast<String>().toList();
    return const [];
  }

  /// 写入某本书的书架标签（去重保序）。
  static void setTags(String sourceId, String comicId, List<String> tags) {
    _base.setField(sourceId, comicId, 'tags', tags.toSet().toList());
  }

  /// 当前书架使用过的全部标签（含预设，按使用频率降序）。
  static List<String> allTags() {
    final count = <String, int>{};
    for (final m in _base.exportData().values.cast<Map<String, dynamic>>()) {
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
      _base.lastSeenChapters(sourceId, comicId);

  /// 写入上次检查到的章节数。
  static void setLastSeenChapters(
      String sourceId, String comicId, int count) {
    _base.setLastSeenChapters(sourceId, comicId, count);
  }

  /// 判断某本书是否有更新：当前章节数 > 上次记录。
  static bool hasUpdate(String sourceId, String comicId, int currentChapters) =>
      _base.hasUpdate(sourceId, comicId, currentChapters);

  /// 新增章节数（current - last）。
  static int newChapterCount(
      String sourceId, String comicId, int currentChapters) =>
      _base.newChapterCount(sourceId, comicId, currentChapters);

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
    final key = '$sid/${d.id}';
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
    return (_base.field(sid, d.id, 'addedAt') as int?) ?? 0;
  }
}
