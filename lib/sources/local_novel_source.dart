import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models/comic_item.dart';
import 'novel_source.dart';
import 'source_config.dart';

/// 本地 TXT/EPUB 导入的解析结果：书名/作者 + 章节列表（含正文）。
class LocalNovelBook {
  final String title;
  final String author;
  final String description;
  final List<LocalNovelChapter> chapters;
  LocalNovelBook({
    required this.title,
    this.author = '',
    this.description = '',
    required this.chapters,
  });
}

/// 本地小说章节：body 为清洗后的原文。
class LocalNovelChapter {
  final String title;
  final String body;
  LocalNovelChapter({required this.title, required this.body});
}

/// 本地小说源：读取「本地导入」的小说（TXT/EPUB），走统一 NovelSource 契约。
///
/// 章节正文不存数据库：按 bookId 存到应用目录 `novel_imports/{bookId}/`，
/// book.json（元信息）+ chapters/{seq}.txt（正文），读时惰性加载。
/// 章节 id 采用 `"{bookId}|{seq}"` 复合格式（与 biquge 的 `novelId|cid` 对齐），
/// chapterContent 只凭 chapterId 就能定位到书与章。
class LocalNovelSource extends NovelSource {
  static const String sourceId = 'local';

  static LocalNovelStore? _store;
  static LocalNovelStore get store =>
      _store ??= LocalNovelStore(dir: _defaultDir());

  static String _defaultDir() {
    // 真实路径由 main.dart 启动时 setStoreDir 覆盖；此处仅作可回退值。
    return p.join(Directory.systemTemp.path, 'novel_imports');
  }

  /// 供 main.dart 启动时绑定真实目录（应用支持目录下）。
  static void setStoreDir(String dir) {
    _store = LocalNovelStore(dir: dir);
  }

  @override
  String get id => sourceId;
  @override
  String get name => '本地导入';
  @override
  SourceTier get tier => SourceTier.fallback;
  @override
  bool get isEnabled => true;

  @override
  Future<List<Category>> categories() async => const [];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async =>
      const [];

  @override
  Future<List<ComicItem>> rank(int page) async => const [];

  @override
  Future<List<ComicItem>> search(String keyword, int page) async => const [];

  @override
  Future<NovelDetail> detail(String novelId) async {
    final meta = store.metaOf(novelId);
    if (meta == null) {
      throw Exception('本地书不存在或已删除');
    }
    final comic = ComicItem(novelId, meta['name'] as String, '')
      ..author = (meta['author'] as String?) ?? '';
    final chapters = <NovelChapter>[
      for (final c in (meta['chapters'] as List? ?? []))
        NovelChapter(
          // 复合 id：书 id | 章序号，让阅读器/详情页只凭 chapterId 即可取正文
          '$novelId|${(c as Map)['seq']}',
          (c['title'] as String?) ?? '',
          index: (c['seq'] as int?) ?? 0,
        ),
    ];
    return NovelDetail(
      comic,
      chapters,
      author: comic.author,
      description: (meta['description'] as String?) ?? '',
      sourceId: sourceId,
    );
  }

  @override
  Future<NovelContent> chapterContent(String chapterId) async {
    final (bookId, seq) = _parseChapterId(chapterId);
    final meta = store.metaOf(bookId);
    if (meta == null) {
      throw Exception('章节内容不存在');
    }
    final chapters = (meta['chapters'] as List? ?? []);
    final title = seq < chapters.length
        ? ((chapters[seq] as Map)['title'] as String?) ?? ''
        : '';
    final body = store.chapterBody(bookId, seq) ?? '';
    return NovelContent(
      chapterId,
      title,
      splitParagraphs(body),
      prevChapterId: seq > 0 ? '$bookId|${seq - 1}' : null,
      nextChapterId: seq + 1 < chapters.length ? '$bookId|${seq + 1}' : null,
    );
  }

