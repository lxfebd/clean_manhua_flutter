import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../sources/source_result.dart';
import '../sources/video_source.dart';

/// 单源搜索失败分类（P1-14）。
///
/// UI 需要区分四种完全不同的情况，而旧实现只给一个 bool：用户看到「搜不到」
/// 时无法判断是自己打错词、源站挂了、被限流，还是要过人机验证——于是反复重试
/// 或直接弃用。
enum SearchFailKind {
  /// 连接层/超时（网络不通或源站无响应）。
  timeout,
  /// 被限流（HTTP 429 或 blocked/rateLimited）。
  rateLimited,
  /// 人机验证（Cloudflare 质询/验证码）。
  captcha,
  /// 页面拿到了但解析不出条目（源站改版）。
  parse,
  /// 其它（HTTP 4xx/5xx、未知异常）。
  other,
}

/// 失败分类的可读文案（UI 直接用，不暴露原始异常/URL）。
String searchFailLabel(SearchFailKind k) => switch (k) {
      SearchFailKind.timeout => '网络超时',
      SearchFailKind.rateLimited => '请求被限流',
      SearchFailKind.captcha => '需要人机验证',
      SearchFailKind.parse => '页面解析失败（源站可能改版）',
      SearchFailKind.other => '请求失败',
    };

/// 纯函数：把异常归约为失败分类。测试直接覆盖，不依赖真实源。
SearchFailKind classifySearchFailure(Object e) {
  if (e is TimeoutException) return SearchFailKind.timeout;
  if (e is SocketException || e is HandshakeException) {
    return SearchFailKind.timeout;
  }
  if (e is SourceError) {
    if (e is SourceBlocked) {
      return e.reason == BlockReason.rateLimited
          ? SearchFailKind.rateLimited
          : SearchFailKind.captcha;
    }
    if (e is SourceParse) return SearchFailKind.parse;
    if (e is SourceNetwork) return SearchFailKind.timeout;
    // 用结构化 statusCode，不靠 message 数 429（P2-15 审计修复）：
    // 状态错误以前全部落进 unknown，字符串匹配形同虚设。
    if (e is SourceService) {
      final code = e.statusCode;
      if (code == 429) return SearchFailKind.rateLimited;
      if (code != null && code >= 500) return SearchFailKind.other;
      if (code == 404 || code == 403) return SearchFailKind.other;
      return SearchFailKind.other;
    }
    return SearchFailKind.other;
  }
  final s = e.toString();
  if (s.contains('Timeout') || s.contains('timeout')) {
    return SearchFailKind.timeout;
  }
  if (s.contains('429')) return SearchFailKind.rateLimited;
  return SearchFailKind.other;
}

/// 单源搜索的失败明细（P1-14：UI 据此给出可操作反馈）。
class SearchFailure {
  final String sourceId;
  final String sourceName;
  final SearchFailKind kind;
  const SearchFailure(this.sourceId, this.sourceName, this.kind);

  String get label => '$sourceName：${searchFailLabel(kind)}';
}

/// 单源搜索的完整结果（含失败分类）。P1-14 新增；成功时 [failure] 为 null。
///
/// UI 需要知道「哪个源、为什么失败」，旧实现只给一个 bool，页面只能显示
/// 「N 个源失败」，用户不知道该重试、该换源，还是该去人机验证。
class SourceSearchResult {
  final List<ComicItem> items;
  final SearchFailure? failure;
  const SourceSearchResult(this.items, this.failure);

  bool get ok => failure == null;
}

/// 单源漫画搜索（带失败分类）。
Future<SourceSearchResult> searchComicSource(
  ComicSource src,
  String keyword,
  int page,
) async {
  try {
    final items = await src
        .search(keyword, page)
        .timeout(const Duration(seconds: 15));
    return SourceSearchResult(items, null);
  } catch (e) {
    return SourceSearchResult(
      const <ComicItem>[],
      SearchFailure(src.id, src.name, classifySearchFailure(e)),
    );
  }
}

/// 单源小说搜索（带失败分类）。
Future<SourceSearchResult> searchNovelSource(
  NovelSource src,
  String keyword,
  int page,
) async {
  try {
    final items = await src
        .search(keyword, page)
        .timeout(const Duration(seconds: 15));
    return SourceSearchResult(items, null);
  } catch (e) {
    return SourceSearchResult(
      const <ComicItem>[],
      SearchFailure(src.id, src.name, classifySearchFailure(e)),
    );
  }
}

/// 单源视频（动漫）搜索（带失败分类）。与 [searchComicSource] 同构：
/// `VideoSource.search` 同样返回 [ComicItem]。
Future<SourceSearchResult> searchVideoSource(
  VideoSource src,
  String keyword,
  int page,
) async {
  try {
    final items = await src
        .search(keyword, page)
        .timeout(const Duration(seconds: 15));
    return SourceSearchResult(items, null);
  } catch (e) {
    return SourceSearchResult(
      const <ComicItem>[],
      SearchFailure(src.id, src.name, classifySearchFailure(e)),
    );
  }
}

/// 视频源的同款容错搜索包装（P1-12：统一搜索的翻页用）。
Future<(List<ComicItem>, bool)> safeSearchVideo(
  VideoSource src,
  String keyword,
  int page,
) async {
  final r = await searchVideoSource(src, keyword, page);
  return (r.items, !r.ok);
}

/// 单源搜索容错包装：成功返回 `(items, false)`；失败/超时静默返回
/// `(<ComicItem>[], true)`（单源失败只丢该源结果，不拖垮整次搜索）。
///
/// 需要失败原因时用 [searchComicSource] / [searchNovelSource]。
Future<(List<ComicItem>, bool)> safeSearch(
  ComicSource src,
  String keyword,
  int page,
) async {
  final r = await searchComicSource(src, keyword, page);
  return (r.items, !r.ok);
}

