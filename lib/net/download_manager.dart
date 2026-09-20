import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;

import '../sources/source_http.dart';
import 'error_logger.dart';
import 'http_client.dart';
import 'local_store.dart';

/// 章节下载画质档位。
enum DownloadQuality {
  /// 原画：下载源图原样存储（默认，保真）。
  original,

  /// 省空间：宽边压到 [compactMaxWidth] 内重新编码，长条图/大图可省大量空间。
  compact,
}

/// 章节下载结果：成功或失败（附原因，如磁盘空间不足）。
class DownloadResult {
  final bool ok;
  final String? error;
  const DownloadResult.ok() : ok = true, error = null;
  const DownloadResult.fail(this.error) : ok = false;
}

/// 章节下载管理：把图片下载到本地，供离线阅读。
class DownloadManager {
  /// 并发下载数（避免过快/过多并发）。
  static const int _concurrency = 3;

  /// 单张图片下载超时。
  static const Duration _imageTimeout = Duration(seconds: 30);

  /// 省空间档位的最大宽边（逻辑像素；源图超过则等比缩到该宽度）。
  static const int compactMaxWidth = 1080;

  /// 全局取消代际 token。取消是全局的：用户显式调用 [cancelAll] 递增
  /// token，使所有已派发批次失效；[beginBatch] 只快照当前代号，供批次内
  /// 循环用 [isCancelled(gen)] 查询——**不递增**，否则新任务一启动就把
  /// 在途旧任务误判为已取消（原 bool 方案的串扰会换一种形式复现）。
  static int _cancelGen = 0;

  /// 单任务取消标记：key（`sourceId/comicId/chapterId`）→ 已请求取消。
  /// 供 UI 跨页面取消在途下载（如书架取消详情页发起的批量任务），
  /// 不干扰其它任务。新任务开始时消费（remove）本 key 的旧标记，
  /// 不继承旧的取消状态。
  static final Map<String, int> _taskCancels = {};

  /// 快照当前取消代号作为本次批次的代号。新任务开始不会影响在途任务；
  /// 只有 [cancelAll] 递增代号才使所有已派发批次失效。
  static int beginBatch() => _cancelGen;

  /// 是否已请求取消（本批次内）。传入暂停时快照的代号。
  static bool isCancelled(int gen) => gen != _cancelGen;

  /// 该任务是否已被 [cancelTask] 请求取消。下载循环每张图轮询一次。
  static bool isTaskCancelled(String key) => _taskCancels.containsKey(key);

  /// 取消单个下载任务（[downloadChapter] 的 key）。只影响该 key 的在途
  /// 下载，不干扰其它任务。无在途下载时留一个未来标记，任务开始时消费。
  static void cancelTask(String key) => _taskCancels[key] = _cancelGen + 1;

  /// 取消所有进行中的下载任务（使所有已派发批次失效）。
  static void cancelAll() {
    _cancelGen++;
    _taskCancels.clear(); // 全局取消同时清掉单任务标记，避免误取消新任务
  }

