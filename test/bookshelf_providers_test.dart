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
    // 清掉跨测试残留的静态目录缓存与写队列：前一个测试的 container dispose
    // 后 _dir 仍指向其已删临时目录，不 reset 会让本测试读写到空目录。
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
      // animeDownloadTasksProvider 初始同步 emit 一次当前快照（StreamProvider
      // 冷流：listen 激活后收到首条即含已 seed 的任务过滤结果）。
      final first = await container.read(animeDownloadTasksProvider.future);
      expect(first.map((t) => t.title), containsAll(['进行中', '已完成']));
      expect(first.map((t) => t.title), isNot(contains('失败')));
      expect(first.map((t) => t.title), isNot(contains('已取消')));
    });

    test('任务进度变化 → 任务列表实时更新（进度可见，联动仅限下载 Tab）', () async {
      final m = VideoDownloadManager.instance;
      await m.resetForTest();
      addTearDown(m.resetForTest);
      m.seedForTest(VideoDownloadTask(
          sourceId: 's', videoId: 'v', title: '下载中', season: 1,
          episode: 1, url: 'http://x/a.mp4')
        ..segmentsTotal = 10);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final stream = container.read(animeDownloadTasksProvider.stream);
      final first = await stream.first;
      final key = first.single.key;

      // 推进进度：直接改任务字段 + 触发 notifier → provider 重推。
      final live = m.taskOf(key);
      expect(live, isNotNull);
      live!.segmentsDone = 5;
      m.notifier.value = Map.of(m.tasks.fold(<String, VideoDownloadTask>{},
          (map, t) => map..[t.key] = t));

      final updated = await stream.firstWhere(
          (ts) => ts.any((t) => t.segmentsDone == 5));
      final liveTask = updated.single;
      expect(liveTask.segmentsDone, 5, reason: '进度变化后任务列表应反映最新进度');
    });

    test('BookshelfData 值相等：无实质变化重读 → 相等；内容变化 → 不相等', () {
      final base = BookshelfData(
        items: const [], recent: const [], videos: const [],
        mangaDownloads: const [],
        folders: const [], bookmarks: const [],
      );
      // 同一内容重新构造（列表/容器新实例）→ 相等（短路重灌）。
      final same = BookshelfData(
        items: const [], recent: const [], videos: const [],
        mangaDownloads: const [],
        folders: const [], bookmarks: const [],
      );
      expect(same, equals(base), reason: '无实质变化的重读应相等短路');
      // 内容变化（folders 增一个）→ 不相等。
      final withFolder = BookshelfData(
        items: const [], recent: const [], videos: const [],
        mangaDownloads: const [],
        folders: const [{'id': 'x', 'name': '新分类'}],
        bookmarks: const [],
      );
      expect(withFolder, isNot(equals(base)), reason: '内容变化必须触发重灌');
      // hashCode 契约：相等对象 hashCode 必相等。
      expect(same.hashCode, base.hashCode);
    });
  });

  group('mangaDownloadsProvider', () {
    Bookmark book(String comicId, String chapterId, {int done = 0, int total = 10}) =>
        Bookmark(
            sourceId: 'src', comicId: comicId, name: '漫画$comicId', pic: '');

    test('首帧即时快照 + upsertDownload 经版本号自动重推最新进度', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 预置一条进行中记录（done=2/10）。
      await LocalStore.upsertDownload(DownloadRecord(
        book: book('1', 'c1'),
        chapterId: 'c1',
        chapterTitle: '第1话',
        total: 10,
        done: 2,
        finished: false,
        localKey: 'src/1/c1',
      ));

      final events = <List<DownloadRecord>>[];
      container.listen(mangaDownloadsProvider, (prev, next) {
        next.whenData(events.add);
      });
      // 首帧：listen 激活即读到已落盘记录（含 done 2）。
      final first = await container.read(mangaDownloadsProvider.future);
      expect(first.single.done, 2, reason: '首帧应即时反映已落盘的记录');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.last.single.done, 2);

      // 下载推进：落盘新进度 → downloadsVersion 自增 → 合并窗口后重推最新。
      await LocalStore.upsertDownload(DownloadRecord(
        book: book('1', 'c1'),
        chapterId: 'c1',
        chapterTitle: '第1话',
        total: 10,
        done: 5,
        finished: false,
        localKey: 'src/1/c1',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(events.last.single.done, 5, reason: '进度变化后列表应实时反映最新进度');
    });

    test('合并 300ms：窗口内连续落盘只合并为一次重读', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final events = <List<DownloadRecord>>[];
      container.listen(mangaDownloadsProvider, (prev, next) {
        next.whenData(events.add);
      });
      await container.read(mangaDownloadsProvider.future); // 等首帧（空列表）
      events.clear(); // 后续只看落盘触发的重推

      // 模拟下载每张图落盘：连续 3 次 upsert 推进进度（都在 300ms 窗口内）。
      for (var i = 1; i <= 3; i++) {
        await LocalStore.upsertDownload(DownloadRecord(
          book: book('1', 'c1'),
          chapterId: 'c1',
          chapterTitle: '第1话',
          total: 10,
          done: i,
          finished: false,
          localKey: 'src/1/c1',
        ));
      }
      // 越过合并窗口（300ms debounce + 串行落盘耗时 + 重读 IO，留足余量）：
      // 窗口内多次落盘应收敛为一次重推，且反映最终进度 3。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(events, hasLength(1), reason: '窗口内 3 次落盘应合并为 1 次重读');
      expect(events.single.single.done, 3, reason: '合并重推应反映最终进度');
    });
  });
}