  /// 复合 id 拆解："{bookId}|{seq}"。
  static (String, int) _parseChapterId(String chapterId) {
    final i = chapterId.lastIndexOf('|');
    if (i < 0) return (chapterId, 0);
    return (chapterId.substring(0, i), int.tryParse(chapterId.substring(i + 1)) ?? 0);
  }

  // ── 导入入口（由 UI 调用）──

  /// 解析 TXT 字节（UTF-8 优先，失败回落 latin1 直读保底）并入库。
  static Future<String> importTxtBytes(
    Uint8List bytes,
    String fileName, {
    String? overrideTitle,
  }) async {
    final book = await Isolate.run(() => parseTxt(bytes, fileName));
    return store.import(
      LocalNovelBook(
        title: overrideTitle?.trim().isNotEmpty == true
            ? overrideTitle!.trim()
            : book.title,
        author: book.author,
        chapters: book.chapters,
      ),
      sourceName: 'TXT',
    );
  }

  /// 解析 EPUB 字节并入库（解包+XHTML 解析在独立 isolate 完成）。
  static Future<String> importEpubBytes(
    Uint8List bytes, {
    String? overrideTitle,
  }) async {
    final book = await Isolate.run(() => parseEpubBytes(bytes));
    return store.import(
      LocalNovelBook(
        title: overrideTitle?.trim().isNotEmpty == true
            ? overrideTitle!.trim()
            : book.title,
        author: book.author,
        description: book.description,
        chapters: book.chapters,
      ),
      sourceName: 'EPUB',
    );
  }
}

// ═══════════════════ TXT 解析 ═══════════════════

/// 章节标题正则：序章/楔子（须整行）/第X[章节回/卷]/Chapter N（行首）。
/// 注意：Dart RegExp 默认 ASCII 模式，`\b` 在中文与非词字符之间不成立，
/// 因此用 `^` + 可选的标题尾缀 + 行尾 `$` 锚定，不依赖词边界。
final RegExp _chapterTitleRe = RegExp(
  r'^(?:序\s*章$|楔\s*子$|第[0-9零一二三四五六七八九十百千万两]+\s*[章节回卷篇][^\n]{0,40}$|'
  r'[Cc][Hh][Aa][Pp][Tt][Ee][Rr]\s*[0-9IVXLCDMivxlcdm]+[^\n]{0,40}$)',
  multiLine: true,
);

final RegExp _tagRe = RegExp(r'<[^>]+>');
final RegExp _nbspRe =
    RegExp(r'&nbsp;|&#160;|&emsp;|&ensp;', caseSensitive: false);
final RegExp _spaceRunRe = RegExp(r' {2,}');

/// 清洗单行：去 HTML 标签、全角空格缩进、制表符、常见实体，去首尾空白，
/// 折叠行内连续空白为单个空格。
String cleanLine(String line) {
  var s = line
      .replaceAll(_nbspRe, ' ')
      .replaceAll(_tagRe, '')
      .replaceAll('\u3000', ' ')
      .replaceAll('\t', ' ')
      .trim();
  s = s.replaceAll(_spaceRunRe, ' ');
  return s;
}

/// 把正文切成展示段落：空行分段；无空行时按句末标点切（保留标点）。
List<String> splitParagraphs(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return const [];
  final blocks = <String>[];
  final cur = <String>[];
  for (final raw in trimmed.split('\n')) {
    final l = cleanLine(raw);
    if (l.isEmpty) {
      if (cur.isNotEmpty) {
        blocks.add(cur.join(''));
        cur.clear();
      }
    } else {
      cur.add(l);
    }
  }
  if (cur.isNotEmpty) blocks.add(cur.join(''));
  if (blocks.isNotEmpty) return blocks;
  // 无空行：按句切
  final parts = trimmed.split(RegExp(r'(?<=[。！？；])'));
  final res = <String>[];
  var buf = '';
  for (final part in parts) {
    buf += part;
    final hasPunct = part.contains('。') ||
        part.contains('！') ||
        part.contains('？') ||
        part.contains('；');
    if (buf.trim().length >= 60 && hasPunct) {
      res.add(buf.trim());
      buf = '';
    }
  }
  if (buf.trim().isNotEmpty) res.add(buf.trim());
  return res.isNotEmpty ? res : [trimmed];
}

