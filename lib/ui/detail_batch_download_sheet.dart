import 'package:flutter/material.dart';

import '../net/download_manager.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/update_notifier.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'responsive.dart';
import 'tokens.dart';
import 'widgets/app_toast.dart';

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

/// 批量下载选章弹窗（原 detail_page.dart 内嵌逻辑搬移）。
///
/// 多选章节 → 批量下载，含画质档位选择（原画/省空间）、下载进度、
/// 取消本批（精确取消只针对本批已派发的章节任务）、全选未下载与
/// 章节标题搜索过滤。弹窗内全部本地状态在 [BatchSheetBodyState]，
/// 不依赖详情页 State。返回 sheet 关闭后的 Future：调用点 await 后
/// 刷新章节列表「已缓存」标记。
Future<void> showBatchDownloadSheet(
  BuildContext context, {
  required List<Chapter> chapters,
  required Set<String> cachedIds,
  required String sourceId,
  required String comicId,
  required String comicName,
  required String? comicPic,
}) {
  if (chapters.isEmpty) return Future.value();
  return showResponsiveBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _BatchSheetBody(
      chapters: chapters,
      cachedIds: cachedIds,
      sourceId: sourceId,
      comicId: comicId,
      comicName: comicName,
      comicPic: comicPic,
      pageContext: context,
    ),
  ).then((_) {});
}

class _BatchSheetBody extends StatefulWidget {
  final List<Chapter> chapters;
  final Set<String> cachedIds;
  final String sourceId;
  final String comicId;
  final String comicName;
  final String? comicPic;
  // 页面 context：下载完成时 AppToast 需落在页面 Overlay（sheet 已 pop）。
  final BuildContext pageContext;

  const _BatchSheetBody({
    required this.chapters,
    required this.cachedIds,
    required this.sourceId,
    required this.comicId,
    required this.comicName,
    required this.comicPic,
    required this.pageContext,
  });

  @override
  State<_BatchSheetBody> createState() => _BatchSheetBodyState();
}

class _BatchSheetBodyState extends State<_BatchSheetBody> {
  final _selected = <int>{};
  bool _downloading = false;
  int _currentIdx = -1;
  int _currentDone = 0;
  int _currentTotal = 0;
  var _quality = DownloadQuality.original;
  // 本次确认下载的章节索引（按下「下载 N 话」时快照，供取消按钮精确取消）
  var _picks = <int>[];
  // 未下载章节的索引（全选只选这些；已下载的显示 ✓ 且不可勾选）
  late final List<int> _selectableChapters = <int>[
    for (var i = 0; i < widget.chapters.length; i++)
      if (!widget.cachedIds.contains(widget.chapters[i].id)) i,
  ];
  final _filterCtrl = TextEditingController();
  String _filter = '';

  // sheet 存活守卫：批量下载闭包不随弹窗存活而中止——下载管理器是全局
  // 后台任务，弹窗关闭（点遮罩/返回/切页）后下载必须继续跑。所有进度
  // 刷新都经 _safeSetState：sheet 已 dispose 时直接跳过（State 的
  // setState 在 dispose 后调用会抛错，未捕获会让整个下载循环终止，
  // 表现为「退出页面下载就停/显示失败」）。
  bool _sheetAlive = true;

