import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/local_store.dart';
import '../models/comic_item.dart';
import '../sources/source_manager.dart';

/// 推荐条目：作品 + 命中理由。
class RecommendItem {
  final String sourceId;
  final ComicItem item;
  final String reason;
  final double score;
  const RecommendItem(this.sourceId, this.item, this.reason, this.score);
}

/// 本地智能推荐：纯规则、全本地计算、不上传任何数据。
///
/// 算法（批次 C「本地推荐」实现）：
/// 1. 聚合阅读历史，按作者统计阅读次数（历史条目里 author 字段）；
/// 2. 对排前 N 的作者，跨「启用中的漫画源」搜索该作者（复用 ComicSource.search）；
/// 3. 过滤已是书架/历史的作品；按「作者热度 × 作品热度」排序取 Top K。
///
/// 无模型、无网络上传；搜索本身走各源接口（同用户手动搜索一致）。
class LocalRecommender {
  LocalRecommender._();

  static const int _maxAuthors = 3;
  static const int _maxResults = 12;

  /// 从历史记录聚合出「作者 → 阅读次数」（按 timestamp 去重同作品）。
  @visibleForTesting
  static Map<String, int> authorCounts(List<HistoryEntry> history) {
    final counts = <String, int>{};
    final seen = <String>{};
    for (final h in history) {
      final author = h.book.author.trim();
      if (author.isEmpty) continue;
      if (!seen.add(h.book.key)) continue; // 同作品只计一次
      counts[author] = (counts[author] ?? 0) + 1;
    }
    return counts;
  }

  /// 跨启用源搜索作者名，聚合结果（去重按 sourceId::id）。
  static Future<List<RecommendItem>> recommend({
    List<HistoryEntry>? history,
    int max = _maxResults,
  }) async {
    final h = history ?? await LocalStore.history();
    final counts = authorCounts(h);
    if (counts.isEmpty) return const [];

    final topAuthors = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final authorList = topAuthors.take(_maxAuthors).map((e) => e.key).toList();

    final sources = await SourceManager.enabledSources();
    final seenKeys = h.map((e) => e.book.key).toSet();

    final found = <String, RecommendItem>{};
    // 逐作者搜索（顺序执行，避免并发打爆源站；受各源自身限流约束）。
    for (final author in authorList) {
      for (final src in sources) {
        try {
          final items = await src
              .search(author, 1)
              .timeout(const Duration(seconds: 8));
          for (final it in items) {
            final key = '${src.id}::${it.id}';
            // 已读/已藏（历史记录 key = '$sourceId::$comicId'）
            if (seenKeys.contains(key)) continue;
            if (found.containsKey(key)) continue;
            // 命中度：作者完全一致 > 名称包含作者名
            final authorHit =
                (it.author ?? '').trim() == author ? 1.0 : 0.5;
            final score = counts[author]! * 10 + authorHit;
            found[key] = RecommendItem(
              src.id,
              it,
              '因为你看过 $author 的作品',
              score,
            );
          }
        } catch (_) {
          // 单源失败跳过（源超时/反爬），不阻塞推荐
        }
      }
    }

    final out = found.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return out.take(max).toList();
  }

  /// 冷启动兜底：历史里没有作者信息时，从启用源拉取榜单 TopN 作为推荐
  /// （仍全本地计算，仅请求各源榜单接口）。
  static Future<List<RecommendItem>> fallbackRanking({int max = 8}) async {
    final sources = await SourceManager.enabledSources();
    final out = <RecommendItem>[];
    for (final src in sources.take(2)) {
      try {
        final items = await src.rank(1).timeout(const Duration(seconds: 8));
        if (items.isEmpty) continue;
        final picked = items.take(max).map((it) =>
            RecommendItem(src.id, it, '来自 ${src.name} 热门榜', 0.0));
        out.addAll(picked);
      } catch (_) {}
      if (out.length >= max) break;
    }
    final dedup = <String, RecommendItem>{};
    for (final r in out) {
      dedup['${r.sourceId}::${r.item.id}'] =
          dedup['${r.sourceId}::${r.item.id}'] ?? r;
    }
    return dedup.values.take(max).toList();
  }
}