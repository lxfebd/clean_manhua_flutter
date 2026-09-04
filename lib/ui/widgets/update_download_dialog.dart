import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../net/update_download_manager.dart';

/// 弹出更新下载进度对话框，带进度条 + 字节数 + 百分比 + 取消按钮。
///
/// 下载由全局 [UpdateDownloadManager] 管理，用户关闭对话框或离开页面
/// 下载仍会在后台继续，并在通知栏显示实时进度。
Future<bool> showUpdateDownloadDialog(
  BuildContext context,
  String apkUrl,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final completer = Completer<bool>();

  // 已在下载就直接打开进度窗口
  if (UpdateDownloadManager.instance.state.received == 0 &&
      UpdateDownloadManager.instance.state.total == 0 &&
      !UpdateDownloadManager.instance.state.done) {
    UpdateDownloadManager.instance.start(apkUrl);
  }

  showDialog<void>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (_) => _DownloadProgressDialog(
      onResult: (ok) {
        navigator.pop();
        completer.complete(ok);
      },
    ),
  );

  return completer.future;
}

class _DownloadProgressDialog extends StatefulWidget {
  final void Function(bool ok) onResult;
  const _DownloadProgressDialog({required this.onResult});

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  UpdateDownloadState _state = const UpdateDownloadState();
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _state = UpdateDownloadManager.instance.state;
    _sub = UpdateDownloadManager.instance.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
      if (s.done || s.error != null) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) widget.onResult(s.done);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _state.done;
    final failed = _state.error != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !done && failed == false) {
          // 返回不取消下载，仅关闭弹窗提示
          widget.onResult(false);
        }
      },
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(done ? '下载完成' : failed ? '下载失败' : '正在下载更新'),
        content: SizedBox(
          width: math.min(MediaQuery.of(context).size.width * 0.85, 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                done
                    ? '安装包已就绪，请稍候…'
                    : failed
                        ? '${_state.error}\n\n可稍后从「设置 → 检查更新」重试，或到 GitHub Releases 手动下载。'
                        : '后台下载中，关闭本窗口不会中断\n返回界面或退出 App 均继续下载',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: failed || done ? null : _state.progress,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    _state.total > 0
                        ? '${_fmt(_state.received)} / ${_fmt(_state.total)}'
                            '（${(_state.progress * 100).toStringAsFixed(0)}%）'
                        : '已下载 ${_fmt(_state.received)}',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  const Spacer(),
                  if (_state.speed.isNotEmpty)
                    Text(
                      _state.speed,
                      style: TextStyle(
                          fontSize: 11.5, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          if (!done && !failed)
            TextButton(
              onPressed: () {
                UpdateDownloadManager.instance.cancel();
                widget.onResult(false);
              },
              child: const Text('取消'),
            )
          else
            TextButton(
              onPressed: () => widget.onResult(done),
              child: const Text('关闭'),
            ),
        ],
      ),
    );
  }

  String _fmt(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}