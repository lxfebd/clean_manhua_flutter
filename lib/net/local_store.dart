import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/comic_item.dart';

/// 在独立 Isolate 中解析 JSON（用于大文件，避免阻塞 UI）。
dynamic _jsonDecodeCompute(String raw) => jsonDecode(raw);

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

/// 历史记录：记录看过的漫画 + 上次读到哪一话（+ 读到第几页）。
class HistoryEntry {
  final Bookmark book;
  final String chapterId;
  final String chapterTitle;
  final int timestamp;

  /// 上次读到的页码（0 基），-1 表示未知（旧数据）。
  final int pageIndex;

  /// 该章节总页数（0 表示未知），用于书架进度条精确计算。
  final int chapterTotalPages;

  const HistoryEntry({
    required this.book,
    required this.chapterId,
    required this.chapterTitle,
    required this.timestamp,
    this.pageIndex = -1,
    this.chapterTotalPages = 0,
  });

  bool get hasPage => pageIndex >= 0;

  Map<String, dynamic> toMap() => {
        ...book.toMap(),
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'timestamp': timestamp,
        'pageIndex': pageIndex,
        'chapterTotalPages': chapterTotalPages,
      };

  factory HistoryEntry.fromMap(Map<String, dynamic> m) => HistoryEntry(
        book: Bookmark.fromMap(m),
        chapterId: (m['chapterId'] as String?) ?? '',
        chapterTitle: (m['chapterTitle'] as String?) ?? '',
        timestamp: (m['timestamp'] as int?) ?? 0,
        pageIndex: (m['pageIndex'] as num?)?.toInt() ?? -1,
        chapterTotalPages: (m['chapterTotalPages'] as num?)?.toInt() ?? 0,
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
      final json = jsonEncode(data);
      await f.writeAsString(json, flush: true);
    } catch (_) {}
  }

  static dynamic _read(String name) async {
    try {
      final f = await _fileAsync(name);
      if (!f.existsSync()) return null;
      final raw = await f.readAsString();
      if (raw.length > 64 * 1024) {
        return await compute(_jsonDecodeCompute, raw);
      }
      return jsonDecode(raw);
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

  /// 当前主题色 ID（0=墨蓝(默认), 1=东京夜, 2=翡翠绿, 3=暖橙, 4=薰衣草）。
  static Future<int> themeId() async =>
      ((await _read('settings')) as Map?)?['themeId'] as int? ?? 0;

  static Future<void> setThemeId(int v) async => _write('settings', {
        'dark': await darkMode(),
        'horizontal': await horizontalReader(),
        'rtl': await rtlReader(),
        'themeId': v,
        'resLevel': await resLevel(),
      });

  static Future<bool> horizontalReader() async =>
      ((await _read('settings')) as Map?)?['horizontal'] as bool? ?? false;

  /// 日漫 RTL 反向翻页（true = 从右往左，翻页方向取反）。
  static Future<bool> rtlReader() async =>
      ((await _read('settings')) as Map?)?['rtl'] as bool? ?? false;

  static Future<int> resLevel() async =>
      ((await _read('settings')) as Map?)?['resLevel'] as int? ?? 0;

  static Future<void> setDarkMode(bool v) async => _write('settings', {
        'dark': v,
        'horizontal': await horizontalReader(),
        'rtl': await rtlReader(),
        'resLevel': await resLevel(),
      });

  static Future<void> setHorizontalReader(bool v) async => _write('settings', {
        'dark': await darkMode(),
        'horizontal': v,
        'rtl': await rtlReader(),
        'resLevel': await resLevel(),
      });

  static Future<void> setRtlReader(bool v) async => _write('settings', {
        'dark': await darkMode(),
        'horizontal': await horizontalReader(),
        'rtl': v,
        'resLevel': await resLevel(),
      });

  static Future<void> setResLevel(int v) async => _write('settings', {
        'dark': await darkMode(),
        'horizontal': await horizontalReader(),
        'rtl': await rtlReader(),
        'resLevel': v,
      });

  // ---- 小说阅读设置 ----
  /// 小说字号（默认 17）。
  static Future<int> novelFontSize() async =>
      ((await _read('novel_read_settings')) as Map?)?['fontSize'] as int? ?? 17;

  /// 小说行距倍数*100（默认 180）。
  static Future<int> novelLineHeight() async {
    final v = ((await _read('novel_read_settings')) as Map?)?['lineHeight'];
    if (v is num) return v.round();
    return 180;
  }

  /// 小说背景纸色：0=跟随主题 1=米白 2=浅绿 3=暗黑。
  static Future<int> novelTheme() async =>
      ((await _read('novel_read_settings')) as Map?)?['theme'] as int? ?? 0;

  static Future<void> setNovelReadSettings({
    int? fontSize,
    int? lineHeight,
    int? theme,
  }) async {
    final cur = (await _read('novel_read_settings')) as Map? ?? {};
    await _write('novel_read_settings', {
      'fontSize': fontSize ?? cur['fontSize'] ?? 17,
      'lineHeight': lineHeight ?? cur['lineHeight'] ?? 180,
      'theme': theme ?? cur['theme'] ?? 0,
    });
  }

  // ---- 阅读统计 ----
  /// 累计一段阅读时长（秒）到当天。
  /// 存储结构：reading_stats -> { "2026-08-23": 3600, ... }（按天，秒）。
  static Future<void> addReadingSeconds(int seconds) async {
    if (seconds <= 0) return;
    final day = _todayKey();
    final m = (await _read('reading_stats')) as Map? ?? {};
    m[day] = ((m[day] as num?) ?? 0).toInt() + seconds;
    await _write('reading_stats', m);
  }

  /// 读取某天的阅读秒数。
  static Future<int> readingSecondsOfDay(String dayKey) async =>
      ((await _read('reading_stats')) as Map?)?[dayKey] as int? ?? 0;

  /// 今日阅读秒数。
  static Future<int> todayReadingSeconds() => readingSecondsOfDay(_todayKey());

  /// 本周（最近 7 天）阅读秒数总和。
  static Future<int> weekReadingSeconds() async {
    final m = (await _read('reading_stats')) as Map? ?? {};
    var sum = 0;
    for (var i = 0; i < 7; i++) {
      final d = DateTime.now().subtract(Duration(days: i));
      sum += (m[_dayKeyOf(d)] as int?) ?? 0;
    }
    return sum;
  }

  /// 累计阅读秒数（所有记录）。
  static Future<int> totalReadingSeconds() async {
    final m = (await _read('reading_stats')) as Map? ?? {};
    var sum = 0;
    for (final v in m.values) {
      sum += (v as num?)?.toInt() ?? 0;
    }
    return sum;
  }

  /// 最近 N 天每天的阅读秒数（按日期升序返回 [{day, seconds}]）。
  static Future<List<Map<String, dynamic>>> recentReadingDays(int n) async {
    final m = (await _read('reading_stats')) as Map? ?? {};
    final out = <Map<String, dynamic>>[];
    for (var i = n - 1; i >= 0; i--) {
      final d = DateTime.now().subtract(Duration(days: i));
      final key = _dayKeyOf(d);
      out.add({'day': key, 'seconds': (m[key] as int?) ?? 0});
    }
    return out;
  }

  static String _todayKey() => _dayKeyOf(DateTime.now());

  static String _dayKeyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---- 阅读器手势配置 ----
  /// 阅读器手势模式：left/center/right 分别映射到哪个动作。
  /// 可选值：prevPage, nextPage, toggleMenu, toggleBrightness, scrollDown, scrollUp。
  static const List<String> gestureActions = [
    'prevPage', 'nextPage', 'toggleMenu', 'toggleBrightness', 'scrollDown', 'scrollUp',
  ];

  /// 默认手势：左=上一页，中=菜单，右=下一页。
  static const Map<String, String> _defaultGesture = {
    'left': 'prevPage',
    'center': 'toggleMenu',
    'right': 'nextPage',
  };

  /// 读取手势配置。
  static Future<Map<String, String>> gestureConfig() async {
    final m = (await _read('gesture_config')) as Map?;
    if (m == null) return Map.from(_defaultGesture);
    return {
      'left': (m['left'] as String?) ?? _defaultGesture['left']!,
      'center': (m['center'] as String?) ?? _defaultGesture['center']!,
      'right': (m['right'] as String?) ?? _defaultGesture['right']!,
    };
  }

  /// 写入手势配置。
  static Future<void> setGestureConfig(Map<String, String> cfg) async {
    await _write('gesture_config', cfg);
  }

  // ---- 更新检查 ----
  /// 上次自动检查更新的时间戳（ms）。用于限制每天最多自动检查一次。
  static Future<int> lastUpdateCheckTs() async =>
      ((await _read('update_check')) as Map?)?['ts'] as int? ?? 0;

  /// 记录本次自动检查更新时间。
  static Future<void> setLastUpdateCheckTs(int ts) async =>
      _write('update_check', {'ts': ts});

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

  // ---- 备份/恢复 ----

  /// 收集所有用户数据（书架/小说书架/历史/动画记录/收藏/下载清单/设置/源配置），
  /// 返回可直接 JSON 序列化的结构。下载图片文件不包含在内。
  static Future<Map<String, dynamic>> collectBackup({
    required dynamic bookshelfData,
    required dynamic novelShelfData,
  }) async {
    return {
      'version': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'favorites': await _read('favorites'),
      'history': await _read('history'),
      'video_records': await _read('video_records'),
      'downloads': await _read('downloads'),
      'settings': await _read('settings'),
      'sources_config': await _read('sources_config'),
      'bookshelf': bookshelfData,
      'novel_shelf': novelShelfData,
    };
  }

  /// 从备份数据恢复。返回恢复的数据文件个数字符串，便于提示。
  static Future<int> restoreBackup(Map<String, dynamic> data) async {
    var count = 0;
    Future<void> put(String name, Object? v) async {
      if (v == null) return;
      await _write(name, v);
      count++;
    }

    await put('favorites', data['favorites']);
    await put('history', data['history']);
    await put('video_records', data['video_records']);
    await put('downloads', data['downloads']);
    await put('settings', data['settings']);
    await put('sources_config', data['sources_config']);
    return count;
  }
}
