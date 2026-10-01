import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/ui/profile_providers.dart';

/// profileProvider 单元测试：六组聚合、读取失败报错（页面进错误态）。
///
/// BookshelfStore 用 bindFile 隔离到临时文件；LocalStore 经 path_provider
/// mock 指向独立临时目录，每测试 resetForTest 清静态目录缓存（与
/// reader_providers_test 同模式，防跨测试目录缓存指向已删 tmpDir）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_profile_providers');
    BookshelfStore.bindFile(File('${tmpDir.path}/bookshelf.json'));
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

  ComicDetail detail(String id) => ComicDetail(ComicItem(id, '漫画$id', ''), []);

  group('profileProvider', () {
    test('六组数据并行聚合：收藏/历史/下载/今日/本周/累计', () async {
      // 收藏 2 本
      BookshelfStore.add('src', detail('1'));
      BookshelfStore.add('src', detail('2'));
      // 历史 1 条
      await LocalStore.recordHistory(HistoryEntry(
        book: const Bookmark(
            sourceId: 'src', comicId: '1', name: '漫画1', pic: ''),
        chapterId: 'c1',
        chapterTitle: '第1话',
        timestamp: 100,
      ));
      // 下载 1 条（已完成）
      await LocalStore.upsertDownload(const DownloadRecord(
        book: Bookmark(
            sourceId: 'src', comicId: '1', name: '漫画1', pic: ''),
        chapterId: 'c1',
        chapterTitle: '第1话',
        total: 1,
        done: 1,
        finished: true,
        localKey: 'src/1/c1',
      ));
      // 阅读秒数：今日 120 + 60 = 180（addReadingSeconds 记到当天）。
      await LocalStore.addReadingSeconds(120);
      await LocalStore.addReadingSeconds(60);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final data = await container.read(profileProvider.future);

      expect(data.favorites, 2);
      expect(data.history, hasLength(1));
      expect(data.downloads, hasLength(1));
      // 今日/本周/累计都覆盖刚写入的 180 秒（同一自然日）。
      expect(data.todaySeconds, greaterThanOrEqualTo(180));
      expect(data.weekSeconds, greaterThanOrEqualTo(180));
      expect(data.totalSeconds, greaterThanOrEqualTo(180));
    });

    test('某组读取失败 → provider 报错（页面据此进错误态）', () async {
      // history 文件写入结构合法但类型错误的 JSON：fromMap cast 抛 TypeError，
      // 与原页面「任一读取失败即整页错误态」语义一致，provider 不吞。
      final dataDir = Directory('${tmpDir.path}/data');
      dataDir.createSync(recursive: true);
      await File('${dataDir.path}/history.json')
          .writeAsString('[123]', flush: true);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await expectLater(
        container.read(profileProvider.future),
        // history 文件 [123]：HistoryEntry.fromMap 对 123 做 Map 强转抛 TypeError。
        throwsA(isA<TypeError>()),
      );
    });
  });
}
