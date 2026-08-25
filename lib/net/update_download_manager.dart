import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'update_checker.dart';

/// 后台更新下载状态。
class UpdateDownloadState {
  final int received;
  final int total;
  final String speed;
  final bool done;
  final String? error;
  const UpdateDownloadState({
    this.received = 0,
    this.total = 0,
    this.speed = '',
    this.done = false,
    this.error,
  });

  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
}

/// 全局更新下载管理器（单例）。下载脱离 Dialog 生命周期，
/// 用户返回界面或退出 App 时下载仍在后台进行，通知栏显示进度。
///
/// GitHub 下载加速：自动尝试多个镜像源，选可用的。
class UpdateDownloadManager {
  UpdateDownloadManager._();
  static final UpdateDownloadManager instance = UpdateDownloadManager._();

  static const _channel = MethodChannel('xingmanxia/update_notification');

  final _stateCtrl = StreamController<UpdateDownloadState>.broadcast();
  Stream<UpdateDownloadState> get stateStream => _stateCtrl.stream;
  UpdateDownloadState _state = const UpdateDownloadState();
  UpdateDownloadState get state => _state;

  bool _running = false;
  bool _cancelled = false;
  String? _downloadedPath;
  String? _apkPath;
  int _totalSize = 0;

  /// GitHub 加速镜像：按速度优先级排列，空字符串表示直连 GitHub。
  /// 2026-08 实测：ghproxy.net 是唯一稳定支持大文件+Range 的镜像（241KB/s）。
  static const _mirrors = <String>[
    'https://ghproxy.net/',
    'https://ghfast.top/',
    '',
  ];

  /// 慢速阈值：5 秒内平均速度低于此值则放弃当前镜像换下一个。
  static const int _minSpeedBytesPerSec = 200 * 1024; // 200 KB/s
  static const Duration _speedCheckDuration = Duration(seconds: 5);

