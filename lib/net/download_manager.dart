import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../sources/source_http.dart';
import 'http_client.dart';
import 'local_store.dart';

/// 章节下载画质档位。
enum DownloadQuality {
  /// 原画：下载源图原样存储（默认，保真）。
  original,

  /// 省空间：宽边压到 [compactMaxWidth] 内重新编码，长条图/大图可省大量空间。
  compact,
}

/// 章节下载管理：把图片下载到本地，供离线阅读。
class DownloadManager {
  /// 并发下载数（避免过快/过多并发）。
  static const int _concurrency = 3;

  /// 单张图片下载超时。
  static const Duration _imageTimeout = Duration(seconds: 30);

  /// 省空间档位的最大宽边（逻辑像素；源图超过则等比缩到该宽度）。
  static const int compactMaxWidth = 1080;

  /// 全局取消标志。注意：归属权在调用方——
  /// 每个逻辑下载任务开始前调用一次 [resetCancel]，
  /// 任务期间任何 [cancelAll] 都会生效（不会被后续任务误清）。
  static bool _cancelled = false;

  /// 是否已请求取消（供批量循环在章节间检查，及时 break）。
  static bool get isCancelled => _cancelled;

  /// 取消所有进行中的下载任务。
  static void cancelAll() => _cancelled = true;

  /// 重置取消标志（每个逻辑下载任务开始前调用一次）。
  static void resetCancel() => _cancelled = false;

  /// 下载某个章节的全部图片（带并发与超时）。
  /// 注意：不在这里重置 [_cancelled]——由每个逻辑下载任务开始前 reset，
  /// 否则 detail 批量循环里下一章会清掉用户刚点的取消标志。
  /// [quality] 为 [DownloadQuality.compact] 时，宽边超过 [compactMaxWidth]
  /// 的图会被等比压缩后存储（省空间档），原画档原样落盘。
  static Future<bool> downloadChapter({
    required Bookmark book,
    required String chapterId,
    required String chapterTitle,
    required List<String> urls,
    DownloadQuality quality = DownloadQuality.original,
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
      if (_cancelled) return;
      try {
        final path = await LocalStore.localImagePath(key, i);
        if (!File(path).existsSync()) {
          // 单源代理：图片下载与源同代理；无配置（null）走全局代理/直连
          final proxy = book.sourceId.isEmpty
              ? null
              : await SourceHttp.proxyFor(book.sourceId);
          final bytes = Uint8List.fromList(await Net.getBytesAuto(urls[i],
                  proxy: proxy)
              .timeout(_imageTimeout));
          if (quality == DownloadQuality.compact) {
            await File(path).writeAsBytes(
                _compactBytes(bytes, compactMaxWidth));
          } else {
            await File(path).writeAsBytes(bytes);
          }
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

  /// 批量下载多个章节。串行逐章下载，取消后立即停止后续章节。
  static Future<Map<String, bool>> batchDownloadChapters({
    required Bookmark book,
    required List<({String id, String title, List<String> urls})> chapters,
    Function(String chapterId, int done, int total)? onProgress,
  }) async {
    resetCancel();
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
    // 复用已存记录里的书名/封面，避免重试后元信息被清空（下载列表显示空标题）。
    final prev = await LocalStore.downloadOf('$bookKey::$chapterId');
    return downloadChapter(
      book: Bookmark(
        sourceId: parts[0],
        comicId: parts[1],
        name: prev?.book.name ?? '',
        pic: prev?.book.pic ?? '',
        author: prev?.book.author ?? '',
      ),
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

  /// 省空间档位：解码后若宽边超过 [maxW] 则等比缩放，再以 PNG 编码。
  /// 解码失败（非标准图/损坏）时原样返回，保证下载不中断。
  static Uint8List _compactBytes(Uint8List bytes, int maxW) {
    try {
      final dec = img.decodeImage(bytes);
      if (dec == null) return bytes;
      final w = dec.width;
      final h = dec.height;
      if (w <= maxW) return bytes; // 本就不超宽，原样保留
      final nh = (h * maxW / w).round();
      final resized = img.copyResize(dec, width: maxW, height: nh);
      return Uint8List.fromList(img.encodePng(resized));
    } catch (_) {
      return bytes;
    }
  }
}