/// 解析 TXT 字节：编码识别（UTF-8 优先）→ 章节切分 → 清洗。
LocalNovelBook parseTxt(Uint8List bytes, String fileName) {
  final text = _decodeText(bytes);
  final lines = text.split('\n');
  final title = fileName.replaceAll(RegExp(r'\.(txt|TXT)$'), '');
  // 收集章节标题行位置
  final starts = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim().isEmpty) continue;
    if (_chapterTitleRe.hasMatch(lines[i].trim())) starts.add(i);
  }
  final chapters = <LocalNovelChapter>[];
  if (starts.isEmpty) {
    final b = _joinLines(lines, 0, lines.length).trim();
    if (b.isNotEmpty) {
      chapters.add(LocalNovelChapter(title: title, body: b));
    }
  } else {
    final pre = _joinLines(lines, 0, starts.first).trim();
    if (pre.isNotEmpty) {
      chapters.add(LocalNovelChapter(title: '前言', body: pre));
    }
    for (var k = 0; k < starts.length; k++) {
      final begin = starts[k];
      final end = k + 1 < starts.length ? starts[k + 1] : lines.length;
      final body = _joinLines(lines, begin + 1, end).trim();
      if (body.isEmpty) continue;
      chapters.add(
          LocalNovelChapter(title: cleanLine(lines[begin]), body: body));
    }
  }
  return LocalNovelBook(title: title, chapters: chapters);
}

String _joinLines(List<String> lines, int from, int to) {
  final buf = StringBuffer();
  for (var i = from; i < to; i++) {
    final l = cleanLine(lines[i]);
    if (l.isNotEmpty) {
      buf.write(l);
      buf.write('\n');
    }
  }
  return buf.toString();
}

/// 编码识别：UTF-8 严格解码；失败回落 latin1（GBK 等中文至少可导入，
/// 章节标题中文正则仍可用；真正 GBK 转码后续可引入 charset 包增强）。
String _decodeText(Uint8List bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

// ═══════════════════ EPUB 解析 ═══════════════════

/// 解析 EPUB 字节：解 zip → container.xml → content.opf → spine 顺序读章节。
/// 不校验 mimetype；找不到有效结构返回空章节列表。
LocalNovelBook parseEpubBytes(Uint8List bytes) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return LocalNovelBook(title: '', chapters: const []);
  }
  if (archive.isEmpty) return LocalNovelBook(title: '', chapters: const []);

  String? opfPath;
  for (final f in archive.files) {
    if (f.isFile && f.name.endsWith('container.xml')) {
      final m = RegExp(r'full-path="([^"]+\.opf)"').firstMatch(_readZipText(f));
      if (m != null) {
        opfPath = _normalizeEpubPath(m.group(1)!);
        break;
      }
    }
  }
  opfPath ??= _firstOpfPath(archive);
  if (opfPath == null) return LocalNovelBook(title: '', chapters: const []);

  final opfDir = p.dirname(opfPath);
  final opfXml = _readZipContent(archive, opfPath);
  if (opfXml == null) return LocalNovelBook(title: '', chapters: const []);

  var title = _firstXmlText(opfXml, r'<dc:title[^>]*>([^<]*)</dc:title>');
  final author = _firstXmlText(opfXml, r'<dc:creator[^>]*>([^<]*)</dc:creator>');
  final description =
      _firstXmlText(opfXml, r'<dc:description[^>]*>([^<]*)</dc:description>');

  // manifest: id → href（相对 opf 目录）
  final manifest = <String, String>{};
  for (final m in RegExp(r'<item\b[^>]*>', caseSensitive: false)
      .allMatches(opfXml)) {
    final tag = m.group(0)!;
    final idm = RegExp(r'id="([^"]+)"', caseSensitive: false).firstMatch(tag);
    final hrefm =
        RegExp(r'href="([^"]+)"', caseSensitive: false).firstMatch(tag);
    if (idm != null && hrefm != null) {
      manifest[idm.group(1)!] =
          _normalizeEpubPath(p.join(opfDir, _stripFragment(hrefm.group(1)!)));
    }
  }

  // spine 顺序
  final spineOrder = <String>[];
  for (final m in RegExp(r'<itemref\b[^>]*>', caseSensitive: false)
      .allMatches(opfXml)) {
    final idref =
        RegExp(r'idref="([^"]+)"', caseSensitive: false).firstMatch(m.group(0)!);
    if (idref != null) spineOrder.add(idref.group(1)!);
  }

  final chapters = <LocalNovelChapter>[];
  for (final idref in spineOrder) {
    final href = manifest[idref];
    if (href == null) continue;
    final xhtml = _readZipContent(archive, href);
    if (xhtml != null) _parseXhtmlChapter(xhtml, chapters);
  }
  if (chapters.isEmpty) {
    // spine 空/无法解析：opf 同目录所有 xhtml 按文件名序兜底
    final names = archive.files
        .where((f) =>
            f.isFile && (f.name.endsWith('.xhtml') || f.name.endsWith('.html')))
        .map((f) => f.name)
        .toList()
      ..sort();
    for (final n in names) {
      final xhtml = _readZipContent(archive, n);
      if (xhtml != null) _parseXhtmlChapter(xhtml, chapters);
    }
  }
  if (title.isEmpty) title = 'EPUB 导入';
  return LocalNovelBook(
      title: title, author: author, description: description, chapters: chapters);
}

