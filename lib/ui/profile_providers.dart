import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/bookshelf_store.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';

/// 我的页聚合统计的不可变快照。
///
/// 一次并行读取六组本地数据供 profile_page 渲染：收藏数、历史条数、
/// 下载条数、今日/本周/累计阅读秒数。任一组读取失败整组以错误态抛出
/// （页面经 when(error) 进入错误态，与原页面「任一读取失败即整页错误」
/// 语义一致）。并行读取总耗时 ≈ 最慢一组。
class ProfileStats {
  /// 收藏数（书架条目总数）。
  final int favorites;
  final List<HistoryEntry> history;
  final List<DownloadRecord> downloads;
  /// 今日阅读秒数。
  final int todaySeconds;
  /// 本周（最近 7 天）阅读秒数。
  final int weekSeconds;
  /// 累计阅读秒数。
  final int totalSeconds;

  const ProfileStats({
    required this.favorites,
    required this.history,
    required this.downloads,
    required this.todaySeconds,
    required this.weekSeconds,
    required this.totalSeconds,
  });
}

/// 我的页聚合统计 provider。
///
/// 页面 watch 本 provider 即拿到全部统计；刷新（下拉/切 Tab 回来）用
/// `ref.invalidate(profileProvider)`。与 bookshelfDataProvider 同模式：
/// 失败不整页崩溃，单组兜底空值。
final profileProvider = FutureProvider<ProfileStats>((ref) async {
  try {
    final results = await Future.wait([
      Future.value(BookshelfStore.listAll().length),
      LocalStore.history(),
      LocalStore.downloads(),
      LocalStore.todayReadingSeconds(),
      LocalStore.weekReadingSeconds(),
      LocalStore.totalReadingSeconds(),
    ]);
    return ProfileStats(
      favorites: results[0] as int,
      history: results[1] as List<HistoryEntry>,
      downloads: results[2] as List<DownloadRecord>,
      todaySeconds: results[3] as int,
      weekSeconds: results[4] as int,
      totalSeconds: results[5] as int,
    );
  } catch (e) {
    // 整组聚合失败（理论上是某组读取抛错）→ 错误态交给页面，不在这里吞。
    ErrorLogger.instance.warn('我的页统计聚合失败: $e');
    rethrow;
  }
});
