import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/error_logger.dart';

/// 本地错误日志系统回归：分级记录、内存缓冲、按天落盘、导出合并。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('xm_errlog_');
    ErrorLogger.instance.debugReset();
    ErrorLogger.instance.debugSetDir(tmpDir);
  });

  tearDown(() {
    ErrorLogger.instance.debugReset();
    ErrorLogger.instance.debugSetDir(tmpDir);
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ErrorLogger 本地日志', () {
    test('分级记录进入内存缓冲（debug/info/warn/error）', () {
      final logger = ErrorLogger.instance;
      logger.debug('d1');
      logger.info('i1');
      logger.warn('w1');
      logger.error('e1');
      logger.logError('e2', stack: 'stack line');
      final buf = logger.debugBuffer();
      expect(buf.any((l) => l.contains('DEBUG d1')), isTrue);
      expect(buf.any((l) => l.contains('INFO i1')), isTrue);
      expect(buf.any((l) => l.contains('WARN w1')), isTrue);
      expect(buf.any((l) => l.contains('ERROR e1')), isTrue);
      // stack 随 error 一起记录
      expect(buf.any((l) => l.contains('e2') && l.contains('stack line')),
          isTrue);
    });

    test('记录落盘为当日 .log 文件', () {
      ErrorLogger.instance.error('boom');
      final files = tmpDir.listSync().whereType<File>().toList();
      expect(files.length, 1);
      final content = files.first.readAsStringSync();
      expect(content.contains('ERROR boom'), isTrue);
      expect(content.contains('['), isTrue); // 时间戳前缀
    });

    test('导出合并日志为单个 txt（含设备/版本头）', () async {
      ErrorLogger.instance.setAppVersion('9.9.9');
      ErrorLogger.instance.info('hello');
      final out = await ErrorLogger.instance.exportLogs();
      expect(out, isNotNull);
      final f = File(out!);
      expect(f.existsSync(), isTrue);
      final content = f.readAsStringSync();
      expect(content.contains('app version: v9.9.9'), isTrue);
      expect(content.contains('ERROR'), isFalse); // 无 error 只有 info
      expect(content.contains('hello'), isTrue);
    });

    test('空目录导出返回 null（无日志可导出）', () async {
      final empty = Directory.systemTemp.createTempSync('xm_errlog_empty_');
      ErrorLogger.instance.debugSetDir(empty);
      final out = await ErrorLogger.instance.exportLogs();
      expect(out, isNull);
      try {
        empty.deleteSync(recursive: true);
      } catch (_) {}
    });
  });
}
