import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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

  // P1-34：日志写盘异步化。旧实现每条日志都 `writeAsStringSync(flush: true)`，
  // 在主 isolate 上同步等平台 I/O——解析失败/网络错误是高频路径，滑动阅读时
  // 这些调用会直接变成掉帧。
  //
  // 约束（audit 红线）：不能为了不卡 UI 就静默丢日志。所以：
  // - 待写队列 + 防抖批量写（默认 1s 合并一次）；
  // - 队列超上限时**写入一条明确的丢弃标记**，绝不静默吞；
  // - 导出、切后台、进程退出前都 flush，保证用户反馈的日志完整。
  final List<String> _pending = [];
  Timer? _flushTimer;
  IOSink? _sink;
  String? _sinkPath;

  static const int _maxPending = 2000;
  static const Duration _flushDebounce = Duration(seconds: 1);

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
  /// 本项目错误记录统一走 [logError]，与 `debugPrint` 的语义对齐。
  void logError(String message, {String? stack, Object? error}) =>
      _write(levelError, message, stack ?? (error?.toString()));

  static String _levelName(int l) => switch (l) {
        levelDebug => 'DEBUG',
        levelInfo => 'INFO',
        levelWarn => 'WARN',
        _ => 'ERROR',
      };

  /// 日志脱敏（P2-19）。纯函数，便于单测。
  ///
  /// 日志会被用户一键导出并转发给我们（反馈 zip），所以写下的每一行都要按
  /// 「可能外传」的标准处理：Authorization/Cookie 头、URL 里的用户口令、以及
  /// token/apikey/signature/session 一类敏感查询参数。掩码保留可诊断的形状
  /// （看得出来是哪个字段），但不泄露值。
  static String redactSensitive(String input) {
    var s = input;
    // Order matters: the Bearer/Basic rules must run BEFORE the header
    // rules, otherwise the header rule eats the word Bearer first and
    // the token body after it survives unmasked.
    // Dart RegExp gotchas: caseSensitive defaults to TRUE (pass false);
    // String.replaceAll replacement is literal ($1 not resolved) ->
    // use replaceAllMapped when a capture group must be kept.
    // 1) Bearer / Basic token body (run first, see note above)
    s = s.replaceAll(RegExp(r'\bbearer\s+\S+', caseSensitive: false), 'Bearer ***');
    s = s.replaceAll(RegExp(r'\bbasic\s+[A-Za-z0-9+/=]+', caseSensitive: false), 'Basic ***');
    // 2) sensitive headers
    s = s.replaceAllMapped(
        RegExp(r'(authorization\s*[:=]\s*)(\S+)', caseSensitive: false),
        (m) => '${m[1]}***');
    s = s.replaceAllMapped(
        RegExp(r'(proxy-authorization\s*[:=]\s*)(\S+)', caseSensitive: false),
        (m) => '${m[1]}***');
    s = s.replaceAllMapped(
        RegExp(r'(cookie\s*[:=]\s*)(\S+)', caseSensitive: false),
        (m) => '${m[1]}***');
    s = s.replaceAllMapped(
        RegExp(r'(set-cookie\s*[:=]\s*)(\S+)', caseSensitive: false),
        (m) => '${m[1]}***');
    // 3) URL userinfo password: https://user:pass@host
    s = s.replaceAllMapped(
        RegExp(r'([a-z][a-z0-9+.-]*://[^/\s:@]+):([^/\s@]+)@', caseSensitive: false),
        (m) => '${m[1]}:***@');
    // 4) sensitive query parameter values
    s = s.replaceAllMapped(
        RegExp(
            r'([?&](?:token|access_token|apikey|api_key|key|password|passwd|pwd|sig|signature|sign|session|sessionid|auth|cookie|secret)=)[^&\s]+',
            caseSensitive: false),
        (m) => '${m[1]}***');
    return s;
  }

  void _write(int level, String message, String? stack) {
    // 测试环境（无目录）仅进内存缓冲，供单测断言
    message = redactSensitive(message);
    final now = DateTime.now();
    final line = '[${_fmt(now)}] ${_levelName(level)} $message'
        '${stack == null || stack.isEmpty ? '' : '\n${redactSensitive(stack)}'}';
    _buffer.add(line);
    if (_buffer.length > 200) _buffer.removeAt(0);
    final d = _dir;
    if (d == null) return;
    // P1-34：只入队 + 安排一次批量写盘，绝不在主 isolate 上等 I/O。
    _pending.add('$line\n');
    if (_pending.length > _maxPending) {
      // 写盘跟不上：丢弃最早的一批，但**留下可追溯的标记**——静默丢日志
      // 会让用户反馈回来的日志缺一段，而我们无从得知。
      final drop = _pending.length - _maxPending;
      _pending.removeRange(0, drop);
      _pending.insert(
          0, '[${_fmt(now)}] WARN [logger] dropped $drop earlier line(s) '
              '(write backlog exceeded \$_maxPending)\n');
    }
    _scheduleFlush();
  }

  /// 安排一次（防抖）批量写盘。
  void _scheduleFlush() {
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(_flushDebounce, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// 把队列里的日志批量写入当日文件。公开：导出 / 切后台 / 测试都 await 它。
  ///
  /// 失败时保留队列（下次 flush 重试），不写入丢弃标记之外的垃圾。
  Future<void> flush() async {
    final d = _dir;
    if (d == null || _pending.isEmpty) return;
    try {
      final target = '${d.path}/${_fileName(DateTime.now())}.log';
      // 日期滚动 / 目录被 debugSetDir 换过：关掉旧 sink 重开。
      if (_sink == null || _sinkPath != target) {
        await _closeSink();
        await _openSink(target);
      }
      final sink = _sink;
      if (sink == null) return;
      final batch = List<String>.of(_pending);
      sink.writeAll(batch);
      await sink.flush();
      _pending.removeRange(0, batch.length);
    } catch (e) {
      debugPrint('ErrorLogger flush failed: $e');
      // 队列保留，下次 flush 再试；极端情况下可能被上限标记裁剪，但不静默丢。
    }
  }

  /// 打开写入口；单日文件超限时先截断成「只保留尾部」，避免日志无限膨胀。
  Future<void> _openSink(String path) async {
    final f = File(path);
    try {
      if (await f.exists() && await f.length() > _maxFileBytes) {
        final existing = await f.readAsString();
        final keep =
            existing.length > 4096 ? existing.substring(existing.length - 4096) : existing;
        await f.writeAsString(keep, flush: true);
      }
    } catch (e) {
      debugPrint('ErrorLogger truncate failed: $e');
    }
    _sink = f.openWrite(mode: FileMode.append);
    _sinkPath = path;
  }

  Future<void> _closeSink() async {
    final s = _sink;
    _sink = null;
    _sinkPath = null;
    if (s == null) return;
    try {
      await s.flush();
      await s.close();
    } catch (_) {}
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

  /// 导出日志：打包为 zip 压缩包（含设备信息头 + 各日日志独立文件 +
  /// 按日排序合并的 logs.txt），返回文件路径。失败返回 null（目录不存在 / 无日志）。
  Future<String?> exportLogs() async {
    // P1-34：导出前必须先 flush——写盘是异步批量的，否则用户刚遇到的 bug
    // （通常正是触发日志的那条）不在导出的 zip 里。
    await flush();
    final d = _dir;
    if (d == null || !d.existsSync()) return null;
    // P2-19：只导出当日/历史 .log 文本。旧实现把目录下所有 File 都打进去，
    // 上一次导出的 zip 会被二次塞进新 zip（越滚越大、还可能把旧日志重复外传）。
    final files = d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) return null;
    String outPath = '';
    try {
      outPath = '${d.path}/logs_${DateTime.now().millisecondsSinceEpoch}.zip';
      // 1) 设备/版本头 + 各日志按日合并的 logs.txt（反馈快速浏览入口）
      final combined = StringBuffer()
        ..write('== 星漫匣 错误日志 ==\n')
        ..write('${_deviceInfo.isEmpty ? 'device: unknown' : _deviceInfo}\n')
        ..write('app version: v$_appVersion\n')
        ..write('exported: ${_fmt(DateTime.now())}\n')
        ..write('========================\n\n');
      for (final f in files) {
        combined
          ..write('---- ${f.uri.pathSegments.last} ----\n')
          ..write(f.readAsStringSync())
          ..write('\n\n');
      }
      // 2) 各日日志独立归档（便于按天查看/对比）
      // codeUnits 是 UTF-16 码元（中文日志会变成乱码字节），
      // 必须 utf8.encode 才是 zip 里正确的 UTF-8 内容。
      final combinedBytes = utf8.encode(combined.toString());
      final archive = Archive()
        ..addFile(
            ArchiveFile('logs.txt', combinedBytes.length, combinedBytes));
      for (final f in files) {
        final bytes = f.readAsBytesSync();
        archive.addFile(
            ArchiveFile(f.uri.pathSegments.last, bytes.length, bytes));
      }
      final zipBytes = ZipEncoder().encode(archive);
      await File(outPath).writeAsBytes(zipBytes, flush: true);
      return outPath;
    } catch (e) {
      debugPrint('ErrorLogger export failed: $e');
      // 删除可能残留的半成品 zip
      try {
        if (outPath.isNotEmpty) File(outPath).deleteSync();
      } catch (_) {}
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
    // 换目录后旧 sink/队列都不再生效：关掉 sink 并丢弃待写（测试目录是隔离的）。
    _pending.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    unawaited(_closeSink());
  }

  /// 测试辅助：等待异步队列全部落盘（P1-34 写盘异步化后，断言落盘内容用）。
  @visibleForTesting
  Future<void> debugFlush() => flush();
}
