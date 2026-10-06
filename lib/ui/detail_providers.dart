import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';

/// 已读章节 id 集合：从历史里筛出指定作品（book.key）读过的章节。
/// 供章节/章节目录列表「已读」角标与「续读」高亮使用；空历史返回空集。
/// 漫画与小说共用（novelId 即 Bookmark.comicId）；纯函数便于单元测试。
Set<String> readChapterIds({
  required List<HistoryEntry> history,
  required String sourceId,
  required String comicId,
}) {
  final key =
      Bookmark(sourceId: sourceId, comicId: comicId, name: '', pic: '').key;
  return {
    for (final h in history)
      if (h.book.key == key) h.chapterId,
  };
}

/// 解析「开始阅读」目标：从历史里找该作品最近读到的章节；无则返回 null
/// （= 第 1 话）。纯函数便于单元测试，行为与历史/章节数据契约解耦。
///
/// 从 [DetailPage.resolveResumeChapter] 提级到 providers 层：详情 provider
/// 不再依赖页面，避免 detail_page ↔ detail_providers 循环导入；原静态方法
/// 保留签名转发到此函数，既有测试零改动。
Chapter? resolveResumeChapter({
  required List<HistoryEntry> history,
  required List<Chapter> chapters,
  required String sourceId,
  required String comicId,
}) {
  final key =
      Bookmark(sourceId: sourceId, comicId: comicId, name: '', pic: '').key;
  for (final h in history.reversed) {
    if (h.book.key != key) continue;
    // 章节列表里找该 chapterId；找不到则用历史条目直接构造
    // （章节可能已从源移除，仍以用户上次读到的位置为准）。
    for (final c in chapters) {
      if (c.id == h.chapterId) return c;
    }
    return Chapter(h.chapterId, h.chapterTitle);
  }
  return null;
}

/// 解析小说「继续阅读」目标：从历史里找该小说最近读到的章节及其滚动位置；
/// 无则返回 null（按钮不显示）。纯函数便于单元测试，行为与历史/章节数据
/// 契约解耦。同 [resolveResumeChapter]，章节已从源移除时用历史条目构造兜底。
({NovelChapter chapter, double offset})? resolveNovelResumeChapter({
  required List<HistoryEntry> history,
  required List<NovelChapter> chapters,
  required String sourceId,
  required String novelId,
}) {
  final key =
      Bookmark(sourceId: sourceId, comicId: novelId, name: '', pic: '').key;
  for (final h in history.reversed) {
    if (h.book.key != key) continue;
    for (final c in chapters) {
      if (c.id == h.chapterId) {
        return (chapter: c, offset: h.scrollOffset);
      }
    }
    return (
      chapter: NovelChapter(h.chapterId, h.chapterTitle),
      offset: h.scrollOffset,
    );
  }
  return null;
}

/// 小说源缺失（详情页需要展示「未找到小说源」而非网络错误）。
class NovelSourceMissing implements Exception {
  final String sourceId;
  const NovelSourceMissing(this.sourceId);
}

/// 漫画详情（按 sourceId+comicId 缓存，family 键用记录结构相等）。
///
/// - 30s 超时（与原详情页一致）；
/// - 源实现不统一回填 [ComicDetail.sourceId]，此处统一绑定——书架/下载/
///   阅读器都依赖它定位源；
/// - 失败经 ErrorLogger 记录后原样 rethrow，页面按异常类型映射文案。
final comicDetailProvider =
    FutureProvider.family<ComicDetail, (String sourceId, String comicId)>(
  (ref, args) async {
    final (sourceId, comicId) = args;
    try {
      final d = await SourceManager.byId(
        sourceId,
      ).detail(comicId).timeout(const Duration(seconds: 30));
      d.sourceId = sourceId;
      return d;
    } catch (e) {
      ErrorLogger.instance.warn('comic detail load failed: $e');
      rethrow;
    }
  },
);

/// 「开始阅读」的目标章节：详情加载后经历史解析续读位（见
/// [resolveResumeChapter]）。历史读取失败不回退第 1 话——[ready] 标记
/// 页面何时可展示「开始阅读」文案与按钮热区。
class ResumeChapter {
  final Chapter? chapter;
  final bool ready;
  const ResumeChapter(this.chapter, {this.ready = true});
}

/// 是否在书架（本地状态）。只读快照：进入详情页首读后缓存；
/// 切书架后本页不自动刷新，与原「进入页面查一次」行为一致——
/// 增删可通过 [ref.invalidate] 主动失效让 UI 重建时重读。
final comicInShelfProvider =
    FutureProvider.family<bool, (String sourceId, String comicId)>(
  (ref, args) async {
    final (sourceId, comicId) = args;
    return SourceManager.byId(sourceId).isInBookshelf(comicId);
  },
);

/// 小说是否在书架（语义同 [comicInShelfProvider]，按 novelId 判）。
final novelInShelfProvider =
    FutureProvider.family<bool, (String sourceId, String novelId)>(
  (ref, args) async {
    final (sourceId, novelId) = args;
    final s = SourceManager.novelById(sourceId);
    if (s == null) return false;
    return s.isInBookshelf(novelId);
  },
);

/// 续读目标解析：watch 详情 provider（详情失败则整体失败），再读历史。
/// 页面 watch/listen 本 provider 即可，不用自己编排 detail→history 时序。
final comicResumeProvider =
    FutureProvider.family<ResumeChapter, (String sourceId, String comicId)>(
  (ref, args) async {
    final (sourceId, comicId) = args;
    final d = await ref.watch(comicDetailProvider(args).future);
    try {
      final hist = await LocalStore.history();
      return ResumeChapter(
        resolveResumeChapter(
          history: hist,
          chapters: d.chapters,
          sourceId: sourceId,
          comicId: comicId,
        ),
      );
    } catch (e) {
      // 历史读取失败不影响阅读：回退第 1 话（chapter 保持 null）。
      ErrorLogger.instance.warn('comic detail resolve resume failed: $e');
      return const ResumeChapter(null);
    }
  },
);

/// 小说详情（按 sourceId+novelId 缓存）。
///
/// - 15s 超时（与原详情页一致）；
/// - 源缺失抛 [NovelSourceMissing]（页面展示「未找到小说源」）；
/// - 其余失败 rethrow，页面统一映射文案。
final novelDetailProvider =
    FutureProvider.family<NovelDetail, (String sourceId, String novelId)>(
  (ref, args) async {
    final (sourceId, novelId) = args;
    final s = SourceManager.novelById(sourceId);
    if (s == null) throw NovelSourceMissing(sourceId);
    try {
      final d = await s
          .detail(novelId)
          .timeout(const Duration(seconds: 15));
      return d;
    } catch (e) {
      ErrorLogger.instance.warn('novel detail load failed: $e');
      rethrow;
    }
  },
);