import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../net/update_checker.dart';

/// 弹出更新下载进度对话框，带进度条 + 字节数 + 百分比 + 取消按钮。
///
/// 下载完成自动关闭对话框、触发安装。
/// 返回 true 表示安装流程已启动，false 表示用户取消，抛异常表示下载失败。
Future<bool> showUpdateDownloadDialog(
  BuildContext context,
  String apkUrl,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final completer = Completer<bool>();

  showDialog<void>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (_) => _DownloadProgressDialog(
      apkUrl: apkUrl,
      onResult: (ok) {
        navigator.pop();
        completer.complete(ok);
      },
    ),
  );

  return completer.future;
}

class _DownloadProgressDialog extends StatefulWidget {
  final String apkUrl;
  final void Function(bool ok) onResult;
  const _DownloadProgressDialog({
    required this.apkUrl,
    required this.onResult,
  });

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  int _received = 0;
  int _total = 0;
  bool _cancelled = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    try {
      final path = await UpdateChecker.downloadApk(
        widget.apkUrl,
        onProgress: (cur, all) {
          if (_cancelled || !mounted) return;
          setState(() {
            _received = cur;
            _total = all;
          });
        },
        isCancelled: () => _cancelled,
      );
      if (_cancelled || !mounted) return;
      setState(() => _done = true);
      final ok = await _installApk(path);
      if (mounted) widget.onResult(ok);
    } catch (e) {
      if (!mounted) return;
      widget.onResult(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败：$e')),
        );
      }
    }
  }

  Future<bool> _installApk(String path) async {
    if (!mounted) return false;
    try {
      await MethodChannel('xingmanxia/install')
          .invokeMethod('installApk', {'path': path});
      return true;
    } catch (e) {
      debugPrint('install failed: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_done) {
          setState(() => _cancelled = true);
        }
      },
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(_done ? '下载完成' : '正在下载更新'),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _done ? 'APK 已下载，正在安装…' : '新版 APK 下载中，请稍候…',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: _total > 0
                      ? (_received / _total).clamp(0.0, 1.0)
                      : null,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _total > 0
                    ? '${_fmt(_received)} / ${_fmt(_total)}'
                        '（${((_received / _total) * 100).toStringAsFixed(1)}%）'
                    : '已下载 ${_fmt(_received)}',
                style: const TextStyle(fontSize: 11.5),
              ),
            ],
          ),
        ),
        actions: [
          if (!_done)
            TextButton(
              onPressed: () {
                setState(() => _cancelled = true);
                widget.onResult(false);
              },
              child: const Text('取消'),
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