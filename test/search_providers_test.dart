import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_manager.dart';
import 'package:xingmanxia/ui/search_providers.dart';

/// 测试用漫画源：search 可注入（成功列表/抛错）。
class FakeComicSource extends ComicSource {
  final String id0;
  final bool fail;
  final SourceTier tier0;
  List<ComicItem> Function(String kw, int page)? onSearch;
  FakeComicSource(this.id0,
      {this.fail = false, this.tier0 = SourceTier.fallback, this.onSearch});

  @override
  String get id => id0;
  @override
  String get name => 'fake-$id0';
  @override
  SourceTier get tier => tier0;

  @override
  Future<List<Category>> categories() async => const [];
  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async =>
      const [];
  @override
  Future<List<ComicItem>> rank(int page) async => const [];
  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    if (fail) throw Exception('fake fail');
    if (onSearch != null) return onSearch!(keyword, page);
    return [ComicItem('$id0-$keyword-1', '$id0 结果1', '')];
  }
  @override
  Future<ComicDetail> detail(String comicId) async =>
      ComicDetail(ComicItem(comicId, 'fake', ''), []);
  @override
  Future<List<String>> chapterPics(String chapterId) async => const [];
}

/// searchSweepProvider 单元测试：空关键词短路、safeSearch 容错、
/// 失败统计与 allFailed 判定（经 ProviderContainer 直查 provider）。
///
/// 网络隔离：内置源（dm5/doubao/jm/mangadex）默认 primary 启用，测试环境
/// 会真实发网。聚合语义测试必须先把内置源经 SourceConfigStore.save 禁用，
/// 只留 fake 源；改前快照 / 改后还原，避免污染真实 sources_config。
void main() {
  late FakeComicSource okSource;
  late FakeComicSource failSource;

  /// 禁用全部内置漫画源 + 联网小说源，仅保留测试源；返回旧配置供 tearDown 还原。
  /// 小说必须一起禁：sweep 会同时搜启用的小说源，测试环境联网源（biquge/
  /// xbiquge）真实发网失败也会计入 failedCount，破坏断言确定性。
  Future<Map<String, SourceConfig>> disableBuiltinSources() async {
    final before = await SourceConfigStore.all();
    final map = {for (final c in before) c.engineId: c};
    for (final builtin in [
      'dm5', 'doubao', 'jm', 'mangadex', // 漫画
      'biquge', 'xbiquge', 'local_novel', // 小说
    ]) {
      await SourceConfigStore.save(SourceConfig(
        engineId: builtin,
        id: map[builtin]?.id ?? builtin,
        name: map[builtin]?.name ?? builtin,
        isEnabled: false,
        tier: SourceTier.disabled,
      ));
    }
    return map;
  }

  setUp(() {
    okSource = FakeComicSource('testok');
    failSource = FakeComicSource('testfail', fail: true);
    SourceManager.addSource(okSource);
    SourceManager.addSource(failSource);
  });
  tearDown(() {
    SourceManager.removeSource('testok');
    SourceManager.removeSource('testfail');
    SourceConfigStore.invalidateCache();
  });

  group('searchSweepProvider', () {
    test('空关键词立即返回空结果（不发起任何源请求）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final outcome =
          await container.read(searchSweepProvider('   ').future);
      expect(outcome.groups, isEmpty);
      expect(outcome.failedCount, 0);
      expect(outcome.hasMore, isFalse);
      expect(outcome.allFailed, isFalse);
    });

    test('safeSearch：单源成功返回 (items, false)', () async {
      okSource.onSearch = (kw, page) =>
          [ComicItem('$kw-1', '结果1', ''), ComicItem('$kw-2', '结果2', '')];
      final (items, isFailed) = await safeSearch(okSource, '火影', 1);
      expect(isFailed, isFalse);
      expect(items, hasLength(2));
      expect(items.first.id, '火影-1');
    });

    test('safeSearch：单源失败返回 (空, true)，不抛异常', () async {
      final (items, isFailed) = await safeSearch(failSource, '火影', 1);
      expect(isFailed, isTrue);
      expect(items, isEmpty);
    });

    test('sweep 聚合：成功源分组保留、失败源计入 failedCount', () async {
      final before = await disableBuiltinSources();
      addTearDown(() async {
        for (final c in before.values) {
          await SourceConfigStore.save(c);
        }
      });
      okSource.onSearch = (kw, page) => [
            for (var i = 1; i <= 25; i++) ComicItem('$kw-$i', '结果$i', ''),
          ];
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final outcome = await container.read(searchSweepProvider('测试').future);

      // 内置源已禁用：outcome 只含 fake 源，可精确断言聚合语义。
      expect(outcome.groups, hasLength(1));
      final ok = outcome.groups.single;
      expect(ok.sourceId, 'testok');
      expect(ok.items, hasLength(25));
      expect(ok.page, 1);
      expect(ok.isNovel, isFalse);
      expect(outcome.failedCount, 1); // failSource 计入失败
    });

    test('sweep 失败情形：全失败 → allFailed=true、noMatch=true', () async {
      final before = await disableBuiltinSources();
      addTearDown(() async {
        for (final c in before.values) {
          await SourceConfigStore.save(c);
        }
      });
      okSource.onSearch = (kw, page) => throw Exception('fake network down');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final outcome = await container.read(searchSweepProvider('测试').future);
      expect(outcome.groups, isEmpty);
      expect(outcome.failedCount, 2); // 两个 fake 源都失败
      expect(outcome.allFailed, isTrue);
      expect(outcome.noMatch, isTrue);
    });

    test('sweep 全部成功但零命中：allFailed=false、noMatch=true', () async {
      // 本测试不需要失败源：移除 failSource，只留 okSource（成功但零命中）。
      SourceManager.removeSource('testfail');
      final before = await disableBuiltinSources();
      addTearDown(() async {
        for (final c in before.values) {
          await SourceConfigStore.save(c);
        }
      });
      okSource.onSearch = (kw, page) => const <ComicItem>[];
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final outcome =
          await container.read(searchSweepProvider('不存在的东西').future);
      expect(outcome.groups, isEmpty);
      expect(outcome.failedCount, 0); // 唯一启用源成功但零命中
      expect(outcome.allFailed, isFalse);
      // 关键语义：零命中 ≠ 失败——页面据此进「没有找到」错误态而非空态。
      expect(outcome.noMatch, isTrue);
    });
  });

  group('searchSweepStreamProvider', () {
    /// 收集 [searchSweepStreamProvider] 的完整事件序列直到收到终态。
    ///
    /// 必须用 [ProviderContainer.listen] 而非 `await for (… .stream)`：对流式
    /// provider 用 `container.read(p.stream)` 的 await-for 会永远等不到流的
    /// done（StreamProvider 冷流经 read 获取后不投递完成信号），listen 可正常
    /// 收完并 close。collector 用 [Completer] 收终态后立即归还，避免依赖
    /// 固定等待时长。
    Future<List<SearchStreamEvent>> collectStreamEvents(
      ProviderContainer container,
      String keyword,
    ) async {
      final events = <SearchStreamEvent>[];
      final done = Completer<void>();
      final sub = container.listen<AsyncValue<SearchStreamEvent>>(
        searchSweepStreamProvider(keyword),
        (prev, next) {
          next.when(
            data: (ev) {
              events.add(ev);
              if (ev.done && !done.isCompleted) done.complete();
            },
            error: (e, st) {
              if (!done.isCompleted) done.complete();
            },
            loading: () {},
          );
        },
      );
      await done.future.timeout(const Duration(seconds: 10));
      sub.close();
      return events;
    }

    test('逐源 emit：成功源产出 group、失败源计 failedCount、终态带 done', () async {
      final before = await disableBuiltinSources();
      addTearDown(() async {
        for (final c in before.values) {
          await SourceConfigStore.save(c);
        }
      });
      okSource.onSearch = (kw, page) =>
          [ComicItem('$kw-1', '结果1', ''), ComicItem('$kw-2', '结果2', '')];
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final events = await collectStreamEvents(container, '测试');

      // 两个 fake 源（1 成功 + 1 失败）：应有两条非终态 + 一条终态。
      final groups = events.where((e) => e.group != null).toList();
      expect(groups, hasLength(1));
      expect(groups.single.group!.sourceId, 'testok');
      expect(groups.single.group!.items, hasLength(2));

      final failedEvents = events.where((e) => e.failed).toList();
      expect(failedEvents, hasLength(1));
      expect(failedEvents.single.failedCount, 1);

      final doneEvents = events.where((e) => e.done).toList();
      expect(doneEvents, hasLength(1));
      expect(doneEvents.single.failedCount, 1);
      // 终态必为最后一条：页面据此关 loading/判 noMatch。
      expect(events.last.done, isTrue);
    });

    test('空关键词：只发一条 done，不发起任何源请求', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final events = await collectStreamEvents(container, '   ');
      expect(events, hasLength(1));
      expect(events.single.done, isTrue);
      expect(events.single.failedCount, 0);
    });
  });
}