import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'local_store.dart';

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
  }) : key = '$sourceId::$videoId::$season-$episode';

  bool get isM3u8 =>
      url.contains('.m3u8') || url.contains('.m3u8?') || url.contains('m3u8');

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
      };

  factory VideoDownloadTask.fromJson(Map<String, dynamic> m) =>
      VideoDownloadTask(
        sourceId: (m['sourceId'] as String?) ?? '',
        videoId: (m['videoId'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        season: (m['season'] as num?)?.toInt() ?? 1,
        episode: (m['episode'] as num?)?.toInt() ?? 1,
        url: (m['url'] as String?) ?? '',
        headers: Map<String, String>.from(
            (m['headers'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

/// 解析后的 m3u8 媒体播放列表：分片、加密信息、初始化段（均为绝对 URL）。
class _M3u8Playlist {
  final List<String> segments;
  final String? keyUri;
  final String? keyIvHex;
  final int mediaSeq;
  final String? initSegment;
  _M3u8Playlist(this.segments, this.keyUri, this.keyIvHex, this.mediaSeq,
      this.initSegment);
}

/// 视频下载管理器：mp4 直链流式下载 / m3u8 分片下载合并（含 AES-128 解密）。
/// 文件存放：应用私有目录 data/downloads/videos/{番名}/S{季}E{集}.{ext}
class VideoDownloadManager {
  VideoDownloadManager._();

  static final VideoDownloadManager instance = VideoDownloadManager._();

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final Map<String, VideoDownloadTask> _tasks = {};
  final Set<String> _canceled = {};
  final ValueNotifier<Map<String, VideoDownloadTask>> notifier =
      ValueNotifier(const {});

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
    final base = await LocalStore.downloadDir();
    _indexFile = File('${base.path}/video_downloads.json');
    try {
      if (_indexFile.existsSync()) {
        final list = jsonDecode(await _indexFile.readAsString());
        if (list is List) {
          for (final e in list) {
            final t = VideoDownloadTask.fromJson(
                Map<String, dynamic>.from(e as Map));
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
      debugPrint('VideoDownloadManager.init() 索引解析失败: $e');
    }
    _ready = true;
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
    if (existing != null) {
      if (existing.isRunning || existing.state == 'done') return existing;
      _canceled.remove(task.key);
      _tasks[task.key] = task;
    } else {
      _canceled.remove(task.key);
      _tasks[task.key] = task;
    }
    _notify();
    _persist();
    unawaited(_run(task));
    return task;
  }

  void cancel(String key) {
    _canceled.add(key);
  }

  /// 重试一个失败/已取消的任务。返回是否真的启动了重试。
  ///
  /// 会先清掉上次残留的进度与报错，避免 UI 还显示旧的百分比和错误信息。
  /// 不做分片级断点续传：m3u8 会重新拉取全部分片（简单可靠，避免半截文件拼接出错）。
  Future<bool> retry(String key) async {
    await init();
    final t = _tasks[key];
    if (t == null) return false;
    if (t.isRunning || t.state == 'done') return false;
    _canceled.remove(key);
    t.state = 'downloading';
    t.error = null;
    t.doneBytes = 0;
    t.segmentsDone = 0;
    t.totalBytes = 0;
    t.segmentsTotal = 0;
    t.localPath = null;
    _notify();
    unawaited(_run(t));
    return true;
  }

  /// 删除已完成任务（文件 + 记录）。返回是否成功。
  Future<bool> remove(String key) async {
    final t = _tasks.remove(key);
    if (t == null) return false;
    _canceled.add(key);
    if (t.localPath != null) {
      try {
        final f = File(t.localPath!);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        debugPrint('删除下载文件失败 ${t.localPath}: $e');
      }
    }
    _notify();
    _persist();
    return true;
  }

  Future<void> _run(VideoDownloadTask t) async {
    try {
      if (t.isM3u8) {
        await _downloadM3u8(t);
      } else {
        await _downloadMp4(t);
      }
      if (_canceled.contains(t.key)) {
        t.state = 'canceled';
        _cleanupPartFile(t);
      } else {
        t.state = 'done';
      }
    } catch (e) {
      t.error = '${e is HttpException ? e.message : e}';
      t.state = _canceled.contains(t.key) ? 'canceled' : 'failed';
      _cleanupPartFile(t);
    }
    _notify();
    _persist();
  }

  // ---------------- mp4 直链 ----------------

  Future<int> _probeLength(VideoDownloadTask t) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(Uri.parse(t.url)).timeout(
          const Duration(seconds: 30));
      _applyHeaders(req, t.headers);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final sink = part.openSync(mode: FileMode.append);
      try {
        await for (final chunk in _throttle(resp)) {
          if (_canceled.contains(t.key)) {
            resp.drain<void>();
            throw HttpException('已取消');
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
    if (pl.keyUri != null && !_canceled.contains(t.key)) {
      keyBytes = await _fetchBytes(pl.keyUri!, t.headers);
    }

    t.segmentsTotal = pl.segments.length;
    t.doneBytes = 0;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
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
        if (_canceled.contains(t.key)) throw HttpException('已取消');
        var data = await _fetchBytesWith(client, pl.segments[i], t.headers);
        if (keyBytes != null) {
          data = _aesDecrypt(data, keyBytes, _segIv(pl.keyIvHex, pl.mediaSeq + i));
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
      String url, Map<String, String> headers) async {
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
          mediaSeq = int.tryParse(
                  line.substring('#EXT-X-MEDIA-SEQUENCE:'.length).trim()) ??
              0;
        } else if (line.startsWith('#EXT-X-KEY:')) {
          final method =
              RegExp(r'METHOD=([A-Z0-9-]+)').firstMatch(line)?.group(1);
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
      return _resolveMediaPlaylist(variants.first.$2, headers);
    }
    return _M3u8Playlist(segments, keyUri, keyIvHex, mediaSeq, initSegment);
  }

  Uint8List _segIv(String? hex, int mediaSeq) {
    if (hex != null && hex.isNotEmpty) {
      final bytes = Uint8List(hex.length ~/ 2);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return bytes;
    }
    // 默认 IV = 媒体序号 big-endian 128 位（序号占低 64 位，与 ffmpeg AV_WB64 一致）
    final iv = Uint8List(16);
    var seq = mediaSeq;
    for (var i = 15; i >= 8; i--) {
      iv[i] = seq & 0xff;
      seq >>= 8;
    }
    return iv;
  }

  Uint8List _aesDecrypt(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = CBCBlockCipher(AESEngine())..init(false,
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
    final out = Uint8List(data.length);
    var offset = 0;
    // CBC 解密（不剥离 padding，m3u8 分片拼接时保留原始字节）
    final blocks = data.length ~/ 16;
    for (var i = 0; i < blocks; i++) {
      offset += cipher.processBlock(
          data, i * 16, out, offset);
    }
    final tail = data.length - blocks * 16;
    if (tail > 0) {
      out.setRange(offset, offset + tail, data, blocks * 16);
      offset += tail;
    }
    return Uint8List.sublistView(out, 0, offset);
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return _fetchBytesWith(client, url, headers);
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _fetchBytesWith(
      HttpClient client, String url, Map<String, String> headers) async {
    final req = await client.getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    _applyHeaders(req, headers);
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      resp.drain<void>();
      throw HttpException('HTTP ${resp.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 原始 chunk 流按 1s 节流（避免每分片都触发 setState 级通知）。
  Stream<List<int>> _throttle(HttpClientResponse resp) async* {
    final src = resp;
    await for (final chunk in src) {
      yield chunk;
    }
  }

  void _notifyThrottled() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotify >= 300) {
      _lastNotify = now;
      _notify();
    }
  }

  int _lastNotify = 0;

  void _notify() {
    notifier.value = Map.of(_tasks);
  }

  void _cleanupPartFile(VideoDownloadTask t) async {
    try {
      final dir = await _videoDir(t);
      final part = File('${dir.path}/S${t.season}E${t.episode}.mp4.part');
      if (part.existsSync()) part.deleteSync();
    } catch (_) {}
  }

  void _persist() {
    unawaited(() async {
      try {
        final list = _tasks.values.map((t) => t.toJson()).toList();
        await _indexFile.writeAsString(jsonEncode(list), flush: true);
      } catch (e) {
        debugPrint('VideoDownloadManager 索引保存失败: $e');
      }
    }());
  }
}