/// 小说源的同款容错搜索包装：小说条目复用 [ComicItem] 模型（id/name/pic
/// 同构），失败静默（与漫画一致，单源失败只丢该源结果）。
///
/// 需要失败原因时用 [searchComicSource] / [searchNovelSource]。
Future<(List<ComicItem>, bool)> safeSearchNovel(
  NovelSource src,
  String keyword,
  int page,
) async {
  final r = await searchNovelSource(src, keyword, page);
  return (r.items, !r.ok);
}

/// 搜索单页的大致容量（各源实际页容量可能不同，仅用于「还有没有更多」判定）。
/// 页面与 provider 共用同一常量，避免两处硬编码 20。
const int searchPageSize = 20;

/// 单个源的搜索结果（漫画源/小说源/视频源之一）。
///
/// P1-12：三类源的 `search` 都返回 [ComicItem]，所以条目可以共用同一列表；
/// 只有「点下去该进哪个详情页」不同，因此用一个可空来源字段区分。
class SourceResult {
  /// 漫画源（仅漫画结果非空）。
  final ComicSource? source;

  /// 小说源（仅小说结果非空）。
  final NovelSource? novelSource;

  /// 视频（动漫）源（仅动漫结果非空）。
  final VideoSource? videoSource;

  final List<ComicItem> items;
  final int page; // 已加载到的页码（从 1 开始）

  SourceResult({
    this.source,
    this.novelSource,
    this.videoSource,
    required this.items,
    this.page = 1,
  }) : assert(source != null || novelSource != null || videoSource != null,
            'SourceResult 必须携带漫画/小说/视频源之一');

  bool get isNovel => novelSource != null;
  bool get isVideo => videoSource != null;
  String get sourceId =>
      videoSource?.id ?? novelSource?.id ?? source!.id;
  String get sourceName =>
      videoSource?.name ?? novelSource?.name ?? source!.name;
}

/// 一源完成即上报的增量集合消息。
class SearchStreamEvent {
  /// 完成了一个源：命中结果（可为空）或失败（[failed] = true）。
  final SourceResult? group;
  final bool failed;
  final int failedCount;
  /// 是否所有源都已落定（含失败；此时页面可判定整体 noMatch/错误态）。
  final bool done;

  /// 本次搜索中失败的源明细（P1-14：UI 展示「哪个源、为什么」并可重试）。
  /// 失败事件会累积带上，终态（done）时是完整列表。
  final List<SearchFailure> failedSources;

  const SearchStreamEvent({
    this.group,
    this.failed = false,
    this.failedCount = 0,
    this.done = false,
    this.failedSources = const [],
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
  // P1-12：动漫源也进统一搜索。旧实现只扫漫画+小说，于是「全局搜索」
  // 名不副实——用户搜番剧必须退回动漫页（那时才会有「三类媒体」的期待）。
  final videoEnabled = await SourceManager.enabledVideoSources();
  // 并发发起所有源；`Stream.fromFutures` 按**真实完成顺序** emit（先完成的
  // 源先到先显示）——逐个 await 数组下标会按源顺序等待（慢源挡快源）。
  final comicCount = enabled.length;
  final novelCount = novelEnabled.length;
  final tagged = <Future<(int, SourceSearchResult)>>[
    for (var i = 0; i < comicCount; i++)
      searchComicSource(enabled[i], kw, 1).then((r) => (i, r)),
    for (var i = 0; i < novelCount; i++)
      searchNovelSource(novelEnabled[i], kw, 1)
          .then((r) => (comicCount + i, r)),
    for (var i = 0; i < videoEnabled.length; i++)
      searchVideoSource(videoEnabled[i], kw, 1)
          .then((r) => (comicCount + novelCount + i, r)),
  ];
  var failed = 0;
  var emitted = 0;
  final failures = <SearchFailure>[];
  final total = tagged.length;
  if (total == 0) {
    // 无任何启用源（测试禁用全部内置源但 fake 源未被 enabledSources 返回，
    // 或用户关了所有源）：直接发终态，避免 stream 空转永不 done。
    yield const SearchStreamEvent(done: true);
    return;
  }
  await for (final (i, res) in Stream.fromFutures(tagged)) {
    emitted++;
    final f = res.failure;
    if (f != null) {
      failed++;
      failures.add(f);
      // P1-14：带上「哪个源、为什么」，页面才能给出重试/换源/去验证的提示。
      yield SearchStreamEvent(
        failed: true,
        failedCount: failed,
        failedSources: List.of(failures),
      );
    } else if (res.items.isNotEmpty) {
      if (i < comicCount) {
        yield SearchStreamEvent(
            group: SourceResult(source: enabled[i], items: res.items, page: 1));
      } else if (i < comicCount + novelCount) {
        yield SearchStreamEvent(
            group: SourceResult(
                novelSource: novelEnabled[i - comicCount],
                items: res.items,
                page: 1));
      } else {
        final r = SourceResult(
            videoSource: videoEnabled[i - comicCount - novelCount],
            items: res.items,
            page: 1);
        yield SearchStreamEvent(group: r);
      }
    } else {
      // 命中为空也记为完成（无 group），页面据此推进 loading 判定。
      yield SearchStreamEvent(
        failedCount: failed,
        failedSources: List.of(failures),
      );
    }
    if (emitted == total) {
      yield SearchStreamEvent(
        done: true,
        failedCount: failed,
        failedSources: List.of(failures),
      );
    }
  }
});
