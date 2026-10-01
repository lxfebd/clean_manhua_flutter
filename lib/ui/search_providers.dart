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

/// 一次搜索（第一页）的聚合结果：按源分组 + 失败统计 + 是否有下一页。
class SearchOutcome {
  final List<SourceResult> groups;
  /// 本次搜索请求失败的源数量（部分失败时 UI 展示提示条）。
  final int failedCount;
  /// 是否有任一源结果超过一页容量（用于「加载更多」判定）。
  final bool hasMore;
  /// 全部源都失败（断网/被墙）时为 true，UI 应进错误态而非「没有结果」。
  final bool allFailed;

  /// 没有任何源产出结果（含全失败与全成功但零命中两种情形）。
  /// 页面级错误态以它为准：命中为空就该进错误态，具体文案再按
  /// [allFailed]/[failedCount] 区分（全失败→搜索失败，否则→没有找到）。
  bool get noMatch => groups.isEmpty;
  /// 搜索单页结果的大致容量（各源实际页容量可能不同，仅用于「还有没有更多」判定）。
  final int pageSize;

  const SearchOutcome({
    required this.groups,
    required this.failedCount,
    required this.hasMore,
    required this.allFailed,
    required this.pageSize,
  });
}

/// 跨源搜索（第一页）：并发搜所有启用漫画源 + 小说源，按源分组聚合。
///
/// - 空关键词返回空结果（不发起请求）。
/// - 单源失败静默丢该源；全部失败置 [SearchOutcome.allFailed]。
/// - 页面触发搜索用 `ref.invalidate(searchSweepProvider(keyword))`；
///   「加载更多」由页面自行并发拉第 N 页去重追加（交互态留页面）。
final searchSweepProvider =
    FutureProvider.family<SearchOutcome, String>((ref, keyword) async {
  final kw = keyword.trim();
  const pageSize = 20;
  if (kw.isEmpty) {
    return const SearchOutcome(
      groups: [],
      failedCount: 0,
      hasMore: false,
      allFailed: false,
      pageSize: pageSize,
    );
  }
  final enabled = await SourceManager.enabledSources();
  final novelEnabled = await SourceManager.enabledNovelSources();
  final futures = <Future<(List<ComicItem>, bool)>>[
    for (final s in enabled) safeSearch(s, kw, 1),
    for (final s in novelEnabled) safeSearchNovel(s, kw, 1),
  ];
  final all = await Future.wait(futures, eagerError: false);
  var failed = 0;
  final list = <SourceResult>[];
  var anyMore = false;
  // 漫画源结果（futures 前段）
  for (var i = 0; i < enabled.length; i++) {
    final (items, isFailed) = all[i];
    if (isFailed) {
      failed++;
      continue;
    }
    if (items.isNotEmpty) {
      list.add(SourceResult(source: enabled[i], items: items, page: 1));
      // 一页就能拉满的源（数量少于页容量）视为没有更多
      anyMore = anyMore || items.length >= pageSize;
    }
  }
  // 小说源结果（futures 后段，偏移 = 漫画源数量）
  for (var i = 0; i < novelEnabled.length; i++) {
    final (items, isFailed) = all[enabled.length + i];
    if (isFailed) {
      failed++;
      continue;
    }
    if (items.isNotEmpty) {
      list.add(
        SourceResult(novelSource: novelEnabled[i], items: items, page: 1),
      );
      anyMore = anyMore || items.length >= pageSize;
    }
  }
  return SearchOutcome(
    groups: list,
    failedCount: failed,
    hasMore: anyMore,
    allFailed: list.isEmpty && failed > 0,
    pageSize: pageSize,
  );
});