String? _firstOpfPath(Archive archive) {
  for (final f in archive.files) {
    if (f.isFile && f.name.endsWith('.opf')) return f.name;
  }
  return null;
}

String _firstXmlText(String xml, String pattern) {
  final m = RegExp(pattern, caseSensitive: false).firstMatch(xml);
  return m == null ? '' : _unescapeXml(m.group(1)!).trim();
}

/// 解析单个 XHTML：`<h1/h2/h3>` 起新章，`<p>` 并入当前章正文。
void _parseXhtmlChapter(String xhtml, List<LocalNovelChapter> out) {
  var text = xhtml.replaceAll(
      RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
  text = text.replaceAll(
      RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '');
  final blockRe = RegExp(
      r'<h[123][^>]*>([\s\S]*?)</h[123]>|<p[^>]*>([\s\S]*?)</p>'
      r'|<div[^>]*>([\s\S]*?)</div>',
      caseSensitive: false);
  var seq = out.length;
  final buf = <String>[];
  String? curTitle;

  void flush() {
    final t = curTitle;
    if (t == null) return;
    final body = buf.join('\n').trim();
    if (body.isEmpty) return;
    out.add(LocalNovelChapter(title: t, body: body));
    buf.clear();
  }

  for (final m in blockRe.allMatches(text)) {
    var isHeading = false;
    var content = '';
    if (m.group(0)!.startsWith('<h')) {
      isHeading = true;
      content = m.group(1) ?? '';
    } else {
      content = m.group(2) ?? m.group(3) ?? '';
    }
    final cleaned = cleanLine(_stripTagsInline(content));
    if (cleaned.isEmpty) continue;
    if (isHeading) {
      flush();
      curTitle = cleaned;
    } else {
      // div 内可能含多个 p / br，拆行
      final inner = content.replaceAll(
          RegExp(r'</p>|<br\s*/?>', caseSensitive: false), '\n');
      for (final l in inner.split('\n')) {
        final c = cleanLine(l);
        if (c.isNotEmpty) buf.add(c);
      }
    }
  }
  flush();
  // 整页无标题：正文作为一章
  if (out.length == seq && buf.isNotEmpty) {
    out.add(LocalNovelChapter(title: '正文', body: buf.join('\n')));
  }
}

String _stripTagsInline(String s) =>
    s.replaceAll(_tagRe, '').replaceAll('\u3000', ' ').trim();

String _unescapeXml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _stripFragment(String href) {
  final i = href.indexOf('#');
  return i >= 0 ? href.substring(0, i) : href;
}

String? _readZipContent(Archive archive, String path) {
  final key = path.startsWith('/') ? path.substring(1) : path;
  for (final f in archive.files) {
    if (f.isFile && f.name == key) {
      try {
        return _readZipText(f);
      } catch (_) {
        return null;
      }
    }
  }
  return null;
}

String _readZipText(ArchiveFile f) {
  final bytes = f.content;
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    try {
      return latin1.decode(bytes);
    } catch (_) {
      return '';
    }
  }
}

