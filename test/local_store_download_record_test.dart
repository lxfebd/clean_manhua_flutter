import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_dlrecord');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmp.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DownloadRecord rec({
    required String comicId,
    required String chapterId,
    required bool finished,
    String? error,
  }) =>
      DownloadRecord(
        book: Bookmark(
          sourceId: 'src',
          comicId: comicId,
          name: '漫画$comicId',
          pic: '',
        ),
        chapterId: chapterId,
        chapterTitle: '第$chapterId话',
        total: 10,
        done: finished ? 10 : 0,
        finished: finished,
        localKey: 'src/$comicId/$chapterId',
        error: error,
      );

  test('error 字段序列化往返：失败原因跨存储保留', () async {
    await LocalStore.init();
    final r = rec(comicId: 'c1', chapterId: '7', finished: true, error: '磁盘空间不足，请清理后重试');
    await LocalStore.upsertDownload(r);
    final got = await LocalStore.downloadOf(r.key);
    expect(got, isNotNull);
    expect(got!.error, '磁盘空间不足，请清理后重试');
    expect(got.finished, isTrue);
  });

  test('旧记录无 error 字段：读取兼容为 null', () async {
    await LocalStore.init();
    // 手写旧版 JSON（无 error 键），模拟历史数据。
    final legacy = rec(comicId: 'legacy', chapterId: '1', finished: true);
    final raw = legacy.toMap()..remove('error');
    await LocalStore.upsertDownload(_fromMap(raw));
    final got = await LocalStore.downloadOf(legacy.key);
    expect(got, isNotNull);
    expect(got!.error, isNull);
    expect(got.finished, isTrue);
  });

  test('下载表超上限：优先裁剪已完成的最旧记录，保留失败/进行中', () async {
    await LocalStore.init();
    // 塞 205 条：200 条已完成 + 5 条失败（未 finished）。
    for (var i = 0; i < 200; i++) {
      await LocalStore.upsertDownload(
          rec(comicId: 'done$i', chapterId: '1', finished: true));
    }
    final failed = <String>[];
    for (var i = 0; i < 5; i++) {
      final key = 'fail$i';
      failed.add(key);
      await LocalStore.upsertDownload(
          rec(comicId: key, chapterId: '1', finished: false));
    }
    // 再插几条已完成触发裁剪。
    final extra = <String>[];
    for (var i = 0; i < 10; i++) {
      final key = 'extra$i';
      extra.add(key);
      await LocalStore.upsertDownload(
          rec(comicId: key, chapterId: '1', finished: true));
    }
    final all = await LocalStore.downloads();
    expect(all.length, lessThanOrEqualTo(200));
    // 失败/进行中全部保留。
    for (final k in failed) {
      expect(all.any((d) => d.book.comicId == k), isTrue, reason: '失败记录 $k 应保留');
    }
    // 最旧的已完成（done0-doneN）应被裁掉，最新 extra 保留。
    expect(all.any((d) => d.book.comicId == 'done0'), isFalse,
        reason: '最旧已完成应被裁剪');
    expect(all.any((d) => d.book.comicId == 'extra9'), isTrue,
        reason: '最新记录应保留');
  });
}

DownloadRecord _fromMap(Map<String, dynamic> m) => DownloadRecord(
      book: Bookmark.fromMap(m),
      chapterId: m['chapterId'] as String,
      chapterTitle: m['chapterTitle'] as String,
      total: m['total'] as int,
      done: m['done'] as int,
      finished: m['finished'] as bool,
      localKey: m['localKey'] as String,
    );