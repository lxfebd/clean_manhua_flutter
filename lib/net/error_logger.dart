import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 本地错误日志系统：崩溃 / 解析失败 / 网络错误按天滚动记录到本地文件，
/// 保留 7 天。纯本地存储不上传，用户可在设置页一键导出压缩包反馈问题。
class ErrorLogger {
  ErrorLogger._();

  static final ErrorLogger instance = ErrorLogger._();

  /// 日志级别（DEBUG < INFO < WARN < ERROR）。
  static const int levelDebug = 0;
  static const int levelInfo = 1;
  static const int levelWarn = 2;
  static const int levelError = 3;

  static const String _dirName = 'logs';
  static const int _keepDays = 7;
  static const int _maxFileBytes = 2 * 1024 * 1024; // 单日文件超 2MB 截断写尾部

  Directory? _dir;
  final List<String> _buffer = [];
  bool _installed = false;
  String _appVersion = '';
  String _deviceInfo = '';

  /// 应用启动时调用：初始化日志目录、安装全局异常捕获、写入设备/版本头。
  Future<void> init() async {
    try {
      // web 端无文件系统：跳过日志落盘，仅安装全局异常捕获（Buffer 日志仍可用）。
      if (!kIsWeb) {
        final base = await getApplicationSupportDirectory();
        final d = Directory('${base.path}/$_dirName');
        if (!d.existsSync()) d.createSync(recursive: true);
        _dir = d;
        _pruneOldLogs();
      }
      if (!_installed) {
        _installed = true;
        _installGlobalHandlers();
      }
      if (!kIsWeb) {
        unawaited(_collectDeviceInfo());
      }
    } catch (e) {
      debugPrint('ErrorLogger init failed: $e');
    }
  }

