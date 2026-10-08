import 'dart:io';

import '../models/comic_item.dart';
import '../sources/novel_source.dart';
import 'shelf_store_base.dart';

/// 小说本地书架：与漫画 [BookshelfStore] 分离，独立 JSON 文件，避免与漫画条目混淆。
/// 存储机制（装载/写盘/损坏恢复/章节更新计数/排序）由泛型 [ShelfStore] 提供，
/// 本类只保留小说条目的序列化差异。
class NovelShelfStore {
  NovelShelfStore._();

  /// 条目强类型 = [NovelDetail]（序列化差异经 fromMap 钩子注入）。
  static final ShelfStore<NovelDetail> _base = ShelfStore<NovelDetail>(
    webKey: 'novel_shelf',
    fileName: 'novel_shelf',
    debugName: 'novel_shelf',
    fromMap: _fromMap,
    idOf: (d) => d.id,
    sourceIdOf: (d) => d.sourceId ?? '',
  );

  /// 注入写盘失败 UI 钩子（main 启动时接线，勿在构造期依赖 UI 层）。
  static void setWriteErrorHandler(
          void Function(Object error, StackTrace stack) cb) =>
      _base.setWriteErrorHandler(cb);

  static void bindFile(File file) => _base.bindFile(file);

  static void add(String sourceId, NovelDetail d) {
    _base.add(sourceId, d.id, {
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
    });
  }

  static void remove(String sourceId, String novelId) =>
      _base.remove(sourceId, novelId);

  static bool contains(String sourceId, String novelId) =>
      _base.contains(sourceId, novelId);

  /// 列出某个源的书架。
  static List<NovelDetail> listBySource(String sourceId) =>
      _base.listBySource(sourceId);

  /// 列出全部书架（用于统一书架视图）。
  static List<NovelDetail> listAll() => _base.listAll();

  /// 导出原始数据（用于备份）。
  static Map<String, dynamic> exportData() => _base.exportData();

  /// 覆盖导入（用于恢复备份）。
  static void importData(Map<String, dynamic> data) =>
      _base.importData(data);

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

  /// 上次检查更新时记录的章节数（-1 = 尚未检查过，不报更新）。
  static int lastSeenChapters(String sourceId, String novelId) =>
      _base.lastSeenChapters(sourceId, novelId);

  /// 写入上次检查到的章节数（ShelfUpdater.checkNow 每轮更新）。
  static void setLastSeenChapters(String sourceId, String novelId, int count) =>
      _base.setLastSeenChapters(sourceId, novelId, count);

  /// 判断该小说是否有更新：当前章节数 > 上次记录。
  static bool hasUpdate(String sourceId, String novelId, int currentChapters) =>
      _base.hasUpdate(sourceId, novelId, currentChapters);

  /// 新增章节数（current - last）。
  static int newChapterCount(
          String sourceId, String novelId, int currentChapters) =>
      _base.newChapterCount(sourceId, novelId, currentChapters);
}