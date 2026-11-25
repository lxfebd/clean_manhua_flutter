import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'aes_cbc.dart';
import 'download_engine.dart';
import 'error_logger.dart';
import 'http_client.dart';
import 'local_store.dart';
import 'update_notifier.dart';

/// 单集视频下载任务。
class VideoDownloadTask {
  final String key;
  final String sourceId;
  final String videoId;
  final String title;
  final int season;
  final int episode;
  final String url;
  final Map<String, String> headers;

  /// downloading / done / failed / canceled
  String state = 'downloading';
  int doneBytes = 0;

  /// mp4 直链总大小（0 = 未知）。
  int totalBytes = 0;
  int segmentsTotal = 0;
  int segmentsDone = 0;
  String? localPath;
  String? error;
  final DateTime startedAt = DateTime.now();

  VideoDownloadTask({
    required this.sourceId,
    required this.videoId,
    required this.title,
    required this.season,
    required this.episode,
    required this.url,
    this.headers = const {},
  }) : key = '$sourceId/$videoId/$season-$episode';

  bool get isM3u8 {
    final u = url;
    // 用 URL 路径扩展名判断，避免把 /api/play?url=xxx 里恰好含 m3u8 的
    // query 参数误判成流媒体（走 mp4 直链逻辑更稳）。
    final path = u.contains('?') ? u.substring(0, u.indexOf('?')) : u;
    return path.toLowerCase().endsWith('.m3u8');
  }

  bool get isRunning => state == 'downloading';

  double get progress {
    if (state == 'done') return 1;
    if (isM3u8) {
      if (segmentsTotal <= 0) return 0;
      return (segmentsDone / segmentsTotal).clamp(0.0, 1.0);
    }
    if (totalBytes <= 0) return 0;
    return (doneBytes / totalBytes).clamp(0.0, 1.0);
  }

