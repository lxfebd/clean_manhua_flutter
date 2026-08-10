import 'dart:io';

import 'http_client.dart';
import 'local_store.dart';

/// 章节下载管理：把图片下载到本地，供离线阅读。
class DownloadManager {
  /// 并发下载数（避免过快/过多并发）。
  static const int _concurrency = 3;

  /// 单张图片下载超时。
  static const Duration _imageTimeout = Duration(seconds: 30);

  /// 下载某个章节的全部图片（带并发与超时）。
  static Future<bool> downloadChapter({
    required Bookmark book,
    required String chapterId,
    required String chapterTitle,
    required List<String> urls,
    Function(int done, int total)? onProgress,
  }) async {
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
      try {
        final path = await LocalStore.localImagePath(key, i);
        if (!File(path).existsSync()) {
          final bytes =
              await Net.getBytes(urls[i]).timeout(_imageTimeout);
          File(path).writeAsBytesSync(bytes);
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
        finished: done == urls.length,
        localKey: key,
      ));
    }

    // 分批并发：每批最多 _concurrency 张，全部超时可控。
    for (var start = 0; start < urls.length; start += _concurrency) {
      final end = (start + _concurrency).clamp(0, urls.length);
      final batch = <Future<void>>[];
      for (var i = start; i < end; i++) {
        if (await LocalStore.localImagePath(key, i).then(
                (p) => File(p).existsSync())) {
          // 已存在，跳过（done 已在开头累加）
          continue;
        }
        batch.add(downloadOne(i));
      }
      await Future.wait(batch);
    }

    final ok = done == urls.length && okCount == urls.length;
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
