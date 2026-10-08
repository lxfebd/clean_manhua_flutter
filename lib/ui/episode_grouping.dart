import '../sources/video_source.dart';

/// 判断扁平剧集列表中下标为 [index] 的剧集是否有下一集（非末集）。
/// 与阅读器 [canContinueChapter]/[hasPrevChapter] 同款边界谓词：
/// 空/越界下标一律视为无下一集（返回 false）。
bool hasNextEpisode(int index, int count) =>
    index >= 0 && index < count - 1;

/// 判断扁平剧集列表中的 [index] 是否有上一集（非首集）。
bool hasPrevEpisode(int index) => index > 0;

/// 把扁平的剧集按 [VideoEpisode.season]（播放源/线路）分组，保持源的顺序。
/// 返回每组：源名（带「第N源」兜底）+ 该源下的剧集。仅当存在多个源时才
/// 展示分组头。抽自播放器主 State，供选集面板/快捷面板复用。
List<({String name, List<VideoEpisode> eps})> groupEpisodesBySeason(
  List<VideoEpisode> episodes,
  Map<int, String>? sourceNames,
) {
  final bySeason = <int, List<VideoEpisode>>{};
  for (final e in episodes) {
    (bySeason[e.season] ??= []).add(e);
  }
  final keys = bySeason.keys.toList()..sort();
  return [
    for (final k in keys)
      (
        name: sourceNames?[k] ?? '线路 $k',
        eps: bySeason[k]!,
      ),
  ];
}

/// 集数展示数字：单线路为剧集数；多线路且各线路集数相同（同一部剧的多个
/// 播放渠道通常是镜像）报每线路集数；各线路不等时报线路数。
/// **绝不把各线路剧集相加**——4 渠道 × 12 集是 12 集，不是 48 集。
int episodeCountFor(List<VideoEpisode> episodes, Map<int, String>? sourceNames) {
  final groups = groupEpisodesBySeason(episodes, sourceNames);
  if (groups.length <= 1) return episodes.length;
  final counts = {for (final g in groups) g.eps.length};
  return counts.length == 1 ? counts.first : groups.length;
}

/// 集数展示文案（详情页/播放器共用口径）：
/// - 单线路：「共 N 集」
/// - 多线路且各线路集数相同：「M 线路 · 共 N 集」
/// - 多线路且集数不同：给了 [currentSeason] 时「M 线路 · 当前 C 集」，
///   否则「M 线路 · 各线路集数不同」
String episodeCountLabelFor(
  List<VideoEpisode> episodes,
  Map<int, String>? sourceNames, {
  int? currentSeason,
  int? currentEpisode,
}) {
  final groups = groupEpisodesBySeason(episodes, sourceNames);
  if (groups.length <= 1) return '共 ${episodes.length} 集';
  final counts = {for (final g in groups) g.eps.length};
  if (counts.length == 1) return '${groups.length} 线路 · 共 ${counts.first} 集';
  if (currentSeason != null) {
    final cur = groups.where((g) => g.eps
        .any((e) => e.season == currentSeason && e.episode == currentEpisode));
    final c = cur.isNotEmpty ? cur.first.eps.length : groups.first.eps.length;
    return '${groups.length} 线路 · 当前 $c 集';
  }
  return '${groups.length} 线路 · 各线路集数不同';
}
