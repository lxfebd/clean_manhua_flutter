import 'package:flutter/material.dart';

import '../net/download_manager.dart';
import '../net/local_store.dart';
import '../net/update_notifier.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'widgets/batch_download_sheet.dart';

/// 批量下载选章过滤纯函数（搜索框用；独立便于单元测试）。
/// [indices] 为候选章节索引，[filter] 按标题模糊匹配（空 = 原样返回）；
/// 空标题按「第N话」占位参与匹配，与详情页章节过滤语义一致。
List<int> filterBatchDownloadIndexes(
  List<Chapter> chapters,
  List<int> indices,
  String filter,
) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return indices;
  return [
    for (final i in indices)
      if ((chapters[i].title.isEmpty ? '第${i + 1}话' : chapters[i].title)
          .toLowerCase()
          .contains(f))
        i,
  ];
}

/// 反选：对 [targets] 内的索引翻转选中态，输出新选中集合（其余保持不变）。
/// 批量下载弹窗「反选」按钮用；纯函数便于单元测试。
Set<int> invertSelection(Set<int> selected, List<int> targets) {
  final out = Set<int>.from(selected);
  for (final i in targets) {
    if (!out.add(i)) out.remove(i);
  }
  return out;
}

/// 当前批次画质档位（画质选择行 [_QualitySelector] 写，下载闭包读；
/// 弹窗级共享，避免把状态塞进共享骨架）。
DownloadQuality _batchQuality = DownloadQuality.original;

/// 批量下载选章弹窗（P1-21：骨架已抽至 [showBatchDownloadSheet]，本文件
/// 只保留漫画侧适配：画质档位选择 + 逐章下载执行 + 系统通知兜底文案）。
/// 弹窗内全部本地状态在共享骨架，不依赖详情页 State。返回 sheet 关闭后的
/// Future：调用点 await 后刷新章节列表「已缓存」标记。
Future<void> showBatchDownloadSheet(
  BuildContext context, {
  required List<Chapter> chapters,
  required Set<String> cachedIds,
  required Set<String> readIds,
  required String sourceId,
  required String comicId,
  required String comicName,
  required String? comicPic,
}) {
  if (chapters.isEmpty) return Future.value();
  return showBatchDownloadSheetCore<Chapter>(
    context,
    items: chapters,
    title: '批量下载',
    titleOf: (ch, index) =>
        ch.title.isEmpty ? '第${index + 1}话' : ch.title,
    subtitleOf: (ch, index, {bool? taken}) {
      final scheme = Theme.of(context).colorScheme;
      if (taken == true) {
        return Text(
          '已下载',
          style: TextStyle(
            fontSize: 11,
            color: scheme.primary.withValues(alpha: 0.7),
          ),
        );
      }
      if (readIds.contains(ch.id)) {
        return Text(
          '已读',
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurface.withValues(alpha: 0.55),
          ),
        );
      }
      return null;
    },
    isTaken: (ch, index) => cachedIds.contains(ch.id),
    filter: (candidates, f) =>
        filterBatchDownloadIndexes(chapters, candidates, f),
    downloadOne: (ch, index, onProgress) async {
      final gen = DownloadManager.beginBatch();
      final book = Bookmark(
        sourceId: sourceId,
        comicId: comicId,
        name: comicName,
        pic: comicPic ?? '',
      );
      final urls = await SourceManager.byId(sourceId).chapterPics(ch.id);
      final r = await DownloadManager.downloadChapter(
        batchGen: gen,
        book: book,
        chapterId: ch.id,
        chapterTitle: ch.title,
        urls: urls,
        quality: _batchQuality,
        onProgress: onProgress,
      );
      return r.ok;
    },
    cancelPicks: (picks) {
      for (final idx in picks) {
        DownloadManager.cancelTask(
          DownloadManager.taskKeyOf(
            sourceId,
            comicId,
            chapters[idx].id,
          ),
        );
      }
    },
    doneMessage: (ok, fail, firstErr) {
      if (fail == 0) return '已下载 $ok 话';
      return '$ok 话成功，$fail 话失败'
          '${firstErr == null ? '' : '：$firstErr'}';
    },
    headerExtras: _QualitySelector(),
    onFinished: (ok, fail, firstErr) {
      // 页面已退出（批量下载关窗后继续跑）时应用内 toast 不可达：
      // 补系统通知兜底，让用户知道结果。
      final msg = fail == 0
          ? '已下载 $ok 话'
          : '$ok 话成功，$fail 话失败${firstErr == null ? '' : '：$firstErr'}';
      UpdateNotifier.notifyDownloadResult(
        title: '《$comicName》下载完成',
        text: msg,
        error: fail > 0,
      );
    },
  );
}

/// 画质档位选择行（漫画专属）：原画（保真）/ 省空间（宽边压到 1080 重编码）。
class _QualitySelector extends StatefulWidget {
  @override
  State<_QualitySelector> createState() => _QualitySelectorState();
}

class _QualitySelectorState extends State<_QualitySelector> {
  @override
  void initState() {
    super.initState();
    // 记住上次选择的画质档位：异步回填后必须走 setState 触发重建，
    // 否则 SegmentedButton 会一直停在默认「原画」。
    LocalStore.downloadQuality().then((v) {
      if (!mounted) return;
      setState(() {
        _batchQuality =
            v == 1 ? DownloadQuality.compact : DownloadQuality.original;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Row(
        children: [
          Text(
            '画质',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SegmentedButton<DownloadQuality>(
              segments: const [
                ButtonSegment(
                  value: DownloadQuality.original,
                  label: Text('原画', style: TextStyle(fontSize: 12)),
                  icon: Icon(Icons.hd_rounded, size: 16),
                ),
                ButtonSegment(
                  value: DownloadQuality.compact,
                  label: Text('省空间', style: TextStyle(fontSize: 12)),
                  icon: Icon(Icons.photo_size_select_small_rounded, size: 16),
                ),
              ],
              selected: {_batchQuality},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  TextStyle(fontSize: 12),
                ),
              ),
              onSelectionChanged: (s) {
                setState(() => _batchQuality = s.first);
                LocalStore.setDownloadQuality(
                  _batchQuality == DownloadQuality.compact ? 1 : 0,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
