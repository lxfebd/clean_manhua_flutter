import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/download_manager.dart';
import 'package:xingmanxia/net/local_store.dart';

/// 回归：第8轮「下载任务 per-key 取消」（commit 69d7a4c）。
///
/// 覆盖语义：
/// - [DownloadManager.cancelTask]/[isTaskCancelled]：单任务取消标记，
///   只影响该 key 的在途下载，不干扰其它任务；
/// - 任务开始前被取消（书架取消按钮抢先按下）：消费旧标记，
///   不落开始记录直接返回 fail('已取消')，且不落任何 finished 记录；
/// - 运行中取消：中断循环，报「已取消」（限定 done < total）；
/// - [DownloadManager.cancelAll] 清空全部单任务标记：不误取消新任务；
/// - 新任务不继承旧取消标记（消费 remove）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_task_cancel');
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

  const book = Bookmark(
      sourceId: 'src', comicId: 'c1', name: '漫画', pic: '', author: '');

  String taskKeyOf(String chapterId) => 'src/c1/$chapterId';

  /// 下载记录表（downloadOf）用 `sourceId::comicId::chapterId` 格式。
  String recordKeyOf(String chapterId) => '${book.key}::$chapterId';

  setUp(() async {
    await LocalStore.init();
    DownloadManager.cancelAll(); // 清空单任务标记 + 重置代际 token
  });

  test('cancelTask 只标记该 key，其它 key 不受影响', () {
    DownloadManager.cancelTask(taskKeyOf('ch1'));
    expect(DownloadManager.isTaskCancelled(taskKeyOf('ch1')), isTrue);
    expect(DownloadManager.isTaskCancelled(taskKeyOf('ch2')), isFalse);
  });

  test('任务开始前已取消：消费标记，落失败记录，不落开始记录', () async {
    // 预置「已取消」标记（模拟书架取消按钮抢在任务启动前按下）。
    DownloadManager.cancelTask(taskKeyOf('ch1'));
    final r = await DownloadManager.downloadChapter(
      batchGen: DownloadManager.beginBatch(),
      book: book,
      chapterId: 'ch1',
      chapterTitle: '第1话',
      urls: ['http://127.0.0.1:1/1.jpg'],
    );
    expect(r.ok, isFalse);
    expect(r.error, '已取消');
    final d = await LocalStore.downloadOf(recordKeyOf('ch1'));
    expect(d, isNotNull);
    expect(d!.error, '已取消');
    expect(d.done, 0);
    expect(d.finished, isFalse);
    // 旧标记被消费：新任务不再继承取消状态。
    expect(DownloadManager.isTaskCancelled(taskKeyOf('ch1')), isFalse);
  });

  test('运行中取消：中断下载，报「已取消」且 done < total', () async {
    final key = taskKeyOf('ch2');
    // 任务启动后立即取消（runInBackground 不 await，先让标记消费执行）。
    final f = DownloadManager.downloadChapter(
      batchGen: DownloadManager.beginBatch(),
      book: book,
      chapterId: 'ch2',
      chapterTitle: '第2话',
      urls: ['unused0', 'unused1'],
    );
    DownloadManager.cancelTask(key);
    final r = await f;
    expect(r.ok, isFalse);
    expect(r.error, '已取消');
    final d = await LocalStore.downloadOf(recordKeyOf('ch2'));
    expect(d, isNotNull);
    expect(d!.error, '已取消');
    expect(d.finished, isFalse);
  });

  test('cancelAll 清空单任务标记：新任务不误取消', () {
    DownloadManager.cancelTask(taskKeyOf('ch1'));
    DownloadManager.cancelAll();
    expect(DownloadManager.isTaskCancelled(taskKeyOf('ch1')), isFalse);
  });

  test('批内多章取消互不串扰：取消 ch1 不影响 ch2 完成', () async {
    final key2 = taskKeyOf('ch2b');
    // ch2 本地图预写，任务能真正完成。
    await File(await LocalStore.localImagePath(key2, 0)).create(recursive: true);
    await File(await LocalStore.localImagePath(key2, 1)).create(recursive: true);
    final f2 = DownloadManager.downloadChapter(
      batchGen: DownloadManager.beginBatch(),
      book: book,
      chapterId: 'ch2b',
      chapterTitle: '第2话B',
      urls: ['unused0', 'unused1'],
    );
    DownloadManager.cancelTask(taskKeyOf('ch1x'));
    final r2 = await f2;
    expect(r2.ok, isTrue, reason: '取消别的 key 不应影响本任务');
    final d2 = await LocalStore.downloadOf(recordKeyOf('ch2b'));
    expect(d2, isNotNull);
    expect(d2!.finished, isTrue);
  });
}