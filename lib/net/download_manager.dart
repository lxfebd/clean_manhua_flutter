import 'dart:io';

import 'http_client.dart';
import 'local_store.dart';

/// 章节下载管理：把图片下载到本地，供离线阅读。
class DownloadManager {
  /// 并发下载数（避免过快/过多并发）。
  static const int _concurrency = 3;

  /// 单张图片下载超时。
  static const Duration _imageTimeout = Duration(seconds: 30);

  /// 全局取消标志。
  static bool _cancelled = false;

  /// 取消所有进行中的下载任务。
  static void cancelAll() => _cancelled = true;

  /// 重置取消标志（开始新任务前调用）。
  static void _resetCancel() => _cancelled = false;

  /// 下载某个章节的全部图片（带并发与超时）。
  static Future<bool> downloadChapter({
    required Bookmark book,
    required String chapterId,
    required String chapterTitle,
    required List<String> urls,
    Function(int done, int total)? onProgress,
  }) async {
    _resetCancel();
    final key = '${book.sourceId}/${book.comicId}/$chapterId';
    final record = DownloadRecord(
      book: book,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      total: urls.length,
      done: 0,
      finished: false,
      localKey: key,
    );
    await LocalStore.upsertDownload(record);

    var done = 0;
    var okCount = 0;
    // 已存在本地文件的不重下，先快速累计
    for (var i = 0; i < urls.length; i++) {
      try {
        final path = await LocalStore.localImagePath(key, i);
        if (File(path).existsSync()) {
          done++;
          okCount++;
        }
      } catch (_) {}
    }

    Future<void> downloadOne(int i) async {
      if (_cancelled) return;
      try {
        final path = await LocalStore.localImagePath(key, i);
        if (!File(path).existsSync()) {
          final bytes =
              await Net.getBytesAuto(urls[i]).timeout(_imageTimeout);
          await File(path).writeAsBytes(bytes);
        }
        okCount++;
      } catch (_) {}
      done++;
      onProgress?.call(done, urls.length);
      await LocalStore.upsertDownload(DownloadRecord(
        book: book,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        total: urls.length,
        done: done,
        finished: false,
        localKey: key,
      ));
    }

    // 分批并发：每批最多 _concurrency 张，全部超时可控。
    for (var start = 0; start < urls.length && !_cancelled; start += _concurrency) {
      final end = (start + _concurrency).clamp(0, urls.length);
      final batch = <Future<void>>[];
      for (var i = start; i < end; i++) {
        if (await LocalStore.localImagePath(key, i).then(
                (p) => File(p).existsSync())) {
          continue;
        }
        batch.add(downloadOne(i));
      }
      await Future.wait(batch);
    }

    final ok = !_cancelled && done == urls.length && okCount == urls.length;
    await LocalStore.upsertDownload(DownloadRecord(
      book: book,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      total: urls.length,
      done: done,
      finished: ok,
      localKey: key,
    ));
    return ok;
  }

  /// 批量下载多个章节。
  static Future<Map<String, bool>> batchDownloadChapters({
    required Bookmark book,
    required List<({String id, String title, List<String> urls})> chapters,
    Function(String chapterId, int done, int total)? onProgress,
  }) async {
    _resetCancel();
    final results = <String, bool>{};
    for (final ch in chapters) {
      if (_cancelled) {
        results[ch.id] = false;
        continue;
      }
      final ok = await downloadChapter(
        book: book,
        chapterId: ch.id,
        chapterTitle: ch.title,
        urls: ch.urls,
        onProgress: (d, t) => onProgress?.call(ch.id, d, t),
      );
      results[ch.id] = ok;
    }
    return results;
  }

  /// 重试单个失败的下载任务。
  static Future<bool> retry(String bookKey, String chapterId,
      String chapterTitle, List<String> urls) async {
    final parts = bookKey.split('::');
    if (parts.length != 2) return false;
    return downloadChapter(
      book: Bookmark(sourceId: parts[0], comicId: parts[1], name: '', pic: ''),
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      urls: urls,
    );
  }

  /// 判断某章节是否已下载完成。
  static Future<bool> isDownloaded(String bookKey, String chapterId) async {
    final d = await LocalStore.downloadOf('$bookKey::$chapterId');
    return d?.finished == true;
  }

  /// 读取本地已下载的图片路径；未下载则返回 null。
  static Future<String?> localUrlIfExists(
      String bookKey, String chapterId, int index) async {
    final key = '${bookKey.replaceFirst('::', '/')}/$chapterId';  // bookKey sourceId::comicId → path
    final p = await LocalStore.localImagePath(key, index);
    if (File(p).existsSync()) return p;
    return null;
  }

  /// 通过源 + 漫画/章节 id 构造 bookKey。
  static String bookKeyOf(String sourceId, String comicId) =>
      '$sourceId::$comicId';
}