  @override
  void initState() {
    super.initState();
    // 记住上次选择的画质档位：异步回填后必须走 setState 触发重建，
    // 否则 SegmentedButton 会一直停在默认「原画」。
    LocalStore.downloadQuality().then((v) {
      if (!mounted) return;
      setState(() {
        _quality = v == 1 ? DownloadQuality.compact : DownloadQuality.original;
      });
    });
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  void _safeSetState(VoidCallback fn) {
    if (!_sheetAlive || !mounted) return;
    try {
      fn();
    } catch (_) {/* sheet 正在销毁：进度刷新可丢，下载继续 */}
  }

  void _closeSheet() {
    if (!_sheetAlive) return;
    _sheetAlive = false;
    if (mounted) Navigator.pop(context);
  }

  /// 过滤后可见的未下载章节索引（全选只作用于这些）。
  List<int> get _visibleSelectable =>
      filterBatchDownloadIndexes(widget.chapters, _selectableChapters, _filter);

  /// 过滤后可见的全部章节索引（搜索框驱动；空过滤 = 全量）。
  List<int> get _visible => filterBatchDownloadIndexes(
        widget.chapters,
        [for (var i = 0; i < widget.chapters.length; i++) i],
        _filter,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.65,
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
                  if (_downloading)
                    TextButton(
                      onPressed: () {
                        // 精确取消本批：只取消未下载的章节任务，
                        // 不影响阅读页/其它详情页在途的下载任务。
                        for (final idx in _picks) {
                          DownloadManager.cancelTask(
                            DownloadManager.taskKeyOf(
                              widget.sourceId,
                              widget.comicId,
                              widget.chapters[idx].id,
                            ),
                          );
                        }
                        setState(() => _downloading = false);
                      },
                      child: const Text('取消'),
                    )
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed:
                              () => setState(() {
                                if (_selected.length ==
                                    _visibleSelectable.length) {
                                  _selected.clear();
                                } else {
                                  // 全选 = 选中所有「可见且未下载」章节
                                  _selected
                                    ..clear()
                                    ..addAll(_visibleSelectable);
                                }
                              }),
                          child: Text(
                            _selected.length == _visibleSelectable.length
                                ? '取消全选'
                                : '全选未下载',
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            // 反选 = 翻转当前可见未下载章节的选中态
                            final next = invertSelection(
                              _selected,
                              _visibleSelectable,
                            );
                            _selected
                              ..clear()
                              ..addAll(next);
                          }),
                          child: const Text('反选'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            // 画质档位选择：原画（保真）/ 省空间（宽边压到 1080 重新编码）
            if (!_downloading)
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
                        selected: {_quality},
                        showSelectedIcon: false,
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          textStyle: WidgetStatePropertyAll(
                            TextStyle(fontSize: 12),
                          ),
                        ),
                        onSelectionChanged: (s) {
                          setState(() => _quality = s.first);
                          LocalStore.setDownloadQuality(
                            _quality == DownloadQuality.compact ? 1 : 0,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            if (_downloading)
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
                      _currentIdx >= 0
                          ? '下载中: 第${_currentIdx + 1}话 ($_currentDone/$_currentTotal)'
                          : '准备中…',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            if (!_downloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: TextField(
                  controller: _filterCtrl,
                  onChanged: (v) => setState(() => _filter = v),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索章节标题 / 话数',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.4),
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                    suffixIcon: _filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除',
                            icon: const Icon(Icons.close_rounded, size: 16),
                            onPressed: () {
                              _filterCtrl.clear();
                              setState(() => _filter = '');
                            },
                          ),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(R.control),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _visible.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.search_off_rounded,
                            size: 36,
                            color: scheme.onSurface.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _filter.trim().isEmpty
                                ? '暂无章节'
                                : '没有匹配「$_filter」的章节',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _visible.length,
                      itemBuilder: (_, i) {
                        final idx = _visible[i];
                        final ch = widget.chapters[idx];
                        final downloaded = widget.cachedIds.contains(ch.id);
                        final sel = _selected.contains(idx);
                        return CheckboxListTile(
                          value: downloaded || sel,
                          enabled: !_downloading && !downloaded,
                          onChanged:
                              (v) => setState(
                                () =>
                                    v == true
                                        ? _selected.add(idx)
                                        : _selected.remove(idx),
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
            if (!_downloading)
              Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed:
                        _selected.isEmpty
                            ? null
                            : () async {
                              _picks = _selected.toList()..sort();
                              _safeSetState(() => _downloading = true);
                              final gen = DownloadManager.beginBatch();
                              final book = Bookmark(
                                sourceId: widget.sourceId,
                                comicId: widget.comicId,
                                name: widget.comicName,
                                pic: widget.comicPic ?? '',
                              );
                              var ok = 0;
                              var fail = 0;
                              String? firstErr;
                              for (final idx in _picks) {
                                if (DownloadManager.isCancelled(gen)) {
                                  break;
                                }
                                final ch = widget.chapters[idx];
                                // 用户取消（弹窗/书架取消按钮）：停止后续章节
                                if (DownloadManager.isTaskCancelled(
                                  DownloadManager.taskKeyOf(
                                    widget.sourceId,
                                    widget.comicId,
                                    ch.id,
                                  ),
                                )) {
                                  break;
                                }
                                _safeSetState(() {
                                  _currentIdx = idx;
                                  _currentDone = 0;
                                  _currentTotal = 0;
                                });
                                try {
                                  final urls = await SourceManager.byId(
                                    widget.sourceId,
                                  ).chapterPics(ch.id);
                                  _safeSetState(
                                    () => _currentTotal = urls.length,
                                  );
                                  final okCh = await DownloadManager
                                      .downloadChapter(
                                        batchGen: gen,
                                        book: book,
                                        chapterId: ch.id,
                                        chapterTitle: ch.title,
                                        urls: urls,
                                        quality: _quality,
                                        onProgress: (d, t) =>
                                            _safeSetState(() {
                                              _currentDone = d;
                                              _currentTotal = t;
                                            }),
                                      );
                                  if (okCh.ok) {
                                    ok++;
                                  } else {
                                    fail++;
                                    firstErr ??= okCh.error ?? '下载失败';
                                  }
                                } catch (e) {
                                  fail++;
                                  ErrorLogger.instance.warn(
                                    'batch download failed: $e',
                                  );
                                }
                              }
                              _closeSheet();
                              // 页面已退出（批量下载关窗后继续跑）时应用内
                              // toast 不可达：补系统通知兜底，让用户知道结果。
                              final msg =
                                  fail == 0
                                      ? '已下载 $ok 话'
                                      : '$ok 话成功，$fail 话失败${firstErr == null ? '' : '：$firstErr'}';
                              await UpdateNotifier.notifyDownloadResult(
                                title: '《${widget.comicName}》下载完成',
                                text: msg,
                                error: fail > 0,
                              );
                              if (widget.pageContext.mounted) {
                                AppToast.show(
                                  widget.pageContext,
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
                      _selected.isEmpty
                          ? '请选择章节'
                          : '下载 ${_selected.length} 话',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
