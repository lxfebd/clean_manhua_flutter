import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

/// LocalStore.removeHistoryEntry 单测：按 book.key 精确删除单条历史。
/// 历史模型是「每书一条（最新覆盖）」，key = book.key（sourceId/comicId），
/// 与 recordHistory 的去重语义一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_rm_history');
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
    LocalStore.resetForTest();
    await LocalStore.init();
  });

  tearDown(() async {
    if (tmpDir.existsSync()) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  HistoryEntry entry(String comicId, String chapterId, {int ts = 0}) =>
      HistoryEntry(
        book: Bookmark(
            sourceId: 'src', comicId: comicId, name: comicId, pic: ''),
        chapterId: chapterId,
        chapterTitle: '第$chapterId话',
        timestamp: ts,
        pageIndex: 0,
        chapterTotalPages: 10,
        scrollOffset: 0,
      );

  test('删除单条：仅移除目标书，其余书保留', () async {
    await LocalStore.recordHistory(entry('a', 'c1', ts: 300));
    await LocalStore.recordHistory(entry('b', 'c1', ts: 100));
    await LocalStore.removeHistoryEntry(entry('a', 'c1', ts: 300));
    final left = await LocalStore.history();
    expect(left.length, 1);
    expect(left.single.book.comicId, 'b');
  });

  test('同书多次记录只留最新一条（key 同覆盖），删除后为空', () async {
    await LocalStore.recordHistory(entry('a', 'c1', ts: 100));
    await LocalStore.recordHistory(entry('a', 'c2', ts: 200));
    final all = await LocalStore.history();
    expect(all.length, 1);
    expect(all.single.chapterId, 'c2'); // 最新覆盖旧章节
    await LocalStore.removeHistoryEntry(entry('a', 'c1', ts: 100));
    expect(await LocalStore.history(), isEmpty);
  });

  test('删除不存在的 key：列表不变', () async {
    await LocalStore.recordHistory(entry('a', 'c1', ts: 100));
    await LocalStore.removeHistoryEntry(entry('x', 'nope'));
    final left = await LocalStore.history();
    expect(left.length, 1);
    expect(left.single.book.comicId, 'a');
  });

  test('跨源同名 comicId 互不影响（key 含 sourceId）', () async {
    await LocalStore.recordHistory(entry('a', 'c1', ts: 100));
    await LocalStore.recordHistory(HistoryEntry(
      book: const Bookmark(
          sourceId: 'src2', comicId: 'a', name: 'a2', pic: ''),
      chapterId: 'c1',
      chapterTitle: '第c1话',
      timestamp: 200,
      pageIndex: 0,
      chapterTotalPages: 10,
      scrollOffset: 0,
    ));
    await LocalStore.removeHistoryEntry(entry('a', 'c1', ts: 100));
    final left = await LocalStore.history();
    expect(left.length, 1);
    expect(left.single.book.sourceId, 'src2');
  });

  test('删除后剩余记录保持时间倒序', () async {
    await LocalStore.recordHistory(entry('a', 'c1', ts: 300));
    await LocalStore.recordHistory(entry('b', 'c1', ts: 200));
    await LocalStore.recordHistory(entry('c', 'c1', ts: 100));
    await LocalStore.removeHistoryEntry(entry('b', 'c1', ts: 200));
    final left = await LocalStore.history();
    // a 最新（ts 300）在前，c（ts 100）在后：history() 按时间倒序。
    expect(left.map((h) => h.book.comicId).toList(), ['a', 'c']);
  });
}
