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

  /// 禁用全部内置源（漫画 + 小说 + 视频），仅保留测试源；返回旧配置供 tearDown 还原。
  ///
  /// 三类都必须禁：sweep 同时搜三類启用源（P1-12 起视频源也进统一搜索），
  /// 测试机只要有网，真实视频源（agedm/xifan/…）就会返回结果——断言
  /// 「恰好一个 group」会被真实源破坏，且随网络状况漂移。
  ///
  /// 用「当前实际列表派生」而不是硬编码 id 列表：以后新增内置源自动生效，
  /// 不会再出现「漏了一类媒体」这种回归。
  Future<Map<String, SourceConfig>> disableBuiltinSources() async {
    final before = await SourceConfigStore.all();
    final map = {for (final c in before) c.engineId: c};
    const fakeIds = {'testok', 'testfail'};
    final builtins = <String>{
      for (final s in SourceManager.sources) s.id,
      for (final s in SourceManager.novelSources) s.id,
      for (final s in SourceManager.videoSources) s.id,
    }.difference(fakeIds);
    for (final builtin in builtins) {
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

  group('safeSearch 容错', () {
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