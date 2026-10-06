import 'package:flutter/material.dart';

import '../net/error_logger.dart';
import '../net/video_download_manager.dart';
import '../sources/video_source.dart';
import 'responsive.dart';
import 'tokens.dart';
import 'widgets/app_toast.dart';

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

/// 动漫批量下载选集弹窗（对齐漫画 detail_batch_download_sheet 交互）：
/// 多选集 → 逐集解析直链入队下载，含搜索过滤、全选未下载、反选、
/// 当前集进度与取消本批（精确取消只针对本批已派发的任务）。
/// 返回 sheet 关闭后的 Future：调用点 await 后刷新已下载角标。
Future<void> showEpisodeBatchDownloadSheet(
  BuildContext context, {
  required VideoSource source,
  required VideoDetail detail,
}) {
  final eps = detail.episodes;
  if (eps.isEmpty) return Future.value();
  return showResponsiveBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _EpisodeBatchSheetBody(
      source: source,
      detail: detail,
      pageContext: context,
    ),
  ).then((_) {});
}

class _EpisodeBatchSheetBody extends StatefulWidget {
  final VideoSource source;
  final VideoDetail detail;
  // 页面 context：下载完成时 AppToast 需落在页面 Overlay（sheet 已 pop）。
  final BuildContext pageContext;

  const _EpisodeBatchSheetBody({
    required this.source,
    required this.detail,
    required this.pageContext,
  });

  @override
  State<_EpisodeBatchSheetBody> createState() =>
      _EpisodeBatchSheetBodyState();
}

class _EpisodeBatchSheetBodyState extends State<_EpisodeBatchSheetBody> {
  final _selected = <int>{};
  bool _downloading = false;
  int _currentIdx = -1;
  var _ok = 0;
  var _fail = 0;
  String? _firstErr;
  // 本次确认下载的选集索引（按下「下载 N 集」时快照，供取消按钮精确取消）。
  var _picks = <int>[];
  final _filterCtrl = TextEditingController();
  String _filter = '';

  // sheet 存活守卫：下载入队后不随弹窗关闭而中止（下载管理器是全局
  // 后台任务）。所有进度刷新经 _safeSetState，dispose 后跳过。
  bool _sheetAlive = true;

  List<VideoEpisode> get _eps => widget.detail.episodes;

  /// 某集是否已下载/下载中（入队集合也判 in 态，不重复勾选）。
  bool _isTaken(int i) {
    final e = _eps[i];
    final t = VideoDownloadManager.instance.taskOf(
      '${widget.source.id}/${widget.detail.video.id}/${e.season}-${e.episode}',
    );
    return t != null &&
        (t.isRunning ||
            (t.state == 'done' && t.localPath != null));
  }

  /// 未下载/未在途的选集（全选只选这些；已下载显示 ✓ 且不可勾选）。
  List<int> get _selectableEpisodes => [
        for (var i = 0; i < _eps.length; i++)
          if (!_isTaken(i)) i,
      ];

  /// 过滤后可见的未下载选集（全选只作用于这些）。
  List<int> get _visibleSelectable => filterEpisodeDownloadIndexes(
        _eps,
        _selectableEpisodes,
        _filter,
      );

  /// 过滤后可见的全部选集（搜索框驱动；空过滤 = 全量）。
  List<int> get _visible => filterEpisodeDownloadIndexes(
        _eps,
        [for (var i = 0; i < _eps.length; i++) i],
        _filter,
      );

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
                        // 精确取消本批：只取消本次已派发的集数任务，
                        // 不影响播放页/其它番剧在途的下载任务。
                        for (final idx in _picks) {
                          final e = _eps[idx];
                          VideoDownloadManager.instance.cancel(
                            '${widget.source.id}/${widget.detail.video.id}/${e.season}-${e.episode}',
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
                          onPressed: () => setState(() {
                            if (_selected.length ==
                                _visibleSelectable.length) {
                              _selected.clear();
                            } else {
                              // 全选 = 选中所有「可见且未下载」选集
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
                            // 反选 = 翻转当前可见未下载选集的选中态
                            final next = _invertSelection(
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
                    Expanded(
                      child: Text(
                        _currentIdx >= 0
                            ? '下载中: 第${_eps[_currentIdx].episode}集 ($_ok 成功/$_fail 失败)'
                            : '准备中…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface,
                        ),
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
                    hintText: '搜索集数 / 标题',
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
                                ? '暂无选集'
                                : '没有匹配「$_filter」的选集',
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
                        final e = _eps[idx];
                        final taken = _isTaken(idx);
                        final sel = _selected.contains(idx);
                        return CheckboxListTile(
                          value: taken || sel,
                          enabled: !_downloading && !taken,
                          onChanged: (v) => setState(
                            () => v == true
                                ? _selected.add(idx)
                                : _selected.remove(idx),
                          ),
                          title: Text(
                            '第${e.episode}集 ${e.title}',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: taken
                              ? Text(
                                  '已下载',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.primary.withValues(alpha: 0.7),
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
                    onPressed: _selected.isEmpty
                        ? null
                        : () => _startBatch(),
                    icon: Icon(
                      Icons.download_rounded,
                      size: 18,
                      color: _selected.isEmpty
                          ? null
                          : Theme.of(context).colorScheme.onPrimary,
                    ),
                    label: Text(
                      _selected.isEmpty ? '未选集' : '下载 ${_selected.length} 集',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 反选：翻转 targets 中已选中的，其余不动。
  Set<int> _invertSelection(Set<int> selected, List<int> targets) {
    final out = Set<int>.from(selected);
    for (final i in targets) {
      if (!out.add(i)) out.remove(i);
    }
    return out;
  }

  Future<void> _startBatch() async {
    _picks = _selected.toList()..sort();
    _safeSetState(() => _downloading = true);
    _ok = 0;
    _fail = 0;
    _firstErr = null;
    for (final idx in _picks) {
      final VideoEpisode e = _eps[idx];
      _safeSetState(() => _currentIdx = idx);
      try {
        final url =
            await widget.source.playUrl(widget.detail.video.id, e.season, e.episode);
        if (!isDirectMediaUrl(url)) {
          _fail++;
          _firstErr ??= '第${e.episode}集非直链，跳过';
          continue;
        }
        String referer = '';
        try {
          final u = Uri.parse(url);
          referer = '${u.scheme}://${u.host}/';
        } catch (_) {}
        await VideoDownloadManager.instance.start(
          sourceId: widget.source.id,
          videoId: widget.detail.video.id,
          title: widget.detail.video.name,
          season: e.season,
          episode: e.episode,
          url: url,
          headers: referer.isEmpty ? const {} : {'Referer': referer},
        );
        _ok++;
      } catch (err) {
        _fail++;
        _firstErr ??= '第${e.episode}集解析失败';
        ErrorLogger.instance.warn('anime batch download ep ${e.episode} failed: $err');
      }
    }
    _safeSetState(() {
      _currentIdx = -1;
      _downloading = false;
      _selected.clear();
    });
    if (_fail > 0) {
      AppToast.info(
        widget.pageContext,
        '批量下载完成：$_ok 集成功，$_fail 集失败${_firstErr != null ? '（$_firstErr）' : ''}',
        duration: const Duration(seconds: 3),
      );
    } else {
      AppToast.info(
        widget.pageContext,
        '已开始下载 $_ok 集',
        duration: const Duration(seconds: 2),
      );
    }
  }
}
