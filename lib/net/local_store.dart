import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/comic_item.dart';
import '../utils/danmaku.dart';
import 'error_logger.dart';

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

  /// 纵向滚动模式下的精确滚动偏移（像素），用于续读精确定位。
  /// 仅纵向模式写入；横向模式为 0（页码已够用）。
  final double scrollOffset;

  const HistoryEntry({
    required this.book,
    required this.chapterId,
    required this.chapterTitle,
    required this.timestamp,
    this.pageIndex = -1,
    this.chapterTotalPages = 0,
    this.scrollOffset = 0,
  });

  bool get hasPage => pageIndex >= 0;

  Map<String, dynamic> toMap() => {
        ...book.toMap(),
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'timestamp': timestamp,
        'pageIndex': pageIndex,
        'chapterTotalPages': chapterTotalPages,
        'scrollOffset': scrollOffset,
      };

  factory HistoryEntry.fromMap(Map<String, dynamic> m) => HistoryEntry(
        book: Bookmark.fromMap(m),
        chapterId: (m['chapterId'] as String?) ?? '',
        chapterTitle: (m['chapterTitle'] as String?) ?? '',
        timestamp: (m['timestamp'] as int?) ?? 0,
        pageIndex: (m['pageIndex'] as num?)?.toInt() ?? -1,
        chapterTotalPages: (m['chapterTotalPages'] as num?)?.toInt() ?? 0,
        scrollOffset: (m['scrollOffset'] as num?)?.toDouble() ?? 0,
      );

  String get key => book.key;
}

/// 手动书签：用户主动收藏漫画的某一页（区别于自动历史记录）。
/// 同书可存多条（不同章节/页码），按时间倒序。
class ComicBookmark {
  final Bookmark book;
  final String chapterId;
  final String chapterTitle;
  final int pageIndex;
  final int timestamp;

