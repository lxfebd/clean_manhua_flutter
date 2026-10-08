import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';

/// 单源搜索容错包装：成功返回 `(items, false)`；失败/超时静默返回
/// `(<ComicItem>[], true)`（单源失败只丢该源结果，不拖垮整次搜索）。
Future<(List<ComicItem>, bool)> safeSearch(
  ComicSource src,
  String keyword,
  int page,
) async {
  try {
    final items = await src
        .search(keyword, page)
        .timeout(const Duration(seconds: 15));
    return (items, false);
  } catch (_) {
    return (const <ComicItem>[], true);
  }
}

/// 小说源的同款容错搜索包装：小说条目复用 [ComicItem] 模型（id/name/pic
/// 同构），失败静默（与漫画一致，单源失败只丢该源结果）。
Future<(List<ComicItem>, bool)> safeSearchNovel(
  NovelSource src,
  String keyword,
  int page,
) async {
  try {
    final items = await src
        .search(keyword, page)
        .timeout(const Duration(seconds: 15));
    return (items, false);
  } catch (_) {
    return (const <ComicItem>[], true);
  }
}

/// 搜索单页的大致容量（各源实际页容量可能不同，仅用于「还有没有更多」判定）。
/// 页面与 provider 共用同一常量，避免两处硬编码 20。
const int searchPageSize = 20;

/// 单个源的搜索结果（漫画源或小说源二选一）。
class SourceResult {
  /// 漫画源（[isNovel] = false 时非空）。
  final ComicSource? source;

  /// 小说源（[isNovel] = true 时非空）。
  final NovelSource? novelSource;

  final List<ComicItem> items;
  final int page; // 已加载到的页码（从 1 开始）

  SourceResult({
    this.source,
    this.novelSource,
    required this.items,
    this.page = 1,
  }) : assert(source != null || novelSource != null,
            'SourceResult 必须携带漫画源或小说源之一');

  bool get isNovel => novelSource != null;
  String get sourceId => novelSource?.id ?? source!.id;
  String get sourceName => novelSource?.name ?? source!.name;
}

/// 一源完成即上报的增量集合消息。
class SearchStreamEvent {
  /// 完成了一个源：命中结果（可为空）或失败（[failed] = true）。
  final SourceResult? group;
  final bool failed;
  final int failedCount;
  /// 是否所有源都已落定（含失败；此时页面可判定整体 noMatch/错误态）。
  final bool done;

  const SearchStreamEvent({
    this.group,
    this.failed = false,
    this.failedCount = 0,
    this.done = false,
  });
}

/// 跨源搜索的流式版本：每源完成即 emit 一条 [SearchStreamEvent]，页面
/// `ref.listen` 增量追加——快源结果 1 秒内就能上屏，不再被最慢源（15s
/// 超时）的 `Future.wait` 拖住整页转圈。终态事件（[done]）携带全部失败
/// 统计，供页面判定 noMatch/全失败错误态。
final searchSweepStreamProvider =
    StreamProvider.family<SearchStreamEvent, String>((ref, keyword) async* {
  final kw = keyword.trim();
  if (kw.isEmpty) {
    yield const SearchStreamEvent(done: true);
    return;
  }
  final enabled = await SourceManager.enabledSources();
  final novelEnabled = await SourceManager.enabledNovelSources();
  // 并发发起所有源；`Stream.fromFutures` 按**真实完成顺序** emit（先完成的
  // 源先到先显示）——逐个 await 数组下标会按源顺序等待（慢源挡快源）。
  final tagged = <Future<(int, List<ComicItem>, bool)>>[
    for (var i = 0; i < enabled.length; i++)
      safeSearch(enabled[i], kw, 1).then((r) => (i, r.$1, r.$2)),
    for (var i = 0; i < novelEnabled.length; i++)
      safeSearchNovel(novelEnabled[i], kw, 1)
          .then((r) => (enabled.length + i, r.$1, r.$2)),
  ];
  var failed = 0;
  var emitted = 0;
  final total = tagged.length;
  if (total == 0) {
    // 无任何启用源（测试禁用全部内置源但 fake 源未被 enabledSources 返回，
    // 或用户关了所有源）：直接发终态，避免 stream 空转永不 done。
    yield const SearchStreamEvent(done: true);
    return;
  }
  await for (final (i, items, isFailed) in Stream.fromFutures(tagged)) {
    emitted++;
    if (isFailed) {
      failed++;
      yield SearchStreamEvent(failed: true, failedCount: failed);
    } else if (items.isNotEmpty) {
      if (i < enabled.length) {
        yield SearchStreamEvent(
            group: SourceResult(source: enabled[i], items: items, page: 1));
      } else {
        yield SearchStreamEvent(
            group: SourceResult(
                novelSource: novelEnabled[i - enabled.length],
                items: items,
                page: 1));
      }
    } else {
      // 命中为空也记为完成（无 group），页面据此推进 loading 判定。
      yield SearchStreamEvent(failedCount: failed);
    }
    if (emitted == total) {
      yield SearchStreamEvent(done: true, failedCount: failed);
    }
  }
});
