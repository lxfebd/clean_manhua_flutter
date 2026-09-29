import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';
import 'package:xingmanxia/net/error_logger.dart';
import 'package:xingmanxia/net/shelf_updater.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/sources/local_novel_source.dart';
import 'package:xingmanxia/sources/source_manager.dart';
import 'package:xingmanxia/ui/novel_reader_page.dart';

/// 小说线 P1 缺陷回归（line2）：
/// 1. local_novel_source TXT 编码识别（UTF-8 / UTF-8 BOM / UTF-16 LE|BE BOM / GBK 兜底）
/// 2. novel_reader_page 阅读历史快照语义（跳章前抓快照，防抖回调只写快照）
/// 3. shelf_updater.checkNow 遇到不存在于漫画源的 sid 不抛异常
///
/// UI 侧的刷新语义（_refreshShelf）不在此测试：需要 widget 测试基建，
/// 本次改动只做 await push 后调用 setState 的直白逻辑，走代码审阅。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmpDir;

  setUpAll(() {
    tmpDir = Directory.systemTemp.createTempSync('xm_line2_novel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmpDir.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    try {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('P1-1 TXT 编码识别', () {
    test('UTF-8 严格解码：合法字节正常切章', () {
      final bytes = utf8.encode('第1章 起\n\n你好。\n\n第2章 落\n\n再见。\n');
      final book = parseTxt(bytes, 'utf8.txt');
      expect(book.title, 'utf8');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].title, '第1章 起');
    });

    test('UTF-8 BOM 剥离：BOM 不影响章节标题正则', () {
      final bom = Uint8List.fromList(
        [0xEF, 0xBB, 0xBF]
          ..addAll(utf8.encode('第1章\n\n正文。\n')),
      );
      final book = parseTxt(bom, 'bom.txt');
      expect(book.chapters, hasLength(1));
      // BOM 剥离后首行必须是「第1章」而不是「\uFEFF第1章」——
      // 章节正则要求整行匹配，BOM 残留会让正则匹配失败、变成单章
      expect(book.chapters.first.title, '第1章');
      expect(book.chapters.first.body, contains('正文'));
    });

    test('UTF-16 LE BOM：解码后能正常切章', () {
      // UTF-16 LE：每个字符转成 2 字节（低位在前），前缀 FF FE
      final s = '第1章\n\n你好。\n';
final bytes = Uint8List.fromList([0xFF, 0xFE]
        ..addAll(s.codeUnits.map((u) => [u & 0xFF, (u >> 8) & 0xFF]).expand((e) => e)));
      final book = parseTxt(bytes, 'le.txt');
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '第1章');
      expect(book.chapters.first.body, contains('你好'));
    });

    test('UTF-16 BE BOM：解码后能正常切章', () {
      final s = '第1章\n\n你好。\n';
final bytes = Uint8List.fromList([0xFE, 0xFF]
        ..addAll(s.codeUnits.map((u) => [(u >> 8) & 0xFF, u & 0xFF]).expand((e) => e)));
      final book = parseTxt(bytes, 'be.txt');
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '第1章');
      expect(book.chapters.first.body, contains('你好'));
    });

    test('GBK 高位字节：走 latin1 兜底不崩溃', () {
      // 构造"疑似 GBK"字节：中文在 GBK 里两字节，高位 0x80-0xFF 大量出现。
      // 无法在纯 Dart 测试里产生真 GBK，用高位字节序列模拟 latin1 特征。
      final gbkish = Uint8List.fromList([
        0xB1, 0xA8, 0xD2, 0xBB, 0x0A, // "第章" 伪 GBK 首字节
        0x0A, 0x30, 0x31, 0x32, 0x0A, // 空行 + ASCII
        0xB0, 0xE6, 0xD0, 0xC4, 0x0A,
      ]);
      // 走兜底路径不抛异常即可；正文按 latin1 直读会有 \u00XX 高位字符，
      // 但至少 decode 不崩溃、章节切分逻辑能跑完。
      final book = parseTxt(gbkish, 'gbk.txt');
      expect(book, isNotNull);
      // ErrorLogger 已记录一次 warn（测试环境进 buffer）
      expect(ErrorLogger.instance.debugBuffer().where((l) => l.contains('GBK')).length,
          greaterThan(0));
    });

    test('非法 UTF-8 字节：走 latin1 兜底且不抛异常', () {
      // 一个明显的非法 UTF-8 字节（孤立 0xC3 后跟 ASCII 0x28）
      // latin1 解码后正文是 "Ã(hi"，无法匹配中文章节正则，返回空章节——
      // 验证 decode 不崩溃、解析流程能走完即可。
      final bytes = Uint8List.fromList([0xC3, 0x28, 0x0A, 0x68, 0x69]);
      final book = parseTxt(bytes, 'bad.txt');
      expect(book, isNotNull);
    });
  });

  group('P1-3 阅读历史快照语义', () {
    test('snapshotHistoryEntry 快照语义：参数决定输出，不读外部状态', () {
      // 快照在调用时固化：先构造 snapshot1，再传入不同的 chapterId，
      // 生成的 snapshot2 与 snapshot1 完全独立——证明防抖回调不会重读 live 状态。
      final snap1 = snapshotHistoryEntry(
        sourceId: 'src',
        novelId: 'novel-1',
        novelName: '小说名',
        novelPic: '',
        novelAuthor: '作者',
        chapterId: 'ch-1',
        chapterTitle: '第一章',
        scrollOffset: 1234.5,
      );
      final snap2 = snapshotHistoryEntry(
        sourceId: 'src',
        novelId: 'novel-1',
        novelName: '小说名',
        novelPic: '',
        novelAuthor: '作者',
        chapterId: 'ch-2',
        chapterTitle: '第二章',
        scrollOffset: 0,
      );

      // 快照 1 保持自己的值，不被快照 2 覆盖
      expect(snap1.chapterId, 'ch-1');
      expect(snap1.scrollOffset, 1234.5);
      expect(snap1.book.sourceId, 'src');
      expect(snap1.book.comicId, 'novel-1');
      expect(snap1.book.name, '小说名');
      expect(snap1.timestamp, 0, reason: '时间戳由写盘时补齐，快照里留 0');

      // 快照 2 独立构造，与快照 1 无关
      expect(snap2.chapterId, 'ch-2');
      expect(snap2.scrollOffset, 0);
    });
  });

  group('P1-4 shelf_updater.checkNow 未注册 sid', () {
    late File shelfFile;
    late File folderFile;

    setUp(() async {
      shelfFile = File('${tmpDir.path}/bookshelf.json');
      folderFile = File('${tmpDir.path}/data/shelf_folders.json');
      if (folderFile.existsSync()) folderFile.deleteSync();
      if (shelfFile.existsSync()) shelfFile.deleteSync();
      // 用空文件初始化书架
      await shelfFile.writeAsString('{}');
      BookshelfStore.bindFile(shelfFile);
      ErrorLogger.instance.debugReset();
    });

    test('未注册的小说 sid 加书架后：checkNow 不抛异常', () async {
      // 用不存在的 sid（novel-sid-not-registered）：byId 兜底回 current，
      // 但 src.id != sid，因此修复后的 checkOne 直接 return。
      final d = ComicDetail(
        ComicItem('novel-x', '本地小说X', ''),
        const <Chapter>[],
        sourceId: 'novel-sid-not-registered',
      );
      BookshelfStore.add('novel-sid-not-registered', d);
      expect(BookshelfStore.listAll(), isNotEmpty);

      // 不抛异常即通过；同时应有一条 warn 日志记录"跳过"
      final result = await ShelfUpdater.checkNow();
      expect(result, isNot(null));
      final warnings = ErrorLogger.instance.debugBuffer()
          .where((l) => l.contains('novel-sid-not-registered') && l.contains('跳过'))
          .length;
      expect(warnings, greaterThan(0),
          reason: '未注册 sid 应记录 warn 说明被跳过');
    });
  });
}
