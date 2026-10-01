import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/bookshelf_store.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/video_download_manager.dart';
import '../sources/comic_source.dart';

/// 动漫下载任务版本桥接：ValueNotifier → NotifierProvider（Riverpod 2.6.1
/// 无 ValueNotifierProvider，须 NotifierProvider 桥接；批次 C 约定）。
/// 任务进度变化（notifier.value 更新）时递增版本号，`bookshelfDataProvider`
/// watch 它 → 下载页进度条实时走动，不再只读一次快照。
final animeDownloadVersionProvider =
    NotifierProvider<AnimeDownloadVersionNotifier, int>(
  AnimeDownloadVersionNotifier.new,
);

class AnimeDownloadVersionNotifier extends Notifier<int> {
  @override
  int build() {
    final notifier = VideoDownloadManager.instance.notifier;
    // ValueNotifier 无内置 provider 桥接：用 listen 同步版本号。
    notifier.addListener(_bump);
    ref.onDispose(() => notifier.removeListener(_bump));
    return 0;
  }

  void _bump() => state++;
}

/// 书架页六组本地数据的不可变快照。
///
/// 聚合读取结果供书架页渲染：漫画列表、最近阅读、视频记录、下载记录、
/// 分类定义、书签。任一组读取失败时该组为空列表并携带错误原因；
/// 全部六组失败才足以让页面进入整页错误视图（判定逻辑在页面侧）。
class BookshelfData {
  final List<ComicDetail> items;
  final List<HistoryEntry> recent;
  final List<VideoRecord> videos;
  final List<DownloadRecord> mangaDownloads;
  final List<VideoDownloadTask> animeDownloads;
  final List<Map<String, dynamic>> folders;
  final List<ComicBookmark> bookmarks;
  /// 全部六组失败时的错误原因（成功/部分失败时为 null）。
  final String? totalError;

  const BookshelfData({
    required this.items,
    required this.recent,
    required this.videos,
    required this.mangaDownloads,
    required this.animeDownloads,
    required this.folders,
    required this.bookmarks,
    this.totalError,
  });

  /// 值相等：让 FutureProvider 对「无实质变化」的重读短路（Riverpod 相等
  /// 短路后 listenManual 不再回调、页面不整组重灌）。
  ///
  /// 背景：动漫下载进度经 animeDownloadVersionProvider 驱动本 provider
  /// 高频重读（下载期间每 300ms 一次）。六组本地读虽快，但每次重读都
  /// 产生新实例 → 页面 _applyData 整组重建列表，用户滚动会被抖。值相等
  /// 后仅当任意一组**实际内容变化**（含任务进度推进）才回调页面。
  ///
  /// 相等范围：animeDownloads 用「key+state+进度」快照（进度推进视为变化
  /// ——这正是驱动实时进度所需的）；其余列表按 identity（内部成员本就不变，
  /// 仅重读产生新容器）。folders/bookmarks 等 Map/对象无稳定 identity，用
  /// toString 兜底近似（内容变化时通常 toString 也变，够用）。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BookshelfData) return false;
    if (!identical(items, other.items) ||
        !identical(recent, other.recent) ||
        !identical(videos, other.videos) ||
        !identical(mangaDownloads, other.mangaDownloads) ||
        !identical(bookmarks, other.bookmarks) ||
        totalError != other.totalError) {
      return false;
    }
    // 动漫下载：内容快照比较（列表元素是可变对象，identity 恒不同）。
    final a = animeDownloads;
    final b = other.animeDownloads;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final ta = a[i];
      final tb = b[i];
      if (ta.key != tb.key ||
          ta.state != tb.state ||
          ta.doneBytes != tb.doneBytes ||
          ta.totalBytes != tb.totalBytes ||
          ta.segmentsDone != tb.segmentsDone ||
          ta.segmentsTotal != tb.segmentsTotal ||
          ta.localPath != tb.localPath) {
        return false;
      }
    }
    // 分类列表：无稳定 identity，用 toString 近似（内容变化通常文本也变）。
    return folders.toString() == other.folders.toString();
  }

  @override
  int get hashCode => Object.hash(
      items, recent, videos, mangaDownloads, bookmarks,
      folders.toString(), totalError,
      // 与 == 的 animeDownloads 快照口径一致（内容 hash，非 identity）。
      Object.hashAllUnordered(animeDownloads.map(
          (t) => Object.hash(t.key, t.state, t.doneBytes, t.totalBytes,
              t.segmentsDone, t.segmentsTotal, t.localPath))));
}

