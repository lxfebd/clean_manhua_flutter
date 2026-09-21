import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/ui/bookshelf_page.dart';

/// 回归：书架下载「重试 N」排除进行中任务（commit 69d7a4c）。
///
/// _failedManga = `!finished && total > 0 && done >= total`：
/// - 进行中任务（done < total）不算失败，不重复启动下载、不虚高 N；
/// - 失败任务（未 finished 且 done >= total）计入「重试 N」。
///
/// 书架 reload() 走真实文件 IO，fake-async 测试 zone 里不推进：
/// 所有文件 IO（LocalStore 初始化/写下载记录/书架 reload）都须在
/// tester.runAsync（真实事件循环）里等待完成，否则 testWidgets 挂死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_bookshelf_failed');
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
    // 允许失败：上一轮超时可能残留文件句柄，不影响本次结果。
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  DownloadRecord rec({
    required String comicId,
    required String chapterId,
    required int total,
    required int done,
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
        total: total,
        done: done,
        finished: finished,
        localKey: 'src/$comicId/$chapterId',
        error: error,
      );

  /// 在真实事件循环里等待一段真实时间：让挂在 fake zone 的文件 IO
  /// 在真实循环里完成（reload 的 Future.wait / upsertDownload 落盘）。
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }

  /// 反复推进真实 IO + 帧，直到书架退出 loading 出现 Tab（限 40 轮）。
  Future<void> settleUntilTabs(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await settleIo(tester);
      if (find.text('下载').evaluate().isNotEmpty) return;
    }
    fail('书架未在限时内渲染出 Tab（reload 未完成）');
  }

  /// 反复推进直到出现指定文本（点击下载 Tab 会再触发一轮 reload，
  /// 期间 _loading 为 true 无正文，需等第二轮完成）。
  Future<void> settleUntilText(WidgetTester tester, String text) async {
    for (var i = 0; i < 60; i++) {
      await settleIo(tester);
      if (find.text(text).evaluate().isNotEmpty) return;
    }
    fail('限时内未出现文本「$text」');
  }

  testWidgets('下载 Tab：进行中任务不算失败，「重试 N」只数失败项', (tester) async {
    // 真实 IO 组：LocalStore 初始化 + 绑定书架文件 + 预置下载记录。
    await tester.runAsync(() async {
      await LocalStore.init();
      BookshelfStore.bindFile(File('${tmp.path}/bookshelf.json'));
      // 进行中：done < total（5/10）
      await LocalStore.upsertDownload(rec(
          comicId: 'running', chapterId: '1', total: 10, done: 5,
          finished: false));
      // 失败：done >= total 且未 finished
      await LocalStore.upsertDownload(rec(
          comicId: 'broken', chapterId: '2', total: 10, done: 10,
          finished: false, error: '下载未完成：0 页失败'));
    });

    await tester.pumpWidget(MaterialApp(home: BookshelfPage()));
    // initState 触发 reload：真实事件循环里等文件 IO + Future.wait 完成。
    await settleUntilTabs(tester);

    // 切到下载 Tab（自绘 _tabItem，文本「下载」；点击触发 reload + setState）。
    await tester.tap(find.text('下载'));
    // 点击后再触发一轮 reload（_loading=true 期间无正文），等第二轮完成。
    await settleUntilText(tester, '漫画broken');

    // 「重试 N」只含失败项（1），不含进行中项。
    expect(find.text('重试 1'), findsOneWidget);
    // 进行中与失败卡片都在列表里。
    expect(find.text('漫画running'), findsOneWidget);
    expect(find.text('漫画broken'), findsOneWidget);
    // 无未处理异常（build 渲染正常）。
    expect(tester.takeException(), isNull);
  });
}