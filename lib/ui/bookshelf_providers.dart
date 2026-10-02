import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/bookshelf_store.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/video_download_manager.dart';
import '../sources/comic_source.dart';

/// 书架页六组本地数据的不可变快照。
///
/// 聚合读取结果供书架页渲染：漫画列表、最近阅读、视频记录、下载记录、
/// 分类定义、书签。任一组读取失败时该组为空列表并携带错误原因；
/// 全部六组失败才足以让页面进入整页错误视图（判定逻辑在页面侧）。
///
/// ⚠️ 动漫下载任务**不在此聚合**——它有独立的高频进度源（`VideoDownloadManager.notifier`
/// 每 ~300ms 推送），若聚合进来会让本 provider 也随之高频重读、拖累书架主列表。
/// 下载任务由 [animeDownloadTasksProvider] 单独承载，只让「下载」Tab watch。
class BookshelfData {
  final List<ComicDetail> items;
  final List<HistoryEntry> recent;
  final List<VideoRecord> videos;
  final List<DownloadRecord> mangaDownloads;
  final List<Map<String, dynamic>> folders;
  final List<ComicBookmark> bookmarks;
  /// 全部六组失败时的错误原因（成功/部分失败时为 null）。
  final String? totalError;

  const BookshelfData({
    required this.items,
    required this.recent,
    required this.videos,
    required this.mangaDownloads,
    required this.folders,
    required this.bookmarks,
    this.totalError,
  });

  /// 值相等：让 FutureProvider 对「无实质变化」的重读短路（Riverpod 相等
  /// 短路后 listenManual 不再回调、页面不整组重灌）。
  ///
  /// 背景：书架本地读虽快，但每次重读都产生新实例 → 页面 _applyData 整组
  /// 重建列表，用户滚动会被抖。值相等后仅当任意一组**实际内容变化**才回调
  /// 页面。其余列表按 identity（内部成员本就不变，仅重读产生新容器）；
  /// folders 等 Map/对象无稳定 identity，用 toString 兜底近似。
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
    // 分类列表：无稳定 identity，用 toString 近似（内容变化通常文本也变）。
    return folders.toString() == other.folders.toString();
  }

  @override
  int get hashCode => Object.hash(
      items, recent, videos, mangaDownloads, bookmarks,
      folders.toString(), totalError);
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
/// - 动漫下载任务不在此聚合（见 [animeDownloadTasksProvider]），避免高频进度
///   重读拖累书架主列表。
final bookshelfDataProvider = FutureProvider<BookshelfData>((ref) async {
  ref.watch(foldersVersionProvider);
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
    folders: results[4].data.cast<Map<String, dynamic>>(),
    bookmarks: results[5].data.cast<ComicBookmark>(),
    totalError: totalError,
  );
});

/// 动漫下载任务实时列表：展示进行中 + 已完成（此前只取 done → 动漫下载
/// 进行中在书架「下载」页完全不可见，用户以为任务丢了）。failed/canceled
/// 是已终止的历史残留，不占列表。
///
/// 使用 [StreamProvider]：`VideoDownloadManager.instance.notifier` 每 ~300ms
/// 推送一次进度，流式产出让「下载」Tab 进度条实时走动，且**只**影响下载
/// Tab，不再像旧版那样经版本号联动整个 [bookshelfDataProvider] 重读。
final animeDownloadTasksProvider =
    StreamProvider<List<VideoDownloadTask>>((ref) {
  final notifier = VideoDownloadManager.instance.notifier;
  final controller = StreamController<List<VideoDownloadTask>>();
  void emit() =>
      controller.add(_activeTasks(VideoDownloadManager.instance.tasks));
  notifier.addListener(emit);
  ref.onDispose(() {
    notifier.removeListener(emit);
    controller.close();
  });
  emit(); // 初始快照：首帧就展示当前任务，不空转等下一次进度。
  return controller.stream;
});

List<VideoDownloadTask> _activeTasks(List<VideoDownloadTask> all) => all
    .where((t) => t.state == 'downloading' || t.state == 'done')
    .toList();