/// 单组读取结果：成功返回 [data]；失败返回空列表 + [error]。
class _GroupRead<E> {
  final List<E> data;
  final String? error;
  const _GroupRead(this.data, {this.error});
}

/// 尽力恢复：单组本地数据读取失败时返回空列表 + 错误原因，
/// 不让一组损坏拖垮整页（其余数据照常渲染）。
Future<_GroupRead<E>> _readGroup<E>(Future<List<E>> Function() read) async {
  try {
    return _GroupRead(await read());
  } catch (e) {
    ErrorLogger.instance.warn('书架本地数据读取失败，已用空列表兜底: $e');
    return _GroupRead(<E>[], error: '书架本地数据读取异常');
  }
}

/// 书架分类版本号（[BookshelfStore.foldersVersion]）的 Riverpod 视图。
///
/// 分类增删改（addFolder/renameFolder/deleteFolder/importData）自增底层
/// ValueNotifier 时，本 provider 同步 emit 新值，供 [bookshelfDataProvider]
/// watch 自动失效。仅转发版本号，不接管 ValueNotifier 生命周期。
final foldersVersionProvider = NotifierProvider<FoldersVersionNotifier, int>(
    FoldersVersionNotifier.new);

class FoldersVersionNotifier extends Notifier<int> {
  @override
  int build() {
    final v = BookshelfStore.foldersVersion;
    v.addListener(_sync);
    ref.onDispose(() => v.removeListener(_sync));
    return v.value;
  }

  void _sync() => state = BookshelfStore.foldersVersion.value;
}

/// 书架页数据源：六组本地数据并行读取，总耗时 ≈ 最慢一组。
///
/// - 订阅 [foldersVersionProvider]：分类增删改时自动失效重读，书架页无需手动 reload。
/// - 页面主动刷新（下拉、切 Tab）用 `ref.invalidate(bookshelfDataProvider)`。
final bookshelfDataProvider = FutureProvider<BookshelfData>((ref) async {
  ref.watch(foldersVersionProvider);
  // 动漫下载进度订阅：任务进度变化 → 版本号递增 → 本 provider 重读，
  // 下载页进度条实时走动。
  ref.watch(animeDownloadVersionProvider);
  final results = await Future.wait([
    _readGroup(() => Future.value(BookshelfStore.listAll())),
    _readGroup(() => LocalStore.history()),
    _readGroup(() => LocalStore.videoRecords()),
    _readGroup(() => LocalStore.downloads()),
    _readGroup(() => Future.value(BookshelfStore.folders())),
    _readGroup(() => LocalStore.bookmarks()),
  ]);
  final errors =
      results.map((r) => r.error).whereType<String>().toList();
  // 全部六组失败才携带整页错误（页面侧据此进错误视图）；单组失败仅空列表兜底。
  final totalError =
      errors.length == 6 ? errors.take(3).join('；') : null;
  return BookshelfData(
    items: results[0].data.cast<ComicDetail>(),
    recent: results[1].data.cast<HistoryEntry>(),
    videos: results[2].data.cast<VideoRecord>(),
    mangaDownloads: results[3].data.cast<DownloadRecord>(),
    animeDownloads: VideoDownloadManager.instance.tasks
        // 展示进行中 + 已完成（此前只取 done → 动漫下载进行中在书架「下载」页
        // 完全不可见，用户以为任务丢了）。failed/canceled 是已终止的历史残留，
        // 不占列表。
        .where((t) => t.state == 'downloading' || t.state == 'done')
        .toList(),
    folders: results[4].data.cast<Map<String, dynamic>>(),
    bookmarks: results[5].data.cast<ComicBookmark>(),
    totalError: totalError,
  );
});
