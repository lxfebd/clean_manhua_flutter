import 'package:flutter/material.dart';

import '../responsive.dart';
import '../tokens.dart';
import 'app_toast.dart';

/// 批量下载选择骨架底部弹窗（P1-21：detail_batch_download_sheet 与
/// episode_batch_download_sheet 两套复制粘贴合一）。
///
/// 两套旧实现逐行同构：标题行 +（选中后）取消 /（未选中）全选未下载+反选、
/// 搜索框、CheckboxListTile 列表（已下载✓禁选）、启动按钮、[下载中] 进度行、
/// sheet 存活守卫（_safeSetState：关闭后下载仍继续，不因 setState 中断）。
/// 业务差异全部参数化为回调：
/// - 条目模型泛型 [E]（漫画 [Chapter] / 动漫 [VideoEpisode]）；
/// - 显示 [titleOf]/[subtitleOf]（已下载/已读脚注）；
/// - 占用判定 [isTaken]（已下载或在途 → 禁选+✓）；
/// - 过滤纯函数 [filter]（各自文件已有，测试独立）；
/// - 下载执行 [downloadOne]：串行 await 返回该项是否成功
///   （漫画版逐章下载并上报页级进度；动漫版解析入队即成功）；
/// - 精确取消 [cancelPicks]（只取消本批已派发的任务）；
/// - 附加头部控件 [headerExtras]（漫画画质档位行；动漫无）。
/// 弹窗内全部本地状态在本 State，不依赖宿主页面。
/// 命名带 Core 后缀：与各端适配器 [showBatchDownloadSheet] 区分（后者是
/// 页面直接调用的公开 API，本函数只被适配器调用）。
Future<void> showBatchDownloadSheetCore<E>(
  BuildContext context, {
  required List<E> items,
  required String Function(E item, int index) titleOf,
  required Widget? Function(E item, int index, {required bool taken})
      subtitleOf,
  required bool Function(E item, int index) isTaken,
  required List<int> Function(List<int> candidates, String filter) filter,
  required Future<bool> Function(
    E item,
    int index,
    void Function(int done, int total)? onProgress,
  )
      downloadOne,
  required void Function(List<int> picks) cancelPicks,
  required String Function(int ok, int fail, String? firstErr) doneMessage,
  Widget? headerExtras,

  /// 收尾通知回调（sheet 关闭后触发；页面已退出时调用方自行判断是否可达）。
  /// 漫画侧用它发系统通知兜底；动漫侧原实现无系统通知，可不传。
  void Function(int ok, int fail, String? firstErr)? onFinished,
  String title = '批量下载',
}) {
  if (items.isEmpty) return Future.value();
  return showResponsiveBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _BatchDownloadSheetBody<E>(
      items: items,
      title: title,
      titleOf: titleOf,
      subtitleOf: subtitleOf,
      isTaken: isTaken,
      filter: filter,
      downloadOne: downloadOne,
      cancelPicks: cancelPicks,
      doneMessage: doneMessage,
      onFinished: onFinished,
      headerExtras: headerExtras,
      pageContext: context,
    ),
  ).then((_) {});
}

class _BatchDownloadSheetBody<E> extends StatefulWidget {
  final List<E> items;
  final String title;
  final String Function(E item, int index) titleOf;
  final Widget? Function(E item, int index, {required bool taken}) subtitleOf;
  final bool Function(E item, int index) isTaken;
  final List<int> Function(List<int> candidates, String filter) filter;
  final Future<bool> Function(
    E item,
    int index,
    void Function(int done, int total)? onProgress,
  )
      downloadOne;
  final void Function(List<int> picks) cancelPicks;
  final String Function(int ok, int fail, String? firstErr) doneMessage;
  final void Function(int ok, int fail, String? firstErr)? onFinished;
  final Widget? headerExtras;
  // 页面 context：下载完成时 AppToast 需落在页面 Overlay（sheet 已 pop）。
  final BuildContext pageContext;

  const _BatchDownloadSheetBody({
    required this.items,
    required this.title,
    required this.titleOf,
    required this.subtitleOf,
    required this.isTaken,
    required this.filter,
    required this.downloadOne,
    required this.cancelPicks,
    required this.doneMessage,
    required this.onFinished,
    required this.headerExtras,
    required this.pageContext,
  });

  @override
  State<_BatchDownloadSheetBody<E>> createState() =>
      _BatchDownloadSheetBodyState<E>();
}

