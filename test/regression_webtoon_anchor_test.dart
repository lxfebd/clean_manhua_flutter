import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

/// 条漫滚动模式相关回归：历史记录 scrollOffset（像素级续读锚点）持久化。
/// 注：LocalStore 的目录在进程内只解析一次，全部断言放同一 test 保证顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 打桩：LocalStore 落到临时目录（单元测试无插件通道）。
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_webtoon_anchor').path;
        }
        return null;
      },
    );
  });

  setUp(() => LocalStore.init());

  test('历史记录持久化 scrollOffset + 兼容旧数据（顺序敏感）', () async {
    // 带滚动偏移写入
    await LocalStore.recordHistory(HistoryEntry(
      book: Bookmark(
          sourceId: 'src',
          comicId: 'c1',
          name: '测试',
          pic: 'https://x/p.jpg'),
      chapterId: 'ch1',
      chapterTitle: '第1话',
      timestamp: 1000,
      pageIndex: 3,
      chapterTotalPages: 10,
      scrollOffset: 5230.5,
    ));
    var hist = await LocalStore.history();
    expect(hist, hasLength(1));
    expect(hist.first.pageIndex, 3);
    expect(hist.first.scrollOffset, 5230.5);

    // 无 scrollOffset 的旧条目回退为 0（兼容旧数据）
    await LocalStore.recordHistory(HistoryEntry(
      book: Bookmark(
          sourceId: 'src',
          comicId: 'c2',
          name: '测试2',
          pic: 'https://x/p2.jpg'),
      chapterId: 'ch1',
      chapterTitle: '第1话',
      timestamp: 2000,
      pageIndex: 1,
      chapterTotalPages: 8,
    ));
    hist = await LocalStore.history();
    final old = hist.firstWhere((h) => h.book.comicId == 'c2');
    expect(old.scrollOffset, 0);
    expect(old.pageIndex, 1);
  });
}