  const ComicBookmark({
    required this.book,
    required this.chapterId,
    required this.chapterTitle,
    required this.pageIndex,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        ...book.toMap(),
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'pageIndex': pageIndex,
        'timestamp': timestamp,
      };

  factory ComicBookmark.fromMap(Map<String, dynamic> m) => ComicBookmark(
        book: Bookmark.fromMap(m),
        chapterId: (m['chapterId'] as String?) ?? '',
        chapterTitle: (m['chapterTitle'] as String?) ?? '',
        pageIndex: (m['pageIndex'] as num?)?.toInt() ?? 0,
        timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
      );

  String get key => '${book.key}::$chapterId::$pageIndex';
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

  /// 每文件的串行写盘队列（文件名 -> 尾链）。
  /// "读-改-写"复合操作（如 addReadingSeconds / recordHistory）并发时会互相覆盖，
  /// 这里保证对同一文件的 writeAsString 严格依序执行。
  static final Map<String, Future<void>> _writeQueues = {};

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
  static Future<void> _write(String name, Object data) {
    final prev = _writeQueues[name] ?? Future.value();
    final next = prev.then((_) => _writeNow(name, data));
    // 让队列保留链上的最后一个 future；忽略错误避免链断裂（错误已在 _writeNow 内部消化）
    _writeQueues[name] = next.catchError((_) {});
    return next;
  }

  static Future<void> _writeNow(String name, Object data) async {
    try {
      final f = await _fileAsync(name);
      final json = jsonEncode(data);
      await f.writeAsString(json, flush: true);
    } catch (e) {
      ErrorLogger.instance.warn('LocalStore._write($name) 写盘失败: $e');
    }
  }

  /// 「读-改-写」复合操作整体串行化：fn 排进该文件的写队列，内部必须用
  /// [_writeNow] 直写（不能再调 [_write]，否则会排到 fn 自己后面死锁）。
  /// 并发 toggle/add 时避免双方读到同一快照后互相覆盖（丢更新）。
  static Future<T> _enqueue<T>(String name, Future<T> Function() fn) {
    final prev = _writeQueues[name] ?? Future.value();
    final next = prev.then((_) => fn());
    // 队列尾链转成 Future<void> 吞掉 fn 的异常，防止链断裂；错误已在 fn 内部消化。
    _writeQueues[name] = next.then<void>((_) {}, onError: (_) {});
    return next;
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
    } catch (e) {
      // 文件损坏（写入中断/磁盘错误）：先备份损坏文件再返回 null，
      // 与 BookshelfStore 的 .corrupt 行为对齐，避免"收藏/历史突然清空"无法追溯。
      try {
        final f = await _fileAsync(name);
        if (f.existsSync()) {
          f.renameSync(
              '${f.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
        }
      } catch (e2) {
        ErrorLogger.instance.warn('LocalStore._read($name) 损坏备份失败: $e2');
      }
      ErrorLogger.instance.warn('LocalStore._read($name) 解析失败（数据已损坏，原文件已备份）: $e');
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

  /// 搜索历史（最近 10 条，去重保留最新）。空列表表示无历史。
  static const int _searchHistoryMax = 10;
  static Future<List<String>> searchHistory() async {
    final v = await _read('search_history');
    final list = (v is List) ? v.whereType<String>().toList() : <String>[];
    return list;
  }

  /// 记录一次搜索关键词：去重后插到最前，截断到 10 条上限。
  static Future<void> addSearchHistory(String kw) async {
    final t = kw.trim();
    if (t.isEmpty) return;
    await _enqueue('search_history', () async {
      final list = (await _read('search_history') as List?)?.whereType<String>().toList() ?? <String>[];
      list.removeWhere((e) => e == t);
      list.insert(0, t);
      if (list.length > _searchHistoryMax) {
        list.removeRange(_searchHistoryMax, list.length);
      }
      await _writeNow('search_history', list);
    });
  }

  /// 清空全部搜索历史。
  static Future<void> clearSearchHistory() async =>
      _write('search_history', <String>[]);

  static Future<bool> isFavorite(String key) async =>
      (await favorites()).any((b) => b.key == key);

  static Future<void> toggleFavorite(Bookmark b) async {
    await _enqueue('favorites', () async {
      final list = (await _read('favorites') as List?) ?? [];
      final items = list.map((e) => Bookmark.fromMap(e as Map<String, dynamic>)).toList();
      final idx = items.indexWhere((x) => x.key == b.key);
      if (idx >= 0) {
        items.removeAt(idx);
      } else {
        items.insert(0, b);
      }
      await _writeNow('favorites', items.map((e) => e.toMap()).toList());
    });
  }

  static Future<void> removeFavorite(String key) async {
    await _enqueue('favorites', () async {
      final list = (await _read('favorites') as List?) ?? [];
      final items = list.map((e) => Bookmark.fromMap(e as Map<String, dynamic>)).toList();
      final out = items.where((b) => b.key != key).toList();
      await _writeNow('favorites', out.map((e) => e.toMap()).toList());
    });
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
    await _enqueue('history', () async {
      final raw = (await _read('history') as List?) ?? [];
      final list = raw
          .map((e) => HistoryEntry.fromMap(e as Map<String, dynamic>))
          .where((h) => h.key != entry.key)
          .toList();
      list.insert(0, entry);
      // 新记录时间戳最大，插到最前后整表仍按时间降序，无需再排序。
      if (list.length > 200) list.removeRange(200, list.length);
      await _writeNow('history', list.map((e) => e.toMap()).toList());
    });
  }

  static Future<void> clearHistory() async => _write('history', []);

  // ---- 手动书签 ----
  static Future<List<ComicBookmark>> bookmarks() async {
    final list = (await _read('bookmarks') as List?) ?? [];
    final out = list
        .map((e) => ComicBookmark.fromMap(e as Map<String, dynamic>))
        .toList();
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  /// 新增一条书签（同书同章同页已存在则更新时间，避免重复）。
  static Future<void> addBookmark(ComicBookmark b) async {
    await _enqueue('bookmarks', () async {
      final raw = (await _read('bookmarks') as List?) ?? [];
      final list = raw
          .map((e) => ComicBookmark.fromMap(e as Map<String, dynamic>))
          .where((x) => x.key != b.key)
          .toList();
      list.insert(0, b);
      // 新书签时间戳最大，插到最前后整表仍按时间降序。
      if (list.length > 500) list.removeRange(500, list.length);
      await _writeNow('bookmarks', list.map((e) => e.toMap()).toList());
    });
  }

  /// 删除一条书签（同书同章同页）。
  static Future<void> removeBookmark(
      String sourceId, String comicId, String chapterId, int pageIndex) async {
    final key = '$sourceId::$comicId::$chapterId::$pageIndex';
    await _enqueue('bookmarks', () async {
      final raw = (await _read('bookmarks') as List?) ?? [];
      final list = raw
          .map((e) => ComicBookmark.fromMap(e as Map<String, dynamic>))
          .where((x) => x.key != key)
          .toList();
      await _writeNow('bookmarks', list.map((e) => e.toMap()).toList());
    });
  }

  /// 某书某章某页是否已加书签。
  static Future<bool> isBookmarked(
      String sourceId, String comicId, String chapterId, int pageIndex) async {
    final key = '$sourceId::$comicId::$chapterId::$pageIndex';
    return (await bookmarks()).any((x) => x.key == key);
  }

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
    await _enqueue('video_records', () async {
      final raw = (await _read('video_records') as List?) ?? [];
      final list = raw
          .map((e) => VideoRecord.fromMap(e as Map<String, dynamic>))
          .where((e) => e.key != r.key)
          .toList();
      list.insert(0, r);
      // 新记录时间戳最大，插到最前后整表仍按时间降序。
      if (list.length > 300) list.removeRange(300, list.length);
      await _writeNow('video_records', list.map((e) => e.toMap()).toList());
    });
  }

  /// 移除一条动画观看记录。
  static Future<void> removeVideoRecord(String key) async {
    await _enqueue('video_records', () async {
      final raw = (await _read('video_records') as List?) ?? [];
      final list = raw
          .map((e) => VideoRecord.fromMap(e as Map<String, dynamic>))
          .where((e) => e.key != key)
          .toList();
      await _writeNow('video_records', list.map((e) => e.toMap()).toList());
    });
  }

  // ---- 设置 ----
  static Future<bool> darkMode() async =>
      ((await _read('settings')) as Map?)?['dark'] as bool? ?? false;

  /// 当前主题色 ID（0=墨蓝(默认), 1=东京夜, 2=翡翠绿, 3=暖橙, 4=薰衣草）。
  static Future<int> themeId() async =>
      ((await _read('settings')) as Map?)?['themeId'] as int? ?? 0;

  static Future<void> setThemeId(int v) async => _updateSetting('themeId', v);

  static Future<bool> horizontalReader() async =>
      ((await _read('settings')) as Map?)?['horizontal'] as bool? ?? false;

  /// 阅读模式（0=纵向滚动，1=单页横向，2=双页横屏平板）。
  /// 兼容迁移：未设置过 readerMode 的老用户，按旧的 horizontal 布尔映射。
  static Future<int> readerMode() async {
    final s = ((await _read('settings')) as Map?);
    if (s == null) return 0;
    final v = s['readerMode'];
    if (v is int) return v;
    return (s['horizontal'] as bool? ?? false) ? 1 : 0;
  }

  static Future<void> setReaderMode(int v) async =>
      _updateSetting('readerMode', v);

  /// 阅读器「自动裁边去白边」（true = 开启，默认关）。仅影响漫画页渲染。
  static Future<bool> trimBorder() async =>
      ((await _read('settings')) as Map?)?['trimBorder'] as bool? ?? false;

  static Future<void> setTrimBorder(bool v) async =>
      _updateSetting('trimBorder', v);

  /// 日漫 RTL 反向翻页（true = 从右往左，翻页方向取反）。
  static Future<bool> rtlReader() async =>
      ((await _read('settings')) as Map?)?['rtl'] as bool? ?? false;

  static Future<int> resLevel() async =>
      ((await _read('settings')) as Map?)?['resLevel'] as int? ?? 0;

  /// 下载画质偏好（0=原画，1=省空间压缩）。由批量下载弹窗选择，跨会话记住。
  static Future<int> downloadQuality() async =>
      ((await _read('settings')) as Map?)?['downloadQuality'] as int? ?? 0;

  static Future<void> setDownloadQuality(int v) async =>
      _updateSetting('downloadQuality', v);

  static Future<void> setDarkMode(bool v) async => _updateSetting('dark', v);

  static Future<void> setHorizontalReader(bool v) async =>
      _updateSetting('horizontal', v);

  static Future<void> setRtlReader(bool v) async => _updateSetting('rtl', v);

  static Future<void> setResLevel(int v) async => _updateSetting('resLevel', v);

  /// 自动翻页间隔（秒）；0 = 关闭。
  static Future<int> autoPageTurn() async =>
      ((await _read('settings')) as Map?)?['autoPageTurn'] as int? ?? 0;

  static Future<void> setAutoPageTurn(int seconds) async =>
      _updateSetting('autoPageTurn', seconds);

  /// 只更新单个设置键，其余设置保持不变（避免全量覆盖丢字段）。
  /// 整体走 _enqueue：并发 set* 时不会各自基于旧快照整表写回而互丢字段。
  static Future<void> _updateSetting(String key, Object? value) async {
    await _enqueue('settings', () async {
      final s = Map<String, dynamic>.from(
          ((await _read('settings')) as Map?) ?? const {});
      s[key] = value;
      await _writeNow('settings', s);
    });
  }

  /// 弹幕显示设置（开关、字号、速度、透明度）。
  static Future<DanmakuSettings> danmakuSettings() async {
    final j = ((await _read('settings')) as Map?)?['danmaku'];
    return j is Map
        ? DanmakuSettings.fromJson(Map<String, dynamic>.from(j))
        : const DanmakuSettings();
  }

  static Future<void> setDanmaku(DanmakuSettings s) async =>
      _updateSetting('danmaku', s.toJson());

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

  /// 小说段间距（px，段落之间的空白高度）。
  static Future<int> novelParagraphGap() async {
    final v = ((await _read('novel_read_settings')) as Map?)?['paragraphGap'];
    if (v is num) return v.round();
    return 18;
  }

  /// 小说首行缩进（true = 段落开头缩进 2 字符）。
  static Future<bool> novelFirstIndent() async =>
      ((await _read('novel_read_settings')) as Map?)?['firstIndent'] as bool? ??
      true;

  /// 小说色温（0~100 无级，0 = 无色温滤镜，100 = 最暖 3000K）。
  static Future<int> novelColorTemp() async {
    final v = ((await _read('novel_read_settings')) as Map?)?['colorTemp'];
    if (v is num) return v.round().clamp(0, 100);
    return 0;
  }

  static Future<void> setNovelReadSettings({
    int? fontSize,
    int? lineHeight,
    int? theme,
    int? paragraphGap,
    bool? firstIndent,
    int? colorTemp,
  }) async {
    // 与 setTtsRate 同文件：整体排队，避免各自基于旧快照写回互丢字段。
    await _enqueue('novel_read_settings', () async {
      final cur = (await _read('novel_read_settings')) as Map? ?? {};
      await _writeNow('novel_read_settings', {
        // 以旧表打底：本方法只写 6 个已知键，ttsRate 等其余键原样保留。
        ...cur,
        'fontSize': fontSize ?? cur['fontSize'] ?? 17,
        'lineHeight': lineHeight ?? cur['lineHeight'] ?? 180,
        'theme': theme ?? cur['theme'] ?? 0,
        'paragraphGap': paragraphGap ?? cur['paragraphGap'] ?? 18,
        'firstIndent': firstIndent ?? cur['firstIndent'] ?? true,
        'colorTemp': colorTemp ?? cur['colorTemp'] ?? 0,
      });
    });
  }

  /// 朗读语速倍率（0.5x~2.0x，默认 1.0）。
  static Future<double> ttsRate() async {
    final v = ((await _read('novel_read_settings')) as Map?)?['ttsRate'];
    if (v is num) return v.toDouble().clamp(0.5, 2.0);
    return 1.0;
  }

  static Future<void> setTtsRate(double rate) async {
    await _enqueue('novel_read_settings', () async {
      final cur = (await _read('novel_read_settings')) as Map? ?? {};
      await _writeNow('novel_read_settings', {
        ...cur,
        'ttsRate': rate.clamp(0.5, 2.0),
      });
    });
  }

  // ---- 阅读统计 ----
  /// 累计一段阅读时长（秒）到当天。
  /// 存储结构：reading_stats -> { "2026-08-23": 3600, ... }（按天，秒）。
  static Future<void> addReadingSeconds(int seconds) async {
    if (seconds <= 0) return;
    final day = _todayKey();
    // 读-改-写整体排进写队列，避免 _flushStats 与 dispose flush 并发时互相覆盖丢秒数。
    await _enqueue('reading_stats', () async {
      final m = (await _read('reading_stats')) as Map? ?? {};
      m[day] = ((m[day] as num?) ?? 0).toInt() + seconds;
      await _writeNow('reading_stats', m);
    });
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

  /// 最近 N 个月每月的阅读秒数（按月份升序 [{month:'2026-08', seconds}]）。
  static Future<List<Map<String, dynamic>>> recentReadingMonths(int n) async {
    final m = (await _read('reading_stats')) as Map? ?? {};
    final now = DateTime.now();
    final out = <Map<String, dynamic>>[];
    for (var i = n - 1; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final key = '${month.year}-${month.month.toString().padLeft(2, '0')}';
      var sum = 0;
      for (final entry in m.entries) {
        final d = (entry.key as String?) ?? '';
        if (d.length >= 7 && d.startsWith(key)) {
          sum += (entry.value as num?)?.toInt() ?? 0;
        }
      }
      out.add({'month': key, 'seconds': sum});
    }
    return out;
  }

  /// 指定年份的月度阅读统计（全年 12 个月升序 [{month:'2026-01', seconds}]）。
  static Future<List<Map<String, dynamic>>> yearReadingMonths(int year) async {
    final m = (await _read('reading_stats')) as Map? ?? {};
    final out = <Map<String, dynamic>>[];
    for (var mo = 1; mo <= 12; mo++) {
      final key = '$year-${mo.toString().padLeft(2, '0')}';
      var sum = 0;
      for (final entry in m.entries) {
        final d = (entry.key as String?) ?? '';
        if (d.length >= 7 && d.startsWith(key)) {
          sum += (entry.value as num?)?.toInt() ?? 0;
        }
      }
      out.add({'month': key, 'seconds': sum});
    }
    return out;
  }

  /// 指定年份的总阅读秒数；不传年份为全部累计。
  static Future<int> yearReadingSeconds([int? year]) async {
    final m = (await _read('reading_stats')) as Map? ?? {};
    var sum = 0;
    for (final entry in m.entries) {
      final d = (entry.key as String?) ?? '';
      if (year != null && !(d.length >= 4 && d.startsWith('$year'))) continue;
      sum += (entry.value as num?)?.toInt() ?? 0;
    }
    return sum;
  }

  /// 有效阅读天数（秒数 > 0）；可传年份限定。
  static Future<int> activeReadingDays([int? year]) async {
    final m = (await _read('reading_stats')) as Map? ?? {};
    var count = 0;
    for (final entry in m.entries) {
      final d = (entry.key as String?) ?? '';
      if (year != null && !(d.length >= 4 && d.startsWith('$year'))) continue;
      if (((entry.value as num?)?.toInt() ?? 0) > 0) count++;
    }
    return count;
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
    try {
      final raw = await _read('downloads');
      if (raw is! List) return [];
      return raw
          .map((e) => DownloadRecord.fromMap(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('LocalStore.downloads() error: $e');
      return [];
    }
  }

  static Future<DownloadRecord?> downloadOf(String key) async {
    for (final d in await downloads()) {
      if (d.key == key) return d;
    }
    return null;
  }

  static Future<void> upsertDownload(DownloadRecord d) async {
    await _enqueue('downloads', () async {
      final list = (await downloads()).where((x) => x.key != d.key).toList();
      list.add(d);
      await _writeNow('downloads', list.map((e) => e.toMap()).toList());
    });
  }

  static Future<void> removeDownload(String key) async {
    await _enqueue('downloads', () async {
      final list = (await downloads()).where((d) => d.key != key).toList();
      await _writeNow('downloads', list.map((e) => e.toMap()).toList());
    });
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
    // 读写整体排队：清文件期间新加入的下载记录不会被旧快照写回覆盖。
    return _enqueue('downloads', () async {
      final list = await downloads();
      final finished = list.where((d) => d.finished).toList();
      for (final d in finished) {
        await removeDownloadFiles(d);
      }
      await _writeNow('downloads',
          list.where((d) => !d.finished).map((e) => e.toMap()).toList());
      return finished.length;
    });
  }

  /// 删除单条下载记录对应的本地文件目录（章节目录），不删记录本身。
  static Future<void> removeDownloadFiles(DownloadRecord d) async {
    try {
      final base = await downloadDir();
      final cd = Directory('${base.path}/${d.localKey}');
      if (cd.existsSync()) cd.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ---- 视频续播进度 ----
  /// key=剧集 historyKey，value=播放秒数。上限 500 条，超出按最旧插入裁剪。
  static const int _videoProgressMax = 500;

  /// 读取某剧集的续播秒数（无记录返回 0）。
  static Future<int> videoProgressOf(String key) async {
    final raw = await _read('video_progress');
    if (raw is Map) return (raw[key] as num?)?.toInt() ?? 0;
    return 0;
  }

  /// 写入/清除续播进度；[seconds] 为 null 或 <=0 表示看完清除记录。
  /// 读-改-写整体排队：主播放器与小窗并发保存时不再互踩丢进度。
  static Future<void> setVideoProgress(String key, int? seconds) async {
    await _enqueue('video_progress', () async {
      final raw = await _read('video_progress');
      final map = <String, dynamic>{};
      if (raw is Map) raw.forEach((k, v) => map['$k'] = v);
      map.remove(key); // 先删再插 = 移到末尾，表头始终是 最旧（裁剪端）
      if (seconds != null && seconds > 0) {
        map[key] = seconds;
      }
      while (map.length > _videoProgressMax) {
        map.remove(map.keys.first);
      }
      await _writeNow('video_progress', map);
    });
  }

  // ---- 备份/恢复 ----

  /// 收集所有用户数据（书架/小说书架/历史/动画记录/收藏/下载清单/设置/源配置），
  /// 返回可直接 JSON 序列化的结构。下载图片文件不包含在内。
  /// 书架分类定义随备份一起导出（bookshelf 数据里的 folderId 依赖它才能还原）。
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
      'shelf_folders': await _read('shelf_folders'),
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
    await put('shelf_folders', data['shelf_folders']);
    return count;
  }

  // ---- 桌面端窗口几何（尺寸/位置记忆）----
  // 合并写入 settings，避免覆盖其它设置项。
  static Future<void> setWindowGeometry({
    double? w,
    double? h,
    double? x,
    double? y,
  }) async {
    // 与 _updateSetting 同文件：resize 与主题/设置变更并发时整体排队，互不丢字段。
    await _enqueue('settings', () async {
      final m = ((await _read('settings')) as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      if (w != null) m['winW'] = w;
      if (h != null) m['winH'] = h;
      if (x != null) m['winX'] = x;
      if (y != null) m['winY'] = y;
      await _writeNow('settings', m);
    });
  }

  /// 返回 {w,h,x,y}，无记录时返回 null。
  static Future<Map<String, double>?> windowGeometry() async {
    final m = ((await _read('settings')) as Map?)?.cast<String, dynamic>();
    if (m == null || m['winW'] == null) return null;
    return {
      'w': (m['winW'] as num).toDouble(),
      'h': (m['winH'] as num).toDouble(),
      'x': (m['winX'] as num?)?.toDouble() ?? 0,
      'y': (m['winY'] as num?)?.toDouble() ?? 0,
    };
  }
}
