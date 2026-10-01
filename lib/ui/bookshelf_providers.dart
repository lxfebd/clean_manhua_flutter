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
        .where((t) => t.state == 'done')
        .toList(),
    folders: results[4].data.cast<Map<String, dynamic>>(),
    bookmarks: results[5].data.cast<ComicBookmark>(),
    totalError: totalError,
  );
});
