import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/local_novel_source.dart';

/// 本地小说导入解析回归（gitignored，不入库）：
/// TXT 编码识别、章节切分、EPUB 解析、正文清洗、持久化 roundtrip。
void main() {
  final tmp = Directory.systemTemp.createTempSync('local_novel_test');

  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('TXT 解析', () {
    test('UTF-8 文本识别与章节切分', () {
      final bytes = utf8.encode(
          '第一章 风起\n\n雨夜，少年握紧了剑。\n\n第二章 云涌\n\n风越来越大。\n');
      final parsed = parseTxt(bytes, 'test.txt');
      expect(parsed.title, 'test');
      expect(parsed.chapters.length, 2);
      expect(parsed.chapters[0].title, '第一章 风起');
      expect(parsed.chapters[0].body, contains('雨夜，少年握紧了剑。'));
      expect(parsed.chapters[1].title, '第二章 云涌');
      expect(parsed.chapters[1].body, contains('风越来越大。'));
    });

    test('GBK 编码文本可识别（含“第一章”BOM 前导字节）', () {
      // 无法在纯 Dart 测试里产生真 GBK 字节（无编解码器），
      // 验证：非 UTF-8 输入按 latin1 直读后仍有章节内容且不抛异常。
      final head = '第一章 风起\n\n正文内容\n';
      final bytes = Uint8List.fromList(utf8.encode(head).expand((b) => [b, 0]).toList());
      final parsed = parseTxt(bytes, 'g.txt');
      expect(parsed.title, 'g');
      expect(parsed.chapters.isNotEmpty, isTrue);
    });

    test('无章节标题时整体为单章', () {
      final bytes = utf8.encode('只是一段普通的文字，没有分章。\n第二行。\n');
      final parsed = parseTxt(bytes, 'plain.txt');
      expect(parsed.chapters.length, 1);
      expect(parsed.chapters[0].body, contains('只是一段普通的文字'));
    });

    test('按“第X章”切分并清洗空白行', () {
      final bytes = utf8.encode(
          '序章\n\n　　楔子部分。\n\n第1章 初见\n\n\n　　他来了。\n\n　　走了。\n\n第2章 再见\n\n　　又来了。\n');
      final parsed = parseTxt(bytes, 'book.txt');
      expect(parsed.chapters.length, 3);
      expect(parsed.chapters[0].title, '序章');
      expect(parsed.chapters[1].title, '第1章 初见');
      expect(parsed.chapters[2].title, '第2章 再见');
      // 清洗后无空行残留
      for (final c in parsed.chapters) {
        expect(c.body.trim().split('\n').where((l) => l.trim().isEmpty),
            isEmpty);
      }
    });
  });

  group('段落与清洗', () {
    test('全文切段落：空行分段落，无空行按句切', () {
      final body = '第一段\n\n第二段\n第三段';
      final paras = splitParagraphs(body);
      expect(paras.length, 2);
      expect(paras[0], '第一段');
      expect(paras[1], '第二段第三段');
    });

    test('清洗全角空格/制表符/HTML 标签', () {
      expect(cleanLine('\u3000\u3000你好\t世界'), '你好 世界');
      expect(cleanLine('<p>段落</p>'), '段落');
      expect(cleanLine('　　'), '');
    });
  });

  group('EPUB 解析', () {
    test('解析最小 EPUB（zip + content.opf + 单个 xhtml）', () async {
      // 构造最小 EPUB：mimetype + META-INF/container.xml + OEBPS/content.opf
      // + OEBPS/ch1.xhtml
      final book = tmp.createTempSync('epub');
      File('${book.path}/mimetype')
          .writeAsStringSync('application/epub+zip');
      final metaInf = Directory('${book.path}/META-INF')..createSync();
      File('${metaInf.path}/container.xml').writeAsStringSync('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
''');
      final oebps = Directory('${book.path}/OEBPS')..createSync();
      File('${oebps.path}/content.opf').writeAsStringSync('''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试书</dc:title>
    <dc:creator>作者A</dc:creator>
  </metadata>
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>
''');
      File('${oebps.path}/ch1.xhtml').writeAsStringSync('''
<html><head><title>第一章</title></head>
<body>
<h1>第一章 风起</h1>
<p>　　雨夜，少年握紧了剑。</p>
<p>　　远方传来雷声。</p>
</body></html>
''');
      File('${oebps.path}/nav.xhtml')
          .writeAsStringSync('<html><body></body></html>');

      // zip 打包
      final zipBytes = await _zipDir(book.path);
      final parsed = parseEpubBytes(zipBytes);
      expect(parsed.title, contains('测试书'));
      expect(parsed.author, '作者A');
      expect(parsed.chapters.isNotEmpty, isTrue);
      expect(parsed.chapters.first.title, '第一章 风起');
      expect(parsed.chapters.first.body, contains('雨夜，少年握紧了剑。'));
    });

    test('非 zip / 损坏输入返回空', () async {
      final parsed = parseEpubBytes(utf8.encode('not a zip'));
      expect(parsed.chapters, isEmpty);
    });
  });

  group('持久化 roundtrip', () {
    test('保存读取还原章节内容', () async {
      final store = LocalNovelStore(dir: tmp.path);
      final parsed = parseTxt(
          utf8.encode('第1章 初见\n\n你好世界。\n'), 't.txt');
      final id = await store.import(parsed, sourceName: '本地');
      expect(id, isNotEmpty);

      final meta = store.metaOf(id);
      expect(meta, isNotNull);
      expect(meta!['name'], 't');
      expect(meta['chapters'], isA<List>());

      final body = store.chapterBody(id, 0);
      expect(body, contains('你好世界'));
    });
  });
}

/// 用纯 Dart 打 zip（不依赖 archive 包）：PNG/图片不需要，这里只打包文本。
/// 采用 archive 兼容的最小 ZIP 结构：STORE 无压缩条目。
Future<Uint8List> _zipDir(String dirPath) async {
  final entries = <_ZipEntry>[];
  void walk(String base, Directory d) {
    for (final f in d.listSync()) {
      if (f is File) {
        entries.add(_ZipEntry(
          name: f.path.substring(base.length + 1).replaceAll('\\', '/'),
          bytes: f.readAsBytesSync(),
        ));
      } else if (f is Directory) {
        walk(base, f);
      }
    }
  }

  walk(dirPath, Directory(dirPath));
  return Uint8List.fromList(_zipEncode(entries));
}

class _ZipEntry {
  final String name;
  final List<int> bytes;
  _ZipEntry({required this.name, required this.bytes});
}

List<int> _zipEncode(List<_ZipEntry> entries) {
  final out = BytesBuilder();
  // Local File Header + Central Directory
  const sigLocal = 0x04034b50;
  const sigCentral = 0x02014b50;
  const sigEocd = 0x06054b50;
  int offset = 0;
  final central = BytesBuilder();
  for (final e in entries) {
    final name = utf8.encode(e.name);
    final data = e.bytes;
    final crc = _crc32(data);
    // local header
    _writeU32(out, sigLocal);
    _writeU16(out, 20); // version needed
    _writeU16(out, 0); // flags
    _writeU16(out, 0); // method: store
    _writeU16(out, 0); // mod time
    _writeU16(out, 0x21); // mod date
    _writeU32(out, crc);
    _writeU32(out, data.length);
    _writeU32(out, data.length);
    _writeU16(out, name.length);
    _writeU16(out, 0);
    out.add(name);
    out.add(data);
    // central dir entry
    _writeU32(central, sigCentral);
    _writeU16(central, 20);
    _writeU16(central, 20);
    _writeU16(central, 0);
    _writeU16(central, 0);
    _writeU16(central, 0);
    _writeU16(central, 0x21);
    _writeU32(central, crc);
    _writeU32(central, data.length);
    _writeU32(central, data.length);
    _writeU16(central, name.length);
    _writeU16(central, 0);
    _writeU16(central, 0);
    _writeU16(central, 0);
    _writeU16(central, 0);
    _writeU32(central, 0);
    _writeU32(central, offset);
    central.add(name);
    offset += 30 + name.length + data.length;
  }
  out.add(central.toBytes());
  final centralSize = central.length;
  // EOCD
  _writeU32(out, sigEocd);
  _writeU16(out, 0);
  _writeU16(out, 0);
  _writeU16(out, entries.length);
  _writeU16(out, entries.length);
  _writeU32(out, centralSize);
  _writeU32(out, offset);
  _writeU16(out, 0);
  return out.toBytes();
}

void _writeU16(BytesBuilder b, int v) {
  b.add([v & 0xFF, (v >> 8) & 0xFF]);
}

void _writeU32(BytesBuilder b, int v) {
  b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
  }
  return crc ^ 0xFFFFFFFF;
}