class _BatchDownloadSheetBodyState<E>
    extends State<_BatchDownloadSheetBody<E>> {
  final _selected = <int>{};
  bool _downloading = false;
  int _currentIdx = -1;
  int _currentDone = 0;
  int _currentTotal = 0;
  var _ok = 0;
  var _fail = 0;
  String? _firstErr;
  // 本次确认下载的条目索引（按下「下载 N 项」时快照，供取消按钮精确取消）。
  var _picks = <int>[];
  final _filterCtrl = TextEditingController();
  String _filter = '';

  // sheet 存活守卫：批量下载闭包不随弹窗存活而中止——下载管理器是全局
  // 后台任务，弹窗关闭（点遮罩/返回/切页）后下载必须继续跑。所有进度
  // 刷新都经 _safeSetState：sheet 已 dispose 时直接跳过（State 的
  // setState 在 dispose 后调用会抛错，未捕获会让整个下载循环终止，
  // 表现为「退出页面下载就停/显示失败」）。
  bool _sheetAlive = true;

  /// 未下载/未在途的条目（全选只选这些；已下载显示 ✓ 且不可勾选）。
  List<int> get _selectable => [
        for (var i = 0; i < widget.items.length; i++)
          if (!widget.isTaken(widget.items[i], i)) i,
      ];

  /// 过滤后可见的未下载条目（全选只作用于这些）。
  List<int> get _visibleSelectable =>
      widget.filter(_selectable, _filter);

  /// 过滤后可见的全部条目（搜索框驱动；空过滤 = 全量）。
  List<int> get _visible => widget.filter(
        [for (var i = 0; i < widget.items.length; i++) i],
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

  void _closeSheet() {
    if (!_sheetAlive) return;
    _sheetAlive = false;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _startBatch() async {
    _picks = _selected.toList()..sort();
    _safeSetState(() => _downloading = true);
    _ok = 0;
    _fail = 0;
    _firstErr = null;
    _currentIdx = -1;
    _currentDone = 0;
    _currentTotal = 0;
    for (final idx in _picks) {
      // 本批内被精确取消：停止后续任务（取消按钮已置 _downloading=false，
      // 但已入队的后续任务仍会走到这里，需主动跳出）。
      if (!_downloading) break;
      _safeSetState(() {
        _currentIdx = idx;
        _currentDone = 0;
        _currentTotal = 0;
      });
      try {
        final okItem = await widget.downloadOne(
          widget.items[idx],
          idx,
          (d, t) => _safeSetState(() {
            _currentDone = d;
            _currentTotal = t;
          }),
        );
        if (okItem) {
          _ok++;
        } else {
          _fail++;
          _firstErr ??= '第${idx + 1}项下载失败';
        }
      } catch (e) {
        _fail++;
        _firstErr ??= '第${idx + 1}项解析失败';
      }
    }
    // 用户点「取消」按钮时 _downloading 已置 false：只关窗不弹 toast
    //（取消是用户主动行为）。
    if (!_downloading) {
      _closeSheet();
      return;
    }
    _closeSheet();
    // 页面内 Toast：落 sheet 宿主页面 Overlay（sheet 已 pop，用 pageContext）。
    final msg = widget.doneMessage(_ok, _fail, _firstErr);
    if (msg.isNotEmpty && widget.pageContext.mounted) {
      AppToast.show(widget.pageContext, msg, error: _fail > 0);
    }
    // 系统通知兜底（页面已退出时告知结果）：调用方自行实现。
    widget.onFinished?.call(_ok, _fail, _firstErr);
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
                    widget.title,
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
                        // 精确取消本批：只取消本次已派发的任务，
                        // 不影响阅读页/播放页/其它页面在途下载。
                        widget.cancelPicks(_picks);
                        _safeSetState(() => _downloading = false);
                      },
                      child: const Text('取消'),
                    )
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            if (_selected.length == _visibleSelectable.length) {
                              _selected.clear();
                            } else {
                              // 全选 = 选中所有「可见且未下载」条目
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
                            // 反选 = 翻转当前可见未下载条目的选中态
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
            if (!_downloading && widget.headerExtras != null)
              widget.headerExtras!,
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
                            ? '下载中: 第${_currentIdx + 1}项 ($_ok 成功/$_fail 失败'
                                  '${_currentTotal > 0 ? ' · $_currentDone/$_currentTotal' : ''})'
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
                    hintText: '搜索标题',
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
                                ? '暂无内容'
                                : '没有匹配「$_filter」的内容',
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
                        final e = widget.items[idx];
                        final taken = widget.isTaken(e, idx);
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
                            widget.titleOf(e, idx),
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: widget.subtitleOf(e, idx, taken: taken),
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
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(
                      _selected.isEmpty
                          ? '请选择'
                          : '下载 ${_selected.length} 项',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 反选：翻转 targets 内索引选中态，其余不变。
  Set<int> _invertSelection(Set<int> selected, List<int> targets) {
    final out = Set<int>.from(selected);
    for (final i in targets) {
      if (!out.add(i)) out.remove(i);
    }
    return out;
  }
}