  /// 启动后台下载（去重，已在跑就直接返回）。
  Future<void> start(String apkUrl) async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    _downloadedPath = null;
    _totalSize = 0;
    // 使用应用缓存目录（getTemporaryDirectory），而非系统级 /data/local/tmp，
    // 符合 Android 存储规范且 FileProvider 可正常分享。
    final cacheDir = await getTemporaryDirectory();
    _apkPath = '${cacheDir.path}/xingmanxia_update.apk';
    _notify('更新下载', '开始下载…', 0, 0, false);
    _state = const UpdateDownloadState();
    _stateCtrl.add(_state);
    _downloadWithMirrors(apkUrl);
  }

  /// 取消下载。
  void cancel() {
    _cancelled = true;
    _running = false;
    _state = const UpdateDownloadState(error: '已取消');
    _stateCtrl.add(_state);
    _cancelNotif();
    final p = _apkPath;
    if (p != null) {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    }
  }

  Future<void> _downloadWithMirrors(String originalUrl) async {
    final candidates = <String>[];
    for (final m in _mirrors) {
      candidates.add(m.isEmpty ? originalUrl : m + originalUrl);
    }
    Exception? lastErr;
    for (var i = 0; i < candidates.length; i++) {
      if (_cancelled) break;
      final url = candidates[i];
      final label = i == 0 ? '直连' : '镜像$i';
      try {
        final path = await _downloadOne(url, label: label);
        if (_cancelled) return;
        _downloadedPath = path;
        _state = UpdateDownloadState(
            received: _totalSize > 0 ? _totalSize : await File(path).length(),
            total: _totalSize > 0 ? _totalSize : await File(path).length(),
            done: true);
        _stateCtrl.add(_state);
        _notifyDone();
        await _triggerInstall();
        _running = false;
        return;
      } catch (e) {
        lastErr = e is Exception ? e : Exception(e.toString());
      }
    }
    if (_cancelled) return;
    _state = UpdateDownloadState(error: '全部镜像失败：$lastErr');
    _stateCtrl.add(_state);
    _notifyError();
    _running = false;
  }

  /// 下载单个 URL（带 Range 断点续传 + 速度计算）。
  /// 使用固定路径文件，切换镜像/重试时可续传。
  Future<String> _downloadOne(String url, {required String label}) async {
    final path = _apkPath;
    if (path == null) throw Exception('下载路径未初始化');
    final file = File(path);

    var received = 0;
    if (file.existsSync()) {
      received = await file.length();
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..badCertificateCallback = (c, h, p) => true;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'xingmanxia-android');
      if (received > 0) req.headers.set('Range', 'bytes=$received-');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 && res.statusCode != 206) {
        throw Exception('HTTP ${res.statusCode} ($label)');
      }

      // 服务器不支持 Range（200 且 received>0）：清空文件从头下，避免追加损坏
      if (res.statusCode == 200 && received > 0) {
        received = 0;
        if (file.existsSync()) await file.delete();
      }

      // 总大小只设一次（第一个返回 content-length 的镜像），后续镜像不覆盖
      final respTotal = res.contentLength > 0
          ? received + res.contentLength
          : (res.headers.value('content-range') != null
              ? int.parse(res.headers.value('content-range')!.split('/').last)
              : 0);
      if (respTotal > 0 && _totalSize == 0) {
        _totalSize = respTotal;
      }
      final total = _totalSize > 0 ? _totalSize : respTotal;

      final sink = file.openWrite(mode: FileMode.append);
      var lastTick = DateTime.now();
      var lastBytes = received;
      final startTime = DateTime.now();
      var speedCheckPassed = false;
      await for (final chunk in res) {
        if (_cancelled) {
          await sink.close();
          throw Exception('已取消');
        }
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        final dt = now.difference(lastTick).inMilliseconds;
        if (dt >= 500) {
          final speedBytes = (received - lastBytes) / (dt / 1000);
          lastBytes = received;
          lastTick = now;
          // 慢速检测：前 10 秒内平均速度 < 50KB/s 则放弃当前镜像换下一个。
          // 不删除已下载文件，下一个镜像用 Range 续传。
          if (!speedCheckPassed &&
              now.difference(startTime).inMilliseconds >=
                  _speedCheckDuration.inMilliseconds) {
            final avgSpeed = received / now.difference(startTime).inMilliseconds * 1000;
            if (avgSpeed < _minSpeedBytesPerSec) {
              await sink.close();
              throw Exception('速度太慢 ${_fmtSpeed(avgSpeed)} ($label)');
            }
            speedCheckPassed = true;
          }
          final speedStr = _fmtSpeed(speedBytes);
          _state = UpdateDownloadState(
              received: received, total: total, speed: speedStr);
          _stateCtrl.add(_state);
          _notify('更新下载', '$label $speedStr', received, total, false);
        }
      }
      await sink.close();
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  /// 通过 MethodChannel 调用原生通知（进度条）。
  Future<void> _notify(
      String title, String text, int received, int total, bool done) async {
    try {
      await _channel.invokeMethod('showProgress', {
        'title': title,
        'text': text,
        'received': received,
        'total': total,
        'done': done,
      });
    } catch (_) {}
  }

  Future<void> _notifyDone() async {
    try {
      await _channel.invokeMethod('showDone', {
        'title': '更新下载完成',
        'text': '点击安装新版本',
        'path': _downloadedPath ?? '',
      });
    } catch (_) {}
  }

  Future<void> _notifyError() async {
    try {
      await _channel.invokeMethod('showError', {
        'title': '更新下载失败',
        'text': '所有镜像均失败，请稍后重试或手动下载',
      });
    } catch (_) {}
  }

  Future<void> _cancelNotif() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  Future<void> _triggerInstall() async {
    final path = _downloadedPath;
    if (path == null) return;
    try {
      await UpdateChecker.installApk(path);
    } catch (e) {
      _state = UpdateDownloadState(
          error: '安装失败：$e（可到文件管理器手动安装）');
      _stateCtrl.add(_state);
      _notifyInstall(path);
      _running = false;
    }
  }

  /// 发送可点击安装的通知（自动安装失败时备用）。
  Future<void> _notifyInstall(String path) async {
    try {
      await _channel.invokeMethod('showInstall', {'path': path});
    } catch (_) {}
  }

  String _fmtSpeed(double bytesPerSec) {
    if (bytesPerSec >= 1048576) {
      return '${(bytesPerSec / 1048576).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSec >= 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytesPerSec.round()} B/s';
  }
}