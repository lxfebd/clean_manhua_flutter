import 'package:flutter/material.dart';

import '../net/download_manager.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'responsive.dart';
import 'widgets/app_toast.dart';

/// 批量下载选章弹窗（原 detail_page.dart 内嵌逻辑搬移）。
///
/// 多选章节 → 批量下载，含画质档位选择（原画/省空间）、下载进度、
/// 取消本批（精确取消只针对本批已派发的章节任务）与全选未下载。
/// 纯搬移：UI/交互/逻辑语义与原 _DetailPageState._openBatchDownloadSheet 一致；
/// 弹窗内全部本地状态走 StatefulBuilder 的 setS，不依赖详情页 State。
void showBatchDownloadSheet(
  BuildContext context, {
  required List<Chapter> chapters,
  required Set<String> cachedIds,
  required String sourceId,
  required String comicId,
  required String comicName,
  required String? comicPic,
}) {
  if (chapters.isEmpty) return;
  final selected = <int>{};
  var downloading = false;
  var currentIdx = -1;
  var currentDone = 0;
  var currentTotal = 0;
  var quality = DownloadQuality.original;
  // 本次确认下载的章节索引（按下「下载 N 话」时快照，供取消按钮精确取消）
  var picks = <int>[];
  // 未下载章节的索引（全选只选这些；已下载的显示 ✓ 且不可勾选）
  final selectableChapters = <int>[
    for (var i = 0; i < chapters.length; i++)
      if (!cachedIds.contains(chapters[i].id)) i,
  ];
  // 记住上次选择的画质档位：异步回填后必须走 setS 触发 StatefulBuilder
  // 重建，否则 SegmentedButton 会一直停在默认「原画」。
  // 守卫必须落在 **sheet 自己的** BuildContext 上：只判页面 context.mounted
  // 时，sheet 已关闭但页面还在，回填会对已 dispose 的 StatefulBuilder
  // 调 setState（"setState() called after dispose()"）。
  void Function(VoidCallback)? syncQuality;
  BuildContext? sheetCtx;
  LocalStore.downloadQuality().then((v) {
    if (!context.mounted) return;
    quality = v == 1 ? DownloadQuality.compact : DownloadQuality.original;
    final ctx = sheetCtx;
    if (ctx == null || !ctx.mounted) return;
    syncQuality?.call(() {});
  });
  showResponsiveBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, setS) {
            syncQuality = setS;
            sheetCtx = ctx;
            final scheme = Theme.of(ctx).colorScheme;
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.65,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Text(
                            '批量下载',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: scheme.onSurface,
                            ),
                          ),
                          const Spacer(),
                          if (downloading)
                            TextButton(
                              onPressed: () {
                                // 精确取消本批：只取消未下载的章节任务，
                                // 不影响阅读页/其它详情页在途的下载任务。
                                for (final idx in picks) {
                                  DownloadManager.cancelTask(
                                    DownloadManager.taskKeyOf(
                                      sourceId,
                                      comicId,
                                      chapters[idx].id,
                                    ),
                                  );
                                }
                                setS(() => downloading = false);
                              },
                              child: const Text('取消'),
                            )
                          else
                            TextButton(
                              onPressed:
                                  () => setS(() {
                                    if (selected.length ==
                                        selectableChapters.length) {
                                      selected.clear();
                                    } else {
                                      // 全选 = 选中所有「未下载」章节
                                      selected
                                        ..clear()
                                        ..addAll(selectableChapters);
                                    }
                                  }),
                              child: Text(
                                selected.length == selectableChapters.length
                                    ? '取消全选'
                                    : '全选未下载',
                              ),
                            ),
                        ],
                      ),
                    ),
                    // 画质档位选择：原画（保真）/ 省空间（宽边压到 1080 重新编码）
                    if (!downloading)
                      Padding(
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
                                    label: Text(
                                      '原画',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    icon: Icon(Icons.hd_rounded, size: 16),
                                  ),
                                  ButtonSegment(
                                    value: DownloadQuality.compact,
                                    label: Text(
                                      '省空间',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    icon: Icon(
                                      Icons.photo_size_select_small_rounded,
                                      size: 16,
                                    ),
                                  ),
                                ],
                                selected: {quality},
                                showSelectedIcon: false,
                                style: ButtonStyle(
                                  visualDensity: VisualDensity.compact,
                                  textStyle: WidgetStatePropertyAll(
                                    TextStyle(fontSize: 12),
                                  ),
                                ),
                                onSelectionChanged: (s) {
                                  setS(() => quality = s.first);
                                  LocalStore.setDownloadQuality(
                                    quality == DownloadQuality.compact ? 1 : 0,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (downloading)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.primary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              currentIdx >= 0
                                  ? '下载中: 第${currentIdx + 1}话 ($currentDone/$currentTotal)'
                                  : '准备中…',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: chapters.length,
                        itemBuilder: (_, i) {
                          final ch = chapters[i];
                          final downloaded = cachedIds.contains(ch.id);
                          final sel = selected.contains(i);
                          return CheckboxListTile(
                            value: downloaded || sel,
                            enabled: !downloading && !downloaded,
                            onChanged:
                                (v) => setS(
                                  () =>
                                      v == true
                                          ? selected.add(i)
                                          : selected.remove(i),
                                ),
                            title: Text(
                              ch.title,
                              style: TextStyle(fontSize: 13),
                            ),
                            subtitle:
                                downloaded
                                    ? Text(
                                      '已下载',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.primary.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
                                    )
                                    : null,
                            dense: true,
                          );
                        },
                      ),
                    ),
                    if (!downloading)
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed:
                                selected.isEmpty
                                    ? null
                                    : () async {
                                      picks = selected.toList()..sort();
                                      setS(() => downloading = true);
                                      final gen = DownloadManager.beginBatch();
                                      final book = Bookmark(
                                        sourceId: sourceId,
                                        comicId: comicId,
                                        name: comicName,
                                        pic: comicPic ?? '',
                                      );
                                      var ok = 0;
                                      var fail = 0;
                                      String? firstErr;
                                      for (final idx in picks) {
                                        if (DownloadManager.isCancelled(gen)) {
                                          break;
                                        }
                                        final ch = chapters[idx];
                                        // 用户取消（弹窗/书架取消按钮）：停止后续章节
                                        if (DownloadManager.isTaskCancelled(
                                          DownloadManager.taskKeyOf(
                                            sourceId,
                                            comicId,
                                            ch.id,
                                          ),
                                        )) {
                                          break;
                                        }
                                        setS(() {
                                          currentIdx = idx;
                                          currentDone = 0;
                                          currentTotal = 0;
                                        });
                                        try {
                                          final urls = await SourceManager.byId(
                                            sourceId,
                                          ).chapterPics(ch.id);
                                          setS(
                                            () => currentTotal = urls.length,
                                          );
                                          final okCh =
                                              await DownloadManager
                                                  .downloadChapter(
                                                    batchGen: gen,
                                                    book: book,
                                                    chapterId: ch.id,
                                                    chapterTitle: ch.title,
                                                    urls: urls,
                                                    quality: quality,
                                                    onProgress: (d, t) =>
                                                        setS(() {
                                                          currentDone = d;
                                                          currentTotal = t;
                                                        }),
                                                  );
                                          if (okCh.ok) {
                                            ok++;
                                          } else {
                                            fail++;
                                            firstErr ??=
                                                okCh.error ?? '下载失败';
                                          }
                                        } catch (e) {
                                          fail++;
                                          ErrorLogger.instance.warn(
                                            'batch download failed: $e',
                                          );
                                        }
                                      }
                                      if (ctx.mounted) {
                                        Navigator.pop(ctx);
                                      }
                                      if (context.mounted) {
                                        final msg =
                                            fail == 0
                                                ? '已下载 $ok 话'
                                                : '$ok 话成功，$fail 话失败${firstErr == null ? '' : '：$firstErr'}';
                                        AppToast.show(
                                          context,
                                          msg,
                                          error: fail > 0,
                                        );
                                      }
                                    },
                            icon: const Icon(
                              Icons.download_rounded,
                              size: 18,
                            ),
                            label: Text(
                              selected.isEmpty
                                  ? '请选择章节'
                                  : '下载 ${selected.length} 话',
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
  );
}
