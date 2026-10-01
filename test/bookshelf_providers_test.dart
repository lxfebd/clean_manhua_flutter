import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/video_download_manager.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/ui/bookshelf_providers.dart';

/// bookshelfDataProvider 单元测试：六组并行读取聚合、单组/全组容错、
/// foldersVersion 变更自动失效、动画下载过滤。
///
/// BookshelfStore 用 bindFile 隔离到临时文件；LocalStore 经 path_provider
/// mock 指向独立临时目录（与现有 LocalStore 测试同模式）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_shelf_providers');
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
    await LocalStore.init();
  });

  tearDown(() async {
    if (tmpDir.existsSync()) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  ComicDetail detail(String id, {String? status, String? type}) =>
      ComicDetail(ComicItem(id, '漫画$id', ''), [], status: status, type: type);

  group('bookshelfDataProvider', () {
    test('六组数据并行聚合：书架/历史/视频/下载/分类/书签', () async {
      // 书架 2 本
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
      // 书签 1 条
      await LocalStore.addBookmark(const ComicBookmark(
        book: Bookmark(
            sourceId: 'src', comicId: '2', name: '漫画2', pic: ''),
        chapterId: 'c2',
        chapterTitle: '第2话',
        pageIndex: 0,
        timestamp: 200,
      ));
      // 分类 1 个
      await BookshelfStore.addFolder('追更');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final data = await container.read(bookshelfDataProvider.future);

      expect(data.items, hasLength(2));
      expect(data.recent, hasLength(1));
      expect(data.videos, isEmpty);
      expect(data.mangaDownloads, hasLength(1));
      // folders() 恒含内置「全部 + 默认分类」，再加自建的「追更」。
      expect(data.folders.map((f) => f['name']), contains('追更'));
      expect(data.bookmarks, hasLength(1));
      expect(data.totalError, isNull);
    });

    test('单组读取失败（历史文件语义损坏）→ 该组空列表兜底，其余照常', () async {
      BookshelfStore.add('src', detail('1'));
      // history 文件写入结构合法但类型错误的 JSON：fromMap cast 抛 TypeError，
      // 触发 provider 的 _readGroup 容错（_read 对纯损坏 JSON 返回 null 不抛）。
      final dataDir = Directory('${tmpDir.path}/data');
      dataDir.createSync(recursive: true);
      await File('${dataDir.path}/history.json')
          .writeAsString('[123]', flush: true);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final data = await container.read(bookshelfDataProvider.future);

      expect(data.items, hasLength(1), reason: '其余组照常渲染');
      expect(data.recent, isEmpty, reason: '失败组用空列表兜底');
      expect(data.totalError, isNull, reason: '单组失败不触发整页错误');
    });

    test('全部六组失败不可构造（书架/分类读取天然容错）→ 多组失败也不误报整页错误', () async {
      // 六组全部写入语义损坏文件；但 BookshelfStore.listAll()/folders() 对损坏
      // JSON 走备份+空开始（不抛），LocalStore 四组 fromMap cast 抛——因此
      // 实际上「六组全败」在本架构不可达，这里验证损坏数据不会误触发整页错误。
      final dataDir = Directory('${tmpDir.path}/data');
      dataDir.createSync(recursive: true);
      await File('${tmpDir.path}/bookshelf.json').writeAsString('{损坏', flush: true);
      for (final name in ['history', 'videos', 'downloads', 'bookmarks']) {
        await File('${dataDir.path}/$name.json').writeAsString('[123]', flush: true);
      }

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final data = await container.read(bookshelfDataProvider.future);

      // 书架/分类两组容错为空列表；LocalStore 四组语义损坏被 _readGroup 兜底。
      expect(data.totalError, isNull, reason: '损坏文件不误报整页错误');
      expect(data.items, isEmpty);
      expect(data.folders.map((f) => f['name']), contains('全部'));
    });

    test('foldersVersion 变更 → provider 自动失效重读（无需手动 reload）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before = await container.read(bookshelfDataProvider.future);
      // 内置「全部 + 默认分类」，无自建分类。
      expect(before.folders, hasLength(2));

      await BookshelfStore.addFolder('新分类');
      // ValueNotifier 自增后 provider 应重新执行并携带新分类。
      final after = await container.read(bookshelfDataProvider.future);
      expect(after.folders, hasLength(3));
      expect(after.folders.map((f) => f['name']), contains('新分类'));
    });

    test('动漫下载过滤：仅展示进行中 + 已完成，终止的历史残留不占列表', () async {
      final m = VideoDownloadManager.instance;
      await m.resetForTest();
      addTearDown(m.resetForTest);
      m.seedForTest(VideoDownloadTask(
          sourceId: 's', videoId: 'v', title: '进行中', season: 1,
          episode: 1, url: 'http://x/a.mp4'));
      m.seedForTest(VideoDownloadTask(
          sourceId: 's', videoId: 'v', title: '已完成', season: 1,
          episode: 2, url: 'http://x/b.mp4')
        ..state = 'done'
        ..localPath = '/tmp/b.mp4');
      m.seedForTest(VideoDownloadTask(
          sourceId: 's', videoId: 'v', title: '失败', season: 1,
          episode: 3, url: 'http://x/c.mp4')
        ..state = 'failed');
      m.seedForTest(VideoDownloadTask(
          sourceId: 's', videoId: 'v', title: '已取消', season: 1,
          episode: 4, url: 'http://x/d.mp4')
        ..state = 'canceled');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final data = await container.read(bookshelfDataProvider.future);

      expect(data.animeDownloads.map((t) => t.title),
          containsAll(['进行中', '已完成']));
      expect(data.animeDownloads.map((t) => t.title), isNot(contains('失败')));
      expect(data.animeDownloads.map((t) => t.title),
          isNot(contains('已取消')));
      expect(data.totalError, isNull);
    });

    test('任务进度变化 → 版本号递增 → 列表实时更新（进度可见）', () async {
      final m = VideoDownloadManager.instance;
      await m.resetForTest();
      addTearDown(m.resetForTest);
      m.seedForTest(VideoDownloadTask(
          sourceId: 's', videoId: 'v', title: '下载中', season: 1,
          episode: 1, url: 'http://x/a.mp4')
        ..segmentsTotal = 10);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final first = await container.read(bookshelfDataProvider.future);
      final key = first.animeDownloads.single.key;

      // 推进进度：直接改任务字段 + 触发 notifier → 版本号递增 → provider 重读。
      final live = m.taskOf(key);
      expect(live, isNotNull);
      live!.segmentsDone = 5;
      m.notifier.value = Map.of(m.tasks.fold(<String, VideoDownloadTask>{},
          (map, t) => map..[t.key] = t));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final updated = await container.read(bookshelfDataProvider.future);
      final liveTask = updated.animeDownloads.single;
      expect(liveTask.segmentsDone, 5, reason: '进度变化后列表应反映最新进度');
    });

    test('BookshelfData 值相等：进度推进 → 不相等；无实质变化重读 → 相等', () {
      final mk = ({
        int done = 0,
        int total = 10,
        String state = 'downloading',
      }) =>
          VideoDownloadTask(
              sourceId: 's', videoId: 'v', title: 'T', season: 1,
              episode: 1, url: 'http://x/a.mp4')
            ..segmentsDone = done
            ..segmentsTotal = total
            ..state = state;
      final base = BookshelfData(
        items: const [], recent: const [], videos: const [],
        mangaDownloads: const [], animeDownloads: [mk()],
        folders: const [], bookmarks: const [],
      );
      // 同一内容重新构造（列表/容器新实例）→ 相等（短路重灌）。
      final same = BookshelfData(
        items: const [], recent: const [], videos: const [],
        mangaDownloads: const [], animeDownloads: [mk()],
        folders: const [], bookmarks: const [],
      );
      expect(same, equals(base), reason: '无实质变化的重读应相等短路');
      // 进度推进（done 变）→ 不相等（驱动实时进度）。
      final progressed = BookshelfData(
        items: const [], recent: const [], videos: const [],
        mangaDownloads: const [], animeDownloads: [mk(done: 5)],
        folders: const [], bookmarks: const [],
      );
      expect(progressed, isNot(equals(base)), reason: '进度变化必须触发重灌');
      // 状态变化（done→failed）→ 不相等。
      final failed = BookshelfData(
        items: const [], recent: const [], videos: const [],
        mangaDownloads: const [], animeDownloads: [mk(state: 'failed')],
        folders: const [], bookmarks: const [],
      );
      expect(failed, isNot(equals(base)));
      // hashCode 契约：相等对象 hashCode 必相等。
      expect(same.hashCode, base.hashCode);
    });
  });
}