String _normalizeEpubPath(String path) {
  var s = Uri.decodeComponent(path);
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  return s;
}

// ═══════════════════ 本地存储 ═══════════════════

/// 本地小说持久化：`{dir}/{bookId}/book.json` + `chapters/{seq}.txt`。
/// 正文是大文本，独立文件存读，不混入 LocalStore 全局 JSON。
class LocalNovelStore {
  final String dir;
  LocalNovelStore({required this.dir});

  String _bookDir(String bookId) => p.join(dir, bookId);

  String _metaPath(String bookId) => p.join(_bookDir(bookId), 'book.json');

  String _chapterPath(String bookId, int seq) =>
      p.join(_bookDir(bookId), 'chapters', '$seq.txt');

  /// 唯一 bookId：毫秒时间戳 + 微秒低位，避免同名覆盖。
  static String nextBookId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rnd =
        (DateTime.now().microsecondsSinceEpoch & 0xFFFFF).toRadixString(16);
    return '$ts$rnd';
  }

  /// 入库：写章节文件 + book.json。返回 bookId。
  Future<String> import(LocalNovelBook book, {required String sourceName}) async {
    final id = nextBookId();
    final bookDir = _bookDir(id);
    await Directory(p.join(bookDir, 'chapters')).create(recursive: true);
    final chapters = <Map<String, dynamic>>[];
    for (var i = 0; i < book.chapters.length; i++) {
      final ch = book.chapters[i];
      await File(_chapterPath(id, i)).writeAsString(ch.body, flush: true);
      chapters.add({'seq': i, 'title': ch.title});
    }
    await File(_metaPath(id)).writeAsString(
      jsonEncode({
        'id': id,
        'name': book.title,
        'pic': '',
        'author': book.author,
        'description': book.description,
        'sourceName': sourceName,
        'importedAt': DateTime.now().millisecondsSinceEpoch,
        'chapters': chapters,
      }),
      flush: true,
    );
    return id;
  }

  /// 元信息（不含正文）。不存在返回 null。
  Map<String, dynamic>? metaOf(String bookId) {
    final f = File(_metaPath(bookId));
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 单章正文。不存在返回 null。
  String? chapterBody(String bookId, int seq) {
    final f = File(_chapterPath(bookId, seq));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  /// 列出全部本地书（元信息，按导入时间倒序）。
  List<Map<String, dynamic>> listAll() {
    final rootDir = Directory(dir);
    if (!rootDir.existsSync()) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in rootDir.listSync()) {
      if (e is! Directory) continue;
      final meta = metaOf(p.basename(e.path));
      if (meta != null) out.add(meta);
    }
    out.sort((a, b) =>
        ((b['importedAt'] as int?) ?? 0).compareTo((a['importedAt'] as int?) ?? 0));
    return out;
  }

  /// 删除本地书（含目录）。
  Future<void> remove(String bookId) async {
    final d = Directory(_bookDir(bookId));
    if (d.existsSync()) {
      await d.delete(recursive: true);
    }
  }
}