  /// 下载某个章节的全部图片（带并发与超时）。
  /// [batchGen] 为本逻辑任务的取消代号（[beginBatch] 返回值）；取消时
  /// 该批次内所有章节收到信号，互不串扰。
  /// [quality] 为 [DownloadQuality.compact] 时，宽边超过 [compactMaxWidth]
  /// 的图会被等比压缩后存储（省空间档），原画档原样落盘。
  /// 单张图片写盘失败（磁盘满/权限等）时停止该章并返回失败原因；
  /// 返回 [DownloadResult.error] 即本章中断，不再继续写后续图。
  static Future<DownloadResult> downloadChapter({
    required int batchGen,
    required Bookmark book,
    required String chapterId,
    required String chapterTitle,
    required List<String> urls,
    DownloadQuality quality = DownloadQuality.original,
    Function(int done, int total)? onProgress,
  }) async {
    final key = '${book.sourceId}/${book.comicId}/$chapterId';
    // 消费单任务取消标记：任务开始前被取消（书架取消按钮抢先按下）→
    // 不落开始记录直接返回；否则清除旧标记，新任务不继承取消状态。
    final preCancelled = _taskCancels.remove(key) != null;
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

    if (preCancelled) {
      await LocalStore.upsertDownload(DownloadRecord(
        book: book,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        total: urls.length,
        done: 0,
        finished: false,
        localKey: key,
        error: '已取消',
      ));
      return const DownloadResult.fail('已取消');
    }

    var done = 0;
    var okCount = 0;
    String? writeError; // 写盘失败原因（磁盘满/权限）；置位后本章停止
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
      if (isCancelled(batchGen)) return;
      if (isTaskCancelled(key)) return;
      if (writeError != null) return; // 已写失败，本章中断
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
          try {
            if (quality == DownloadQuality.compact) {
              await File(path).writeAsBytes(
                  _compactBytes(bytes, compactMaxWidth));
            } else {
              await File(path).writeAsBytes(bytes);
            }
          } on FileSystemException catch (e) {
            // 写盘失败：多数是磁盘满/只读/权限。记录原因并中断本
            // 章，避免继续下载产生更多失败页（用户看不到原因）。
            writeError = _describeWriteError(e);
            ErrorLogger.instance.logError(
                '[download] write FAIL chapter=$chapterId idx=$i err=$e');
            return;
          }
        }
        okCount++;
      } catch (e) {
        // 单张图拉取失败不中断整章（尽量多下），但要留痕——
        // 否则 UI 只看到「下载未完成」无法区分网络失败与写盘失败。
        ErrorLogger.instance.warn('[download] img FAIL chapter=$chapterId idx=$i err=$e');
      }
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
    for (var start = 0;
        start < urls.length &&
            !isCancelled(batchGen) &&
            !isTaskCancelled(key) &&
            writeError == null;
        start += _concurrency) {
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

    if (writeError != null) {
      await LocalStore.upsertDownload(DownloadRecord(
        book: book,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        total: urls.length,
        done: done,
        finished: false,
        localKey: key,
        error: writeError,
      ));
      return DownloadResult.fail(writeError);
    }

    // 任务级取消与全局取消取并集判定（同样限定「没下完」）。
    final taskCancelled = isTaskCancelled(key);
    // 取消中断判定必须限定「没下完」：全下完后全局 token 可能已被别的
    // 任务 cancelAll 递增（取消是全局的），此时本章已完整落盘，不能报取消。
    final cancelled =
        (isCancelled(batchGen) || taskCancelled) && done < urls.length;
    final ok = !cancelled && done == urls.length && okCount == urls.length;
    await LocalStore.upsertDownload(DownloadRecord(
      book: book,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      total: urls.length,
      done: done,
      finished: ok,
      localKey: key,
      // 中断原因落盘：用户取消 / 网络失败（done 缺页）也能在下载列表看到具体原因。
      error: cancelled
          ? '已取消'
          : (ok ? null : '下载未完成：${urls.length - done} 页失败'),
    ));
    return ok ? const DownloadResult.ok() : DownloadResult.fail(cancelled ? '已取消' : '下载未完成');
  }

  /// 把写盘异常翻译成用户可读的原因（磁盘满/只读/权限等）。
  static String _describeWriteError(FileSystemException e) {
    final osError = e.osError;
    final msg = osError?.message.toLowerCase() ?? '';
    if (msg.contains('no space') || msg.contains('磁盘空间')) {
      return '磁盘空间不足，请清理后重试';
    }
    if (msg.contains('permission') || msg.contains('denied') ||
        msg.contains('access')) {
      return '没有写入权限，请检查存储目录权限';
    }
    return '写入本地失败：${osError?.message ?? e.message}';
  }

  /// 批量下载多个章节。串行逐章下载，取消后立即停止后续章节。
  static Future<Map<String, bool>> batchDownloadChapters({
    required Bookmark book,
    required List<({String id, String title, List<String> urls})> chapters,
    Function(String chapterId, int done, int total)? onProgress,
  }) async {
    final gen = beginBatch();
    final results = <String, bool>{};
    for (final ch in chapters) {
      if (isCancelled(gen)) {
        results[ch.id] = false;
        continue;
      }
      final r = await downloadChapter(
        batchGen: gen,
        book: book,
        chapterId: ch.id,
        chapterTitle: ch.title,
        urls: ch.urls,
        onProgress: (d, t) => onProgress?.call(ch.id, d, t),
      );
      results[ch.id] = r.ok;
    }
    return results;
  }

  /// 重试单个失败的下载任务。返回失败原因（null = 成功）。
  static Future<String?> retry(String bookKey, String chapterId,
      String chapterTitle, List<String> urls) async {
    final parts = bookKey.split('::');
    if (parts.length != 2) return '无效的下载任务';
    // 复用已存记录里的书名/封面，避免重试后元信息被清空（下载列表显示空标题）。
    final prev = await LocalStore.downloadOf('$bookKey::$chapterId');
    final r = await downloadChapter(
      batchGen: beginBatch(),
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
    return r.ok ? null : r.error;
  }

  /// 判断某章节是否已下载完成。web 端无下载能力，恒为 false。
  static Future<bool> isDownloaded(String bookKey, String chapterId) async {
    if (kIsWeb) return false;
    final d = await LocalStore.downloadOf('$bookKey::$chapterId');
    return d?.finished == true;
  }

  /// 读取本地已下载的图片路径；未下载则返回 null。web 端无本地文件，恒为 null。
  static Future<String?> localUrlIfExists(
      String bookKey, String chapterId, int index) async {
    if (kIsWeb) return null;
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
