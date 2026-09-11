import 'dart:io';

import 'package:archive/archive.dart' as archive_pkg;
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/error_logger.dart';

/// 本地错误日志系统回归：分级记录、内存缓冲、按天落盘、导出 zip。
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

    test('导出日志为 zip（含设备/版本头 + 各日志文件 + logs.txt）', () async {
      ErrorLogger.instance.setAppVersion('9.9.9');
      ErrorLogger.instance.info('hello');
      final out = await ErrorLogger.instance.exportLogs();
      expect(out, isNotNull);
      final f = File(out!);
      expect(f.existsSync(), isTrue);
      expect(f.path.endsWith('.zip'), isTrue, reason: '导出应为 zip 压缩包');
      // 解包验证：含当日日志 + logs.txt（含设备/版本头）
      final bytes = f.readAsBytesSync();
      final archive = archive_pkg.ZipDecoder().decodeBytes(bytes);
      expect(archive.isEmpty, isFalse);
      final logsTxt = archive.files.firstWhere(
        (e) => e.name == 'logs.txt',
        orElse: () => throw StateError('zip 缺 logs.txt'),
      );
      final content = String.fromCharCodes(logsTxt.content);
      expect(content.contains('app version: v9.9.9'), isTrue);
      expect(content.contains('hello'), isTrue);
      // 各日日志独立归档也在包内
      expect(archive.files.any((e) => e.name.endsWith('.log')), isTrue,
          reason: 'zip 应包含各日 .log 独立文件');
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
