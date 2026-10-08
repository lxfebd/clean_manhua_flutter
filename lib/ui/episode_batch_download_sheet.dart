import 'package:flutter/material.dart';

import '../net/video_download_manager.dart';
import '../sources/video_source.dart';
import 'widgets/batch_download_sheet.dart';

/// 动漫批量下载选集过滤纯函数（搜索框用；独立便于单元测试）。
/// 按剧集标题模糊匹配，也支持直接输集数（如「12」匹配第 12 集）；
/// 空 = 原列表原样（与选集页 filterVideoEpisodes 同语义）。
List<int> filterEpisodeDownloadIndexes(
  List<VideoEpisode> eps,
  List<int> indices,
  String filter,
) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return indices;
  return [
    for (final i in indices)
      if (eps[i].title.toLowerCase().contains(f) ||
          eps[i].episode.toString().contains(f))
        i,
  ];
}

/// 动漫批量下载选集弹窗（P1-21：骨架已抽至共享 [showBatchDownloadSheet]，
/// 本文件只保留动漫侧适配：逐集解析直链入队 + 已下载判定）。
/// 返回 sheet 关闭后的 Future：调用点 await 后刷新已下载角标。
Future<void> showEpisodeBatchDownloadSheet(
  BuildContext context, {
  required VideoSource source,
  required VideoDetail detail,
}) {
  final eps = detail.episodes;
  if (eps.isEmpty) return Future.value();
  return showBatchDownloadSheetCore<VideoEpisode>(
    context,
    items: eps,
    title: '批量下载',
    titleOf: (e, index) => '第${e.episode}集 ${e.title}',
    subtitleOf: (e, index, {bool? taken}) =>
        taken == true
            ? Text(
                '已下载',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.7),
                ),
              )
            : null,
    isTaken: (e, index) {
      final t = VideoDownloadManager.instance.taskOf(
        '${source.id}/${detail.video.id}/${e.season}-${e.episode}',
      );
      return t != null && (t.isRunning || (t.state == 'done' && t.localPath != null));
    },
    filter: (candidates, f) =>
        filterEpisodeDownloadIndexes(eps, candidates, f),
    downloadOne: (e, index, onProgress) async {
      final url = await source.playUrl(
        detail.video.id,
        e.season,
        e.episode,
      );
      if (!isDirectMediaUrl(url)) return false;
      String referer = '';
      try {
        final u = Uri.parse(url);
        referer = '${u.scheme}://${u.host}/';
      } catch (_) {}
      await VideoDownloadManager.instance.start(
        sourceId: source.id,
        videoId: detail.video.id,
        title: detail.video.name,
        season: e.season,
        episode: e.episode,
        url: url,
        headers: referer.isEmpty ? const {} : {'Referer': referer},
      );
      return true;
    },
    cancelPicks: (picks) {
      for (final idx in picks) {
        final e = eps[idx];
        VideoDownloadManager.instance.cancel(
          '${source.id}/${detail.video.id}/${e.season}-${e.episode}',
        );
      }
    },
    doneMessage: (ok, fail, firstErr) => fail > 0
        ? '批量下载完成：$ok 集成功，$fail 集失败${firstErr != null ? '（$firstErr）' : ''}'
        : '已开始下载 $ok 集',
    // 动漫侧无系统通知兜底（原实现即无，对齐现状不新增）。
  );
}