  /// 安装全局异常/错误捕获（幂等，init 调用一次）。
  void _installGlobalHandlers() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      logError('FlutterError: ${details.exception}',
          stack: details.stack?.toString() ?? '');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      logError('PlatformDispatcher: $error', stack: stack.toString());
      return true; // 已处理，不交给系统默认崩溃对话框
    };
  }

  /// 收集设备与版本信息，写入当日日志头（异步，不阻塞启动）。
  Future<void> _collectDeviceInfo() async {
    try {
      final plugin = DeviceInfoPlugin();
      final buf = StringBuffer('device: ');
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await plugin.androidInfo;
          buf.write('android ${a.version.release} (sdk ${a.version.sdkInt}) '
              '${a.manufacturer} ${a.model}');
        case TargetPlatform.iOS:
          final i = await plugin.iosInfo;
          buf.write('ios ${i.systemVersion} ${i.utsname.machine}');
        case TargetPlatform.windows:
          final w = await plugin.windowsInfo;
          buf.write('windows ${w.majorVersion}.${w.minorVersion}.${w.buildNumber}');
        case TargetPlatform.macOS:
          buf.write('macos');
        case TargetPlatform.linux:
          buf.write('linux');
        default:
          buf.write(defaultTargetPlatform.name);
      }
      _deviceInfo = buf.toString();
      info('$_deviceInfo | app v$_appVersion');
    } catch (_) {
      info('device info unavailable | app v$_appVersion');
    }
  }

  /// 设置应用版本号（启动时从 PackageInfo 读取后写入，用于日志头）。
  void setAppVersion(String v) {
    _appVersion = v;
  }

  /// 记录调试级日志。
  void debug(String message) => _write(levelDebug, message, null);

  /// 记录信息级日志（常规事件，如启动完成、同步成功）。
  void info(String message) => _write(levelInfo, message, null);

  /// 记录警告级日志（可恢复的异常，如某源请求失败）。
  void warn(String message, {String? stack}) =>
      _write(levelWarn, message, stack);

  /// 记录错误级日志（崩溃 / 解析失败 / 网络错误）。
  void error(String message, {String? stack, Object? error}) =>
      _write(levelError, message, stack ?? (error?.toString()));

  /// [error] 的别名，语义与项目内 `debugPrint` 对齐。
  void logError(String message, {String? stack, Object? error}) =>
      _write(levelError, message, stack ?? (error?.toString()));

  static String _levelName(int l) => switch (l) {
        levelDebug => 'DEBUG',
        levelInfo => 'INFO',
        levelWarn => 'WARN',
        _ => 'ERROR',
      };

  void _write(int level, String message, String? stack) {
    // 测试环境（无目录）仅进内存缓冲，供单测断言
    final now = DateTime.now();
    final line = '[${_fmt(now)}] ${_levelName(level)} $message'
        '${stack == null || stack.isEmpty ? '' : '\n$stack'}';
    _buffer.add(line);
    if (_buffer.length > 200) _buffer.removeAt(0);
    final d = _dir;
    if (d == null) return;
    try {
      final f = File('${d.path}/${_fileName(now)}.log');
      final toWrite = '$line\n';
      if (f.existsSync() && f.lengthSync() > _maxFileBytes) {
        // 单日文件超限：只保留尾部（截断写），避免日志无限膨胀
        final existing = f.readAsStringSync();
        final keep = existing.length > 4096
            ? existing.substring(existing.length - 4096)
            : existing;
        f.writeAsStringSync('$keep$toWrite', flush: true);
      } else {
        f.writeAsStringSync(toWrite, mode: FileMode.append, flush: true);
      }
    } catch (e) {
      debugPrint('ErrorLogger write failed: $e');
    }
  }

  static String _fmt(DateTime t) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} '
        '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }

  static String _fileName(DateTime t) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)}';
  }

  /// 删除超过 [_keepDays] 天的旧日志文件。
  void _pruneOldLogs() {
    try {
      final d = _dir;
      if (d == null) return;
      final cutoff = DateTime.now()
          .subtract(Duration(days: _keepDays))
          .millisecondsSinceEpoch;
      for (final f in d.listSync().whereType<File>()) {
        try {
          if (f.statSync().modified.millisecondsSinceEpoch < cutoff) {
            f.deleteSync();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 今日日志文件绝对路径（导出用）。
  String get todayLogPath => _dir == null
      ? ''
      : '${_dir!.path}/${_fileName(DateTime.now())}.log';

  /// 日志目录路径（导出用）。
  String? get logDirPath => _dir?.path;

  /// 导出日志：把所有日志文件合并为一个文本文件（含设备信息头），
  /// 返回文件路径。失败返回 null（目录不存在 / 无日志）。
  Future<String?> exportLogs() async {
    final d = _dir;
    if (d == null || !d.existsSync()) return null;
    final files = d.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) return null;
    try {
      final out =
          File('${d.path}/logs_${DateTime.now().millisecondsSinceEpoch}.txt');
      final sink = out.openWrite();
      try {
        sink.write('== 星漫匣 错误日志 ==\n');
        if (_deviceInfo.isNotEmpty) sink.write('$_deviceInfo\n');
        sink.write('app version: v$_appVersion\n');
        sink.write('exported: ${_fmt(DateTime.now())}\n');
        sink.write('========================\n\n');
        for (final f in files) {
          sink.write('---- ${f.uri.pathSegments.last} ----\n');
          // 日志文件为 UTF-8 文本，直接写字符串（字节列表会被 toString 成数字数组）
          sink.write(f.readAsStringSync());
          sink.write('\n\n');
        }
      } finally {
        await sink.close();
      }
      return out.path;
    } catch (e) {
      debugPrint('ErrorLogger export failed: $e');
      return null;
    }
  }

  /// 测试辅助：最近的内存日志行（不含时间戳前缀）。
  @visibleForTesting
  List<String> debugBuffer() => List.of(_buffer);

  /// 测试辅助：清空内存缓冲（不影响已写盘文件）。
  @visibleForTesting
  void debugReset() {
    _buffer.clear();
  }

  /// 测试辅助：直接指定日志目录（绕过 path_provider），便于单测。
  /// 只设置目录不安装全局 handler，避免覆盖测试框架的 FlutterError 处理。
  @visibleForTesting
  void debugSetDir(Directory d) {
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
  }
}
