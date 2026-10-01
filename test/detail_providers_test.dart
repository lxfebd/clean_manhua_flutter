import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/novel_shelf_store.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/sources/novel_source.dart' as novel;
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_manager.dart';
import 'package:xingmanxia/ui/detail_providers.dart';

/// 测试用漫画源：detail 可注入（成功/抛错），书架走本地 BookshelfStore。
class FakeComicSource extends ComicSource {
  final String id0;
  final bool failDetail;
  ComicDetail Function(String comicId)? onDetail;
  FakeComicSource(this.id0, {this.failDetail = false, this.onDetail});

  @override
  String get id => id0;
  @override
  String get name => 'fake-$id0';
  @override
  SourceTier get tier => SourceTier.fallback;

  @override
  Future<List<Category>> categories() async => const [];
  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async =>
      const [];
  @override
  Future<List<ComicItem>> rank(int page) async => const [];
  @override
  Future<List<ComicItem>> search(String keyword, int page) async => const [];
  @override
  Future<ComicDetail> detail(String comicId) async {
    if (failDetail) throw Exception('fake detail fail');
    if (onDetail != null) return onDetail!(comicId);
    return ComicDetail(
      ComicItem(comicId, '漫画$comicId', ''),
      [
        Chapter('ch1', '第1话'),
        Chapter('ch2', '第2话'),
      ],
    );
  }
  @override
  Future<List<String>> chapterPics(String chapterId) async => const [];
}

/// 测试用小说源：detail 可注入；书架走本地 NovelShelfStore。
class FakeNovelSource extends novel.NovelSource {
  final String id0;
  final bool failDetail;
  novel.NovelDetail Function(String novelId)? onDetail;
  FakeNovelSource(this.id0, {this.failDetail = false, this.onDetail});

  @override
  String get id => id0;
  @override
  String get name => 'fake-novel-$id0';

  @override
  Future<List<novel.Category>> categories() async => const [];
  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async =>
      const [];
  @override
  Future<List<ComicItem>> rank(int page) async => const [];
  @override
  Future<List<ComicItem>> search(String keyword, int page) async => const [];
  @override
  Future<novel.NovelDetail> detail(String novelId) async {
    if (failDetail) throw Exception('fake novel detail fail');
    if (onDetail != null) return onDetail!(novelId);
    return novel.NovelDetail(
      ComicItem(novelId, '小说$novelId', ''),
      [
        novel.NovelChapter('nc1', '第一章'),
        novel.NovelChapter('nc2', '第二章'),
      ],
    );
  }
  @override
  Future<novel.NovelContent> chapterContent(String chapterId) async =>
      novel.NovelContent(chapterId, '章', const ['内容']);
}