  int get secondsSinceStart => DateTime.now().difference(startedAt).inSeconds;

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'videoId': videoId,
    'title': title,
    'season': season,
    'episode': episode,
    'url': url,
    'headers': headers,
    'state': state,
    'localPath': localPath,
    'error': error,
  };

  factory VideoDownloadTask.fromJson(Map<String, dynamic> m) {
    final t = VideoDownloadTask(
      sourceId: (m['sourceId'] as String?) ?? '',
      videoId: (m['videoId'] as String?) ?? '',
      title: (m['title'] as String?) ?? '',
      season: (m['season'] as num?)?.toInt() ?? 1,
      episode: (m['episode'] as num?)?.toInt() ?? 1,
      url: (m['url'] as String?) ?? '',
      headers: Map<String, String>.from(
        (m['headers'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
    // 恢复持久化状态：否则重启后已完成任务（done + localPath）退化为默认
    // downloading → init() 误标 failed，已下载内容既不可见也打不开。
    t.state = (m['state'] as String?) ?? 'downloading';
    t.localPath = m['localPath'] as String?;
    t.error = m['error'] as String?;
    return t;
  }
}

/// 解析后的 m3u8 媒体播放列表：分片、加密信息、初始化段（均为绝对 URL）。
class _M3u8Playlist {
  final List<String> segments;
  final String? keyUri;
  final String? keyIvHex;
  final int mediaSeq;
  final String? initSegment;
  _M3u8Playlist(
    this.segments,
    this.keyUri,
    this.keyIvHex,
    this.mediaSeq,
    this.initSegment,
  );
}

/// 视频下载管理器：mp4 直链流式下载 / m3u8 分片下载合并（含 AES-128 解密）。
/// 文件存放：应用私有目录 data/downloads/videos/{番名}/S{季}E{集}.{ext}
class VideoDownloadManager {
  VideoDownloadManager._() {
    _queue = TaskQueue<String>(
      maxConcurrent: _maxConcurrent,
      run: (key) {
        final t = _tasks[key];
        if (t == null) return Future.value();
        // P1-09：登记在途 Future——remove() 要等它真正停下，否则
        // 已删除的文件会被在途写盘重新写出来。
        final f = _run(t);
        _inflight[key] = f;
        f.whenComplete(() => _inflight.remove(key));
        return f;
      },
    );
    _persistDebounced = DebouncedPersist(
      debounce: const Duration(milliseconds: 500),
      write: _writeIndex,
    );
  }

  static final VideoDownloadManager instance = VideoDownloadManager._();

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final Map<String, VideoDownloadTask> _tasks = {};

  /// 取消 token（P0-1 引擎共享）：per-key 单任务取消，与历史 [_canceled]
  /// 集合语义一致（任务开始/重试/删除后重新下载时清除标记）。
  final CancelToken _cancel = CancelToken();

  /// 同时进行的下载任务数上限：低端机多任务并发会耗尽磁盘 IO 与带宽，
  /// 导致下载互相拖慢、进度跳动。超过上限的任务排队等待。
  static const int _maxConcurrent = 2;

  /// 有界任务队列（P0-1 引擎共享）：并发上限 2，超出排队，完成自动补位。
  late final TaskQueue<String> _queue;

  /// 总进度看门狗：[_run] 周期采样发现任务在途 90 秒零字节增长时中止
  /// （与分片级 stall 守卫并列，防「一直在吐但几乎不涨」的涓流）。
  final Set<String> _stalled = {};

  final ValueNotifier<Map<String, VideoDownloadTask>> notifier = ValueNotifier(
    const {},
  );

  /// 进度通知节流（P0-1 引擎共享）：每 300ms 合并一次 ValueNotifier 通知。
  final ProgressThrottle _notifyThrottle = ProgressThrottle(
    const Duration(milliseconds: 300),
  );

  /// 索引防抖持久化（P0-1 引擎共享）：批量状态更新合并到 500ms 窗口末尾。
  late final DebouncedPersist _persistDebounced;

  File _indexFile = File('');
  bool _ready = false;

  static Future<Directory> _videosRoot() async {
    final base = await LocalStore.downloadDir();
    final d = Directory('${base.path}/videos');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 启动时调用：加载已下载索引。
  Future<void> init() async {
    if (_ready) return;
    _ready = true; // web 端无本地视频下载，直接视为就绪（避免 path_provider 报错）
    if (kIsWeb) return;
    final base = await LocalStore.downloadDir();
    _indexFile = File('${base.path}/video_downloads.json');
    try {
      if (_indexFile.existsSync()) {
        final list = jsonDecode(await _indexFile.readAsString());
        if (list is List) {
          for (final e in list) {
            final t = VideoDownloadTask.fromJson(
              Map<String, dynamic>.from(e as Map),
            );
            if (t.state == 'downloading') {
              // 进程中断导致的悬挂任务标记为失败
              t.state = 'failed';
              t.error = '下载被中断';
            }
            _tasks[t.key] = t;
          }
        }
      }
    } catch (e) {
      ErrorLogger.instance.warn('VideoDownloadManager.init() 索引解析失败: $e');
    }
    _notify();
  }

  List<VideoDownloadTask> get tasks => List.of(_tasks.values);

  VideoDownloadTask? taskOf(String key) => _tasks[key];

  bool isDownloaded(String key) {
    final t = _tasks[key];
    return t != null && t.state == 'done' && t.localPath != null;
  }

  /// 开始下载一集。若已下载/下载中则直接返回现有任务。
  Future<VideoDownloadTask> start({
    required String sourceId,
    required String videoId,
    required String title,
    required int season,
    required int episode,
    required String url,
    Map<String, String> headers = const {},
  }) async {
    // P1-23：Web 无本地文件系统，直接拒绝，避免生成假任务记录。
    if (kIsWeb) {
      final denied = VideoDownloadTask(
        sourceId: sourceId,
        videoId: videoId,
        title: title,
        season: season,
        episode: episode,
        url: url,
        headers: headers,
      );
      denied.state = 'failed';
      denied.error = 'Web 端不支持离线下载';
      return denied;
    }
    await init();
    final task = VideoDownloadTask(
      sourceId: sourceId,
      videoId: videoId,
      title: title,
      season: season,
      episode: episode,
      url: url,
      headers: headers,
    );
    final existing = _tasks[task.key];
    if (existing != null && (existing.isRunning || existing.state == 'done')) {
      return existing;
    }
    // 清理取消标记：删除任务后重新 start 同一集时，若此前 cancel() 留下的
    // 标记未清，新任务会被误判为已取消。
    _cancel.clearTaskCancel(task.key);
    _tasks[task.key] = task;
    _notify();
    _persist();
    _queue.submit(task.key);
    return task;
  }

  void cancel(String key) {
    _cancel.cancelTask(key);
    // 排队中的任务直接标记取消态（还未开始下载）
    if (_queue.removePending(key)) {
      final t = _tasks[key];
      if (t != null) {
        t.state = 'canceled';
        _notify();
        _persist();
      }
    }
    _queue.drain();
  }

  /// 重试一个失败/已取消的任务。返回是否真的启动了重试。
  ///
  /// 会先清掉上次残留的进度与报错，避免 UI 还显示旧的百分比和错误信息。
  /// 不做分片级断点续传：m3u8 会重新拉取全部分片（简单可靠，避免半截文件拼接出错）。
  Future<bool> retry(String key) async {
    if (kIsWeb) return false; // P1-23：Web 无本地下载
    await init();
    final t = _tasks[key];
    if (t == null) return false;
    if (t.isRunning || t.state == 'done') return false;
    _cancel.clearTaskCancel(key);
    t.state = 'downloading';
    t.error = null;
    t.doneBytes = 0;
    t.segmentsDone = 0;
    t.totalBytes = 0;
    t.segmentsTotal = 0;
    t.localPath = null;
    _notify();
    _queue.submit(key);
    return true;
  }

  /// 删除任务（文件 + 记录）。返回是否成功。
  ///
  /// P1-09：**在途任务必须先取消并等它真正停下**。旧实现只做
  /// `removePending + release + clearTaskCancel` 然后直接删文件——而在途
  /// `_run` 仍持有任务对象继续写盘，于是：删掉的文件被重新写出来（用户看到
  /// 「已删除」却又出现）、还可能收到一条迟到的完成通知；同名重新下载时新旧
  /// 两个写者争用同一个 `S{季}E{集}.mp4.part`，产出缝合文件。
  Future<bool> remove(String key) async {
    final t = _tasks.remove(key);
    if (t == null) return false;
    // 1) 在途/排队中：下取消标记，等 _run 在最近的数据块边界退出。
    final wasRunning = _queue.isRunning(key);
    _queue.removePending(key);
    if (wasRunning) {
      _cancel.cancelTask(key);
      final f = _inflight[key];
      if (f != null) {
        try {
          // 上限 10s：下载循环每个数据块都检查取消，正常应在毫秒级退出；
          // 超时说明卡在单个大分片上，此时放弃等待继续删（最坏残留一个
          // 很快会因为取消检查而中止的孤儿写者，由下次清理兜底）。
          await f.timeout(const Duration(seconds: 10));
        } catch (_) {}
      }
    }
    // 2) 释放并发槽与取消标记。release 只负责调度，不能代替取消。
    _queue.release(key);
    _cancel.clearTaskCancel(key);
    // 3) 删除成品 + 残留 .part（在途写者写的是 .part，只删成品会留下垃圾）。
    for (final p in <String?>[
      t.localPath,
      if (t.localPath != null) '${t.localPath}.part',
    ]) {
      if (p == null) continue;
      try {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        ErrorLogger.instance.warn('删除下载文件失败 $p: $e');
      }
    }
    _queue.drain();
    _notify();
    _persist();
    return true;
  }

  /// 在途任务的 Future 登记表（P1-09）。
  final Map<String, Future<void>> _inflight = {};

  Future<void> _run(VideoDownloadTask t) async {
    // 总进度看门狗（P0-1 引擎共享）：每 15s 拍一次 doneBytes，连续 6 拍
    // （90s）零增长 → 标记停滞，循环在下一个分片/数据块边界中止任务。
    // 慢速但持续增长的合法下载不受影响（任一拍有增长即清零计数）。
    final watchdog = StallWatchdog(
      bytesOf: () => t.doneBytes,
      onStalled: () => _stalled.add(t.key),
      isActive: () => t.state == 'downloading',
    )..start();
    try {
      if (t.isM3u8) {
        await _downloadM3u8(t);
      } else {
        await _downloadMp4(t);
      }
      if (_cancel.isTaskCancelled(t.key)) {
        t.state = 'canceled';
        await _cleanupPartFile(t);
      } else if (_stalled.contains(t.key)) {
        t.state = 'failed';
        t.error = '下载停滞，请重试';
        await _cleanupPartFile(t);
      } else {
        t.state = 'done';
      }
    } catch (e) {
      // 原始异常（SocketException/HttpException）进日志；UI 展示用固定中文文案。
      ErrorLogger.instance.logError('[video-dl] FAIL key=${t.key} err=$e');
      t.error = e is HttpException ? e.message : '下载失败，请重试';
      t.state = _cancel.isTaskCancelled(t.key) ? 'canceled' : 'failed';
      await _cleanupPartFile(t);
    } finally {
      watchdog.stop();
      _stalled.remove(t.key);
    }
    // 单集收尾：完成/失败发系统通知（应用切后台或退出下载页时告知结果）。
    // 已取消不发（用户主动行为，无需提醒）。
    // P1-09：任务已被删除时也不发——否则用户刚删掉它，两秒后收到一条
    // 「下载完成」，而文件已经不存在了（白惊喜一场）。
    final stillThere = _tasks.containsKey(t.key);
    if (stillThere && t.state == 'done') {
      unawaited(
        UpdateNotifier.notifyDownloadResult(
          title: '《${t.title}》下载完成',
          text: '第 ${t.episode} 集已缓存，可离线观看',
          error: false,
        ),
      );
    } else if (stillThere && t.state == 'failed') {
      unawaited(
        UpdateNotifier.notifyDownloadResult(
          title: '《${t.title}》下载失败',
          text: '第 ${t.episode} 集：${t.error ?? '请重试'}',
          error: true,
        ),
      );
    }
    _notify();
    _persist();
    // 运行槽位释放 + 拉起排队任务由 TaskQueue._wrap 的 complete 收尾。
  }

  // ---------------- mp4 直链 ----------------

  /// 首块特征嗅探：判断下载回来的第一批字节是不是网页/错误页而非媒体。
  ///
  /// 二进制媒体（TS/fMP4/MP4）不可能以 `<` 或 `{` 开头，因此只看前 256 字节
  /// 的可打印前缀即可，不需要等整包。纯函数，便于单测。
  @visibleForTesting
  static bool looksLikeMarkup(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final head = utf8
        .decode(bytes.take(256).toList(), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    if (head.isEmpty) return false;
    if (head.startsWith('<')) return true; // <!doctype / <html / <?xml
    if (head.startsWith('{') || head.startsWith('[')) return true; // JSON 错误体
    for (final marker in const [
      'not found',
      'access denied',
      'forbidden',
      '请登录',
      '验证',
    ]) {
      if (head.contains(marker)) return true;
    }
    return false;
  }

  Future<int> _probeLength(VideoDownloadTask t) async {
    final client = Net.clientForRequest(Uri.parse(t.url).host);
    try {
      final req = await client.openUrl('HEAD', Uri.parse(t.url));
      _applyHeaders(req, t.headers);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final len = resp.contentLength;
      resp.drain<void>();
      return len > 0 ? len : 0;
    } catch (_) {
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadMp4(VideoDownloadTask t) async {
    t.totalBytes = await _probeLength(t);
    final dir = await _videoDir(t);
    final out = File('${dir.path}/S${t.season}E${t.episode}.mp4');
    final part = File('${out.path}.part');
    if (part.existsSync()) part.deleteSync();
    final client = Net.clientForRequest(Uri.parse(t.url).host)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final req = await client
          .getUrl(Uri.parse(t.url))
          .timeout(const Duration(seconds: 30));
      _applyHeaders(req, t.headers);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      // P0-04：**内容校验第一道**——Content-Type。把网页/登录页/质询页
      // 存成 .mp4 并标「下载完成」是最坑的假成功（用户离线时打不开）。
      final ct = (resp.headers.value('content-type') ?? '').toLowerCase();
      if (ct.contains('text/html') ||
          ct.contains('application/xhtml') ||
          ct.contains('text/plain')) {
        resp.drain<void>();
        throw HttpException('返回的是网页而非视频（content-type=$ct），已放弃');
      }
      final sink = part.openSync(mode: FileMode.append);
      var sniffed = false;
      try {
        // 分块停滞超时：单文件直链下载期间源站中途挂死时，等待下一块
        // 20 秒无数据即放弃本任务（可重试），不无限悬挂。
        await for (final chunk in stallGuarded(
          resp,
          stall: const Duration(seconds: 45),
        )) {
          if (_cancel.isTaskCancelled(t.key)) {
            resp.drain<void>();
            throw HttpException('已取消');
          }
          if (_stalled.contains(t.key)) {
            resp.drain<void>();
            throw HttpException('下载停滞');
          }
          // P0-04：**内容校验第二道**——首块特征嗅探。有些源 404/需要登录
          // 时返回 200 + text/plain + JSON/HTML 正文，Content-Type 拦不住全部。
          if (!sniffed) {
            sniffed = true;
            if (looksLikeMarkup(chunk)) {
              resp.drain<void>();
              throw HttpException('下载内容不是视频（返回网页或错误页），已放弃');
            }
          }
          sink.writeFromSync(chunk);
          t.doneBytes += chunk.length;
          _notifyThrottled();
        }
      } finally {
        sink.closeSync();
      }
      part.renameSync(out.path);
      t.localPath = out.path;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------- m3u8 ----------------

  Future<void> _downloadM3u8(VideoDownloadTask t) async {
    final dir = await _videoDir(t);
    final out = File('${dir.path}/S${t.season}E${t.episode}.mp4');
    final part = File('${out.path}.part');
    if (part.existsSync()) part.deleteSync();

    // 解析播放列表：master（多码率）则取最高码率变体递归解析其媒体列表
    final pl = await _resolveMediaPlaylist(t.url, t.headers);
    if (pl.segments.isEmpty) throw HttpException('m3u8 播放列表为空');

    // 密钥下载失败直接抛出，避免把密文当明文写入产出不可播文件
    Uint8List? keyBytes;
    if (pl.keyUri != null && !_cancel.isTaskCancelled(t.key)) {
      keyBytes = await _fetchBytes(pl.keyUri!, t.headers);
    }

    t.segmentsTotal = pl.segments.length;
    t.doneBytes = 0;
    final client = Net.clientForRequest(Uri.parse(pl.segments.first).host)
      ..idleTimeout = const Duration(seconds: 20);
    final sink = part.openSync(mode: FileMode.writeOnly);
    try {
      // fMP4 流需先写入初始化段，否则合并文件无法被播放器识别
      if (pl.initSegment != null) {
        final init = await _fetchBytesWith(client, pl.initSegment!, t.headers);
        sink.writeFromSync(init);
        t.doneBytes += init.length;
      }
      for (var i = 0; i < pl.segments.length; i++) {
        if (_cancel.isTaskCancelled(t.key)) throw HttpException('已取消');
        if (_stalled.contains(t.key)) throw HttpException('下载停滞');
        var data = await _fetchBytesWith(client, pl.segments[i], t.headers);
        if (keyBytes != null) {
          data = AesCbc.decryptCbcRaw(
            data,
            keyBytes,
            AesCbc.segmentIv(pl.keyIvHex, pl.mediaSeq + i),
          );
        }
        sink.writeFromSync(data);
        t.segmentsDone = i + 1;
        t.doneBytes += data.length;
        _notifyThrottled();
      }
    } finally {
      sink.closeSync();
      client.close(force: true);
    }
    part.renameSync(out.path);
    t.localPath = out.path;
  }

  /// 解析 m3u8 播放列表。master playlist（含 #EXT-X-STREAM-INF）取最高码率
  /// 变体递归解析其媒体播放列表；媒体列表返回分片、密钥、初始化段（均已转为绝对 URL）。
  Future<_M3u8Playlist> _resolveMediaPlaylist(
    String url,
    Map<String, String> headers, {
    int depth = 0,
  }) async {
    if (depth > 3) {
      throw Exception('m3u8 嵌套 master playlist 过深（>$depth 层）');
    }
    final text = await _fetchText(url, headers);
    var mediaSeq = 0;
    String? keyUri;
    String? keyIvHex;
    String? initSegment;
    final segments = <String>[];
    final variants = <(int, String)>[];
    var pendingVariantBw = -1;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
          mediaSeq =
              int.tryParse(
                line.substring('#EXT-X-MEDIA-SEQUENCE:'.length).trim(),
              ) ??
              0;
        } else if (line.startsWith('#EXT-X-KEY:')) {
          final method = RegExp(
            r'METHOD=([A-Z0-9-]+)',
          ).firstMatch(line)?.group(1);
          final rawUri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
          keyIvHex = RegExp(r'IV=0x([0-9a-fA-F]+)').firstMatch(line)?.group(1);
          if (method == null || method == 'NONE' || rawUri == null) {
            keyUri = null;
            keyIvHex = null;
          } else {
            keyUri = _resolveUrl(url, rawUri);
          }
        } else if (line.startsWith('#EXT-X-MAP:')) {
          final u = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
          if (u != null) initSegment = _resolveUrl(url, u);
        } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
          final m = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
          pendingVariantBw = m != null ? (int.tryParse(m.group(1)!) ?? 0) : 0;
        }
        continue;
      }
      if (pendingVariantBw >= 0) {
        variants.add((pendingVariantBw, _resolveUrl(url, line)));
        pendingVariantBw = -1;
      } else {
        segments.add(_resolveUrl(url, line));
      }
    }
    if (variants.isNotEmpty) {
      variants.sort((a, b) => b.$1.compareTo(a.$1));
      return _resolveMediaPlaylist(variants.first.$2, headers, depth: depth + 1);
    }
    return _M3u8Playlist(segments, keyUri, keyIvHex, mediaSeq, initSegment);
  }

  // ---------------- 通用 ----------------

  void _applyHeaders(HttpClientRequest req, Map<String, String> headers) {
    headers.forEach((k, v) => req.headers.set(k, v));
    req.headers.set(HttpHeaders.userAgentHeader, _ua);
  }

  Future<Directory> _videoDir(VideoDownloadTask t) async {
    final root = await _videosRoot();
    final safe = t.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final d = Directory('${root.path}/${safe.isEmpty ? '未命名' : safe}');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String _resolveUrl(String base, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    return Uri.parse(base).resolve(url).toString();
  }

  Future<String> _fetchText(String url, Map<String, String> headers) async {
    final bytes = await _fetchBytes(url, headers);
    return utf8.decode(bytes);
  }

  Future<Uint8List> _fetchBytes(String url, Map<String, String> headers) async {
    final client = Net.clientForRequest(Uri.parse(url).host)
      // 响应体停滞兜底：源站连上了、头也回了，但 body 一直不吐数据
      // （cdn 悬挂/被掐），没有 idleTimeout 会永久挂起这个分片下载。
      ..idleTimeout = const Duration(seconds: 20);
    try {
      return _fetchBytesWith(client, url, headers);
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _fetchBytesWith(
    HttpClient client,
    String url,
    Map<String, String> headers,
  ) async {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    _applyHeaders(req, headers);
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      resp.drain<void>();
      throw HttpException('HTTP ${resp.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    // 每块都带停滞超时：body 中途长时间不吐数据（源站挂死）不能无限等。
    await for (final chunk in stallGuarded(resp)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _notifyThrottled() {
    if (_notifyThrottle.allow()) _notify();
  }

  void _notify() {
    notifier.value = Map.of(_tasks);
  }

  /// 测试注入口：直接向任务表播种任务并通知，避免真实网络下载。
  /// 仅测试使用；生产代码路径一律走 start()/init()。
  @visibleForTesting
  void seedForTest(VideoDownloadTask task) {
    _tasks[task.key] = task;
    _notify();
  }

  /// 测试注入口：清空任务表（含持久化索引），避免跨测试污染。
  @visibleForTesting
  Future<void> resetForTest() async {
    _tasks.clear();
    _queue.clearPending();
    _cancel.cancelAll();
    _notify();
    try {
      if (_indexFile.path.isNotEmpty && _indexFile.existsSync()) {
        await _indexFile.writeAsString('[]', flush: true);
      }
    } catch (_) {}
  }

  Future<void> _cleanupPartFile(VideoDownloadTask t) async {
    try {
      final dir = await _videoDir(t);
      final part = File('${dir.path}/S${t.season}E${t.episode}.mp4.part');
      if (part.existsSync()) part.deleteSync();
    } catch (e) {
      ErrorLogger.instance.warn(
        '[video-dl] cleanup part failed key=${t.key}: $e',
      );
    }
  }

  /// 索引写盘（P0-1 引擎防抖持久化合并调用，批量状态更新 500ms 内仅写一次）。
  void _persist() => _persistDebounced.request();

  /// 立即写盘（供防抖合并窗口之外的关键路径显式调用，如应用切后台/退出前）。
  void flushPersist() => _persistDebounced.flush();

  Future<void> _writeIndex() async {
    try {
      final list = _tasks.values.map((t) => t.toJson()).toList();
      await _indexFile.writeAsString(jsonEncode(list), flush: true);
    } catch (e) {
      ErrorLogger.instance.warn('VideoDownloadManager 索引保存失败: $e');
    }
  }
}
