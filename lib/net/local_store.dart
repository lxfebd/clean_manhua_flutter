import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/comic_item.dart';

/// 收藏/历史记录条目。
class Bookmark {
  final String sourceId;
  final String comicId;
  final String name;
  final String pic;
  final String author;

  const Bookmark({
    required this.sourceId,
    required this.comicId,
    required this.name,
    required this.pic,
    this.author = '',
  });

  Map<String, dynamic> toMap() => {
        'sourceId': sourceId,
        'comicId': comicId,
        'name': name,
        'pic': pic,
        'author': author,
      };

  factory Bookmark.fromMap(Map<String, dynamic> m) => Bookmark(
        sourceId: (m['sourceId'] as String?) ?? '',
        comicId: (m['comicId'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        pic: (m['pic'] as String?) ?? '',
        author: (m['author'] as String?) ?? '',
      );

  String get key => '$sourceId::$comicId';

  ComicItem toComic() => ComicItem(comicId, name, pic)..author = author;
}

/// 历史记录：记录看过的漫画 + 上次读到哪一话。
class HistoryEntry {
  final Bookmark book;
  final String chapterId;
  final String chapterTitle;
  final int timestamp;

  const HistoryEntry({
    required this.book,
    required this.chapterId,
    required this.chapterTitle,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        ...book.toMap(),
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'timestamp': timestamp,
      };

  factory HistoryEntry.fromMap(Map<String, dynamic> m) => HistoryEntry(
        book: Bookmark.fromMap(m),
        chapterId: (m['chapterId'] as String?) ?? '',
        chapterTitle: (m['chapterTitle'] as String?) ?? '',
        timestamp: (m['timestamp'] as int?) ?? 0,
      );

  String get key => book.key;
}

/// 动画观看记录：记录看到哪部剧、哪一集、播到第几秒。
class VideoRecord {
  /// 播放源 id（VideoSource.id）。
  final String sourceId;

  /// 番剧 id，配合 [sourceId] 可重新解析播放链。
  final String videoId;

  final String title;
  final String? cover;

  /// 播放到的集/进度。
  final int season;
  final int episode;

  /// 上次播放位置（秒）。
  final int seconds;

  /// 单集总时长（秒），0 表示未知（无 duration 时进度条按播放时间衰减）。
  final int duration;
  final int timestamp;

  const VideoRecord({
    required this.sourceId,
    required this.videoId,
    required this.title,
    this.cover,
    this.season = 1,
    this.episode = 1,
    this.seconds = 0,
    this.duration = 0,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'sourceId': sourceId,
        'videoId': videoId,
        'title': title,
        'cover': cover,
        'season': season,
        'episode': episode,
        'seconds': seconds,
        'duration': duration,
        'timestamp': timestamp,
      };

  factory VideoRecord.fromMap(Map<String, dynamic> m) => VideoRecord(
        sourceId: (m['sourceId'] as String?) ?? '',
        videoId: (m['videoId'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        cover: m['cover'] as String?,
        season: (m['season'] as num?)?.toInt() ?? 1,
        episode: (m['episode'] as num?)?.toInt() ?? 1,
        seconds: (m['seconds'] as num?)?.toInt() ?? 0,
        duration: (m['duration'] as num?)?.toInt() ?? 0,
        timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
      );

  /// 同一剧集同一集的唯一 key，与历史 key 一致。
  String get key => '$sourceId::$videoId::$season-$episode';
}

/// 下载任务记录。
class DownloadRecord {
  final Bookmark book;
  final String chapterId;
  final String chapterTitle;
  final int total;
  final int done;
  final bool finished;
  final String localKey;

  const DownloadRecord({
    required this.book,
    required this.chapterId,
    required this.chapterTitle,
    required this.total,
    required this.done,
    required this.finished,
    required this.localKey,
  });

  Map<String, dynamic> toMap() => {
        ...book.toMap(),
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'total': total,
        'done': done,
        'finished': finished,
        'localKey': localKey,
      };

  factory DownloadRecord.fromMap(Map<String, dynamic> m) => DownloadRecord(
        book: Bookmark.fromMap(m),
        chapterId: (m['chapterId'] as String?) ?? '',
        chapterTitle: (m['chapterTitle'] as String?) ?? '',
        total: (m['total'] as int?) ?? 0,
        done: (m['done'] as int?) ?? 0,
        finished: (m['finished'] as bool?) ?? false,
        localKey: (m['localKey'] as String?) ?? '',
      );

  String get key => '${book.key}::$chapterId';
}

/// 本地存储：基于 JSON 文件的收藏/历史/设置/下载清单持久化。
/// 所有数据存放在应用文档目录下，避免引入额外依赖。
class LocalStore {
  static Directory? _dir;

  /// 初始化（应用启动时调用一次）。
  static Future<void> init() async {
    await _dirAsync();
  }

  static Future<Directory> _dirAsync() async {
    if (_dir != null) return _dir!;
    final d = await getApplicationSupportDirectory();
    final sub = Directory('${d.path}/data');
    if (!sub.existsSync()) sub.createSync(recursive: true);
    _dir = sub;
    return sub;
  }

  static Future<File> _fileAsync(String name) async {
    final d = await _dirAsync();
    return File('${d.path}/$name.json');
  }

  // ---- 通用读写 ----
  static Future<void> _write(String name, Object data) async {
    try {
      final f = await _fileAsync(name);
      f.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  static dynamic _read(String name) async {
    try {
      final f = await _fileAsync(name);
      if (!f.existsSync()) return null;
      return jsonDecode(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// 对外暴露的 JSON 读写（供源配置等复用同一存储目录）。
  static Future<dynamic> readJson(String name) => _read(name);
  static Future<void> writeJson(String name, Object data) => _write(name, data);

  // ---- 收藏 ----
  static Future<List<Bookmark>> favorites() async {
    final list = (await _read('favorites') as List?) ?? [];
    return list
        .map((e) => Bookmark.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  static Future<bool> isFavorite(String key) async =>
      (await favorites()).any((b) => b.key == key);

  static Future<void> toggleFavorite(Bookmark b) async {
    final list = await favorites();
    final idx = list.indexWhere((x) => x.key == b.key);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, b);
    }
    await _write('favorites', list.map((e) => e.toMap()).toList());
  }

  static Future<void> removeFavorite(String key) async {
    final list = (await favorites()).where((b) => b.key != key).toList();
    await _write('favorites', list.map((e) => e.toMap()).toList());
  }

  // ---- 历史 ----
  static Future<List<HistoryEntry>> history() async {
    final list = (await _read('history') as List?) ?? [];
    final entries = list
        .map((e) => HistoryEntry.fromMap(e as Map<String, dynamic>))
        .toList();
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return entries;
  }

  static Future<void> recordHistory(HistoryEntry entry) async {
    final list = (await history()).where((h) => h.key != entry.key).toList();
    list.insert(0, entry);
    if (list.length > 200) list.removeRange(200, list.length);
    await _write('history', list.map((e) => e.toMap()).toList());
  }

  static Future<void> clearHistory() async => _write('history', []);

  // ---- 动画观看记录 ----
  static Future<List<VideoRecord>> videoRecords() async {
    final list = (await _read('video_records') as List?) ?? [];
    final records = list
        .map((e) => VideoRecord.fromMap(e as Map<String, dynamic>))
        .toList();
    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return records;
  }

  /// 保存/更新一条动画观看记录（同 key 覆盖）。
  static Future<void> recordVideo(VideoRecord r) async {
    final list = (await videoRecords()).where((e) => e.key != r.key).toList();
    list.insert(0, r);
    if (list.length > 300) list.removeRange(300, list.length);
    await _write('video_records', list.map((e) => e.toMap()).toList());
  }

  /// 移除一条动画观看记录。
  static Future<void> removeVideoRecord(String key) async {
    final list = (await videoRecords()).where((e) => e.key != key).toList();
    await _write('video_records', list.map((e) => e.toMap()).toList());
  }

  // ---- 设置 ----
  static Future<bool> darkMode() async =>
      ((await _read('settings')) as Map?)?['dark'] as bool? ?? false;

  static Future<bool> horizontalReader() async =>
      ((await _read('settings')) as Map?)?['horizontal'] as bool? ?? false;

  static Future<void> setDarkMode(bool v) async =>
      _write('settings',
          {'dark': v, 'horizontal': await horizontalReader()});

  static Future<void> setHorizontalReader(bool v) async =>
      _write('settings', {'dark': await darkMode(), 'horizontal': v});

  // ---- 下载记录 ----
  static Future<List<DownloadRecord>> downloads() async {
    final list = (await _read('downloads') as List?) ?? [];
    return list
        .map((e) => DownloadRecord.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  static Future<DownloadRecord?> downloadOf(String key) async {
    for (final d in await downloads()) {
      if (d.key == key) return d;
    }
    return null;
  }

  static Future<void> _saveDownloads(List<DownloadRecord> list) async {
    await _write('downloads', list.map((e) => e.toMap()).toList());
  }

  static Future<void> upsertDownload(DownloadRecord d) async {
    final list = (await downloads()).where((x) => x.key != d.key).toList();
    list.add(d);
    await _saveDownloads(list);
  }

  static Future<void> removeDownload(String key) async {
    await _saveDownloads(
        (await downloads()).where((d) => d.key != key).toList());
  }

  /// 下载文件根目录。
  static Future<Directory> downloadDir() async {
    final base = await _dirAsync();
    final d = Directory('${base.path}/downloads');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 某章节下载图片的本地文件路径。
  static Future<String> localImagePath(String chapterKey, int index) async {
    final d = await downloadDir();
    final cd = Directory('${d.path}/$chapterKey');
    if (!cd.existsSync()) cd.createSync(recursive: true);
    return '${cd.path}/$index.img';
  }

  /// 清空全部下载（文件 + 记录）。
  static Future<void> clearDownloads() async {
    try {
      final d = await downloadDir();
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    await _write('downloads', []);
  }

  /// 仅清理已完成的下载（文件 + 记录），保留进行中的任务。
  static Future<int> clearFinishedDownloads() async {
    final list = await downloads();
    final finished = list.where((d) => d.finished).toList();
    for (final d in finished) {
      await removeDownloadFiles(d);
    }
    await _saveDownloads(list.where((d) => !d.finished).toList());
    return finished.length;
  }

  /// 删除单条下载记录对应的本地文件目录（章节目录），不删记录本身。
  static Future<void> removeDownloadFiles(DownloadRecord d) async {
    try {
      final base = await downloadDir();
      final cd = Directory('${base.path}/${d.localKey}');
      if (cd.existsSync()) cd.deleteSync(recursive: true);
    } catch (_) {}
  }
}