/// detail_providers 单元测试：comic/novel 详情、续读解析、书架态、
/// 源缺失与失败路径（经 ProviderContainer 直查 provider）。
///
/// 隔离：BookshelfStore/NovelShelfStore bindFile 到临时文件；LocalStore 经
/// path_provider mock 指向独立临时目录。源只用注册的 fake（内置源不参与，
/// 避免真实发网）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late FakeComicSource comicSrc;
  late FakeNovelSource novelSrc;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_detail_providers');
    BookshelfStore.bindFile(File('${tmpDir.path}/bookshelf.json'));
    NovelShelfStore.bindFile(File('${tmpDir.path}/novel_shelf.json'));
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
    // 每测试清静态目录缓存：LocalStore._dir 首次 init 后缓存，跨测试
    // 复用会指向已删除的旧 tmpDir（历史读写落错目录）。
    LocalStore.resetForTest();
    await LocalStore.init();
    await LocalStore.clearHistory();
    comicSrc = FakeComicSource('testcomic');
    novelSrc = FakeNovelSource('testnovel');
    SourceManager.addSource(comicSrc);
    SourceManager.addNovelSource(novelSrc);
  });

  tearDown(() async {
    SourceManager.removeSource('testcomic');
    SourceManager.removeNovelSource('testnovel');
    if (tmpDir.existsSync()) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('comicDetailProvider', () {
    test('加载详情：数据就绪并绑定 sourceId', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final d = await container
          .read(comicDetailProvider(('testcomic', 'c1')).future);
      expect(d.id, 'c1');
      expect(d.chapters, hasLength(2));
      // 源实现不统一回填 sourceId，provider 统一绑定（阅读器/书架依赖）。
      expect(d.sourceId, 'testcomic');
    });

    test('详情失败：provider 抛错（页面映射错误态）', () async {
      final failing = FakeComicSource('testfail', failDetail: true);
      SourceManager.addSource(failing);
      addTearDown(() => SourceManager.removeSource('testfail'));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await expectLater(
        container.read(comicDetailProvider(('testfail', 'c9')).future),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('comicResumeProvider', () {
    test('有历史：续读到最近读的章节', () async {
      await LocalStore.recordHistory(HistoryEntry(
        book: const Bookmark(
            sourceId: 'testcomic', comicId: 'c1', name: '漫画c1', pic: ''),
        chapterId: 'ch2',
        chapterTitle: '第2话',
        timestamp: 200,
      ));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final r = await container
          .read(comicResumeProvider(('testcomic', 'c1')).future);
      expect(r.ready, isTrue);
      expect(r.chapter?.id, 'ch2');
    });

    test('无历史：null（回退第 1 话）且 ready', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final r = await container
          .read(comicResumeProvider(('testcomic', 'c1')).future);
      expect(r.ready, isTrue);
      expect(r.chapter, isNull);
    });
  });

  group('comicInShelfProvider', () {
    test('初始不在书架；toggle 后 invalidate 重读为 true', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final key = ('testcomic', 'c1');
      final v0 = await container.read(comicInShelfProvider(key).future);
      expect(v0, isFalse);

      // 经真实书架写路径翻转（源实现调 BookshelfStore）。
      final d = await container.read(comicDetailProvider(key).future);
      await SourceManager.byId('testcomic').toggleBookshelf(d);
      container.invalidate(comicInShelfProvider(key));
      final v1 = await container.read(comicInShelfProvider(key).future);
      expect(v1, isTrue);
    });
  });

  group('novelDetailProvider', () {
    test('加载小说详情', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final d = await container
          .read(novelDetailProvider(('testnovel', 'n1')).future);
      expect(d.id, 'n1');
      expect(d.chapters, hasLength(2));
    });

    test('小说详情失败：provider 抛错', () async {
      final failing = FakeNovelSource('testnofail', failDetail: true);
      SourceManager.addNovelSource(failing);
      addTearDown(() => SourceManager.removeNovelSource('testnofail'));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await expectLater(
        container.read(novelDetailProvider(('testnofail', 'n9')).future),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('novelInShelfProvider', () {
    test('toggle 后 invalidate 重读为 true', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final key = ('testnovel', 'n1');
      final v0 = await container.read(novelInShelfProvider(key).future);
      expect(v0, isFalse);

      final d = await container.read(novelDetailProvider(key).future);
      await SourceManager.novelById('testnovel')!.toggleBookshelf(d);
      container.invalidate(novelInShelfProvider(key));
      final v1 = await container.read(novelInShelfProvider(key).future);
      expect(v1, isTrue);
    });
  });

  group('resolveResumeChapter（提级纯函数）', () {
    test('有该作品历史返回最近章节；无历史返回 null', () {
      final r = resolveResumeChapter(
        history: [
          HistoryEntry(
            book: const Bookmark(
                sourceId: 's', comicId: 'c', name: '书', pic: ''),
            chapterId: 'ch1',
            chapterTitle: '第1话',
            timestamp: 100,
          ),
        ],
        chapters: [Chapter('ch1', '第1话'), Chapter('ch2', '第2话')],
        sourceId: 's',
        comicId: 'c',
      );
      expect(r?.id, 'ch1');

      final none = resolveResumeChapter(
        history: const [],
        chapters: [Chapter('ch1', '第1话')],
        sourceId: 's',
        comicId: 'c',
      );
      expect(none, isNull);
    });
  });
}
