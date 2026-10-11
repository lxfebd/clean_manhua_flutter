import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_migration');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmp.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('LocalStore schema 迁移框架', () {
    test('init 后 schema_version 写入当前版本', () async {
      await LocalStore.init();
      final v = await LocalStore.readJson('schema_version');
      expect(v, LocalStore.schemaVersion);
    });
    test('重复 init 幂等：版本不倒退不重复写', () async {
      await LocalStore.init();
      final f = File('${tmp.path}/data/schema_version.json');
      final before = await f.readAsString();
      await LocalStore.init();
      expect(await f.readAsString(), before);
      final v = await LocalStore.readJson('schema_version');
      expect(v, LocalStore.schemaVersion);
    });

    test('旧版本文件升级：schema_version 从缺省推进到当前版', () async {
      // 清掉版本文件模拟老安装
      final f = File('${tmp.path}/data/schema_version.json');
      if (f.existsSync()) f.deleteSync();
      await LocalStore.init();
      expect(await LocalStore.readJson('schema_version'),
          LocalStore.schemaVersion);
    });

    test('v2 迁移：video_progress 的 `::` key 改写为 `/` 分隔（P2-15）', () async {
      // 模拟 v1 安装：先写旧格式进度 + 版本 1，再 init 触发迁移。
      final dir = '${tmp.path}/data';
      Directory(dir).createSync(recursive: true);
      File('$dir/video_progress.json').writeAsStringSync(jsonEncode({
        'src::vid::1-3': 42,
        'src::vid2::2-1': 15,
      }));
      File('$dir/schema_version.json').writeAsStringSync(jsonEncode(1));
      await LocalStore.init();
      final raw = await LocalStore.readJson('video_progress') as Map;
      expect(raw, {'src/vid/1-3': 42, 'src/vid2/2-1': 15});
      expect(raw.keys.any((k) => k.contains('::')), isFalse);
    });

    test('v2 迁移幂等：已是 `/` 分隔时不改写', () async {
      final dir = '${tmp.path}/data';
      Directory(dir).createSync(recursive: true);
      File('$dir/video_progress.json').writeAsStringSync(jsonEncode({
        'src/vid/1-3': 42,
      }));
      File('$dir/schema_version.json').writeAsStringSync(jsonEncode(1));
      await LocalStore.init();
      expect(await LocalStore.readJson('video_progress'),
          {'src/vid/1-3': 42});
    });

    test('restoreBackup 恢复旧备份时同步改写 video_progress key', () async {
      await LocalStore.init();
      await LocalStore.restoreBackup({
        'video_progress': {'a::b::1-1': 30, 'c::d::2-1': 12},
        'video_records': null,
        'history': null,
        'favorites': null,
        'bookmarks': null,
        'downloads': null,
      });
      final raw = await LocalStore.readJson('video_progress') as Map;
      expect(raw, {'a/b/1-1': 30, 'c/d/2-1': 12});
      expect(raw.keys.any((k) => k.contains('::')), isFalse);
    });

    test('restoreBackup 恢复新格式（/ 分隔）video_progress：原样写回不丢失', () async {
      // 现代备份的 key 已是 `/` 分隔：normalize 判定"无需改写"返 null，
      // 恢复必须回退写原数据——否则新格式备份的续播进度被静默丢弃。
      await LocalStore.init();
      await LocalStore.restoreBackup({
        'video_progress': {'x/y/1-1': 30, 'z/w/2-1': 12},
        'video_records': null,
        'history': null,
        'favorites': null,
        'bookmarks': null,
        'downloads': null,
      });
      final raw = await LocalStore.readJson('video_progress') as Map;
      expect(raw, {'x/y/1-1': 30, 'z/w/2-1': 12},
          reason: '新格式备份恢复不得丢数据（normalize 返 null 不能当"跳过"）');
    });

    test('restoreBackup 导入 double 秒数：统计读取按 num 容错不抛 TypeError', () async {
      // 备份恢复是外部 JSON 摄入口：手改/第三方工具可能产生 3600.5 这类
      // double；同节其余统计读（total/month/year）都用 as num 容错，这 3 处
      // 严格 as int 会让 profileProvider 整组失败 → 我的页整页错误。
      await LocalStore.init();
      final now = DateTime.now();
      final todayKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await LocalStore.restoreBackup({
        'reading_stats': {'2000-01-01': 3600.5, todayKey: 60.5},
        'video_progress': null,
        'video_records': null,
        'history': null,
        'favorites': null,
        'bookmarks': null,
        'downloads': null,
      });
      expect(await LocalStore.readingSecondsOfDay('2000-01-01'), 3600,
          reason: 'double 应按 num 收敛为 int，不得抛 TypeError');
      expect(await LocalStore.weekReadingSeconds(), 60);
      final days = await LocalStore.recentReadingDays(3);
      expect(days.last['seconds'], 60);
    });

    test('writeJson 拒绝路径注入 key：文件必须落在 data 目录内（防越界写）', () async {
      await LocalStore.init();
      // 动态 key 面：home 快照 key 含 SourceManager.current.id，而自定义源 id
      // （DSL 导入/源市场）只校验非空——`../x` 这类 id 若直接拼
      // File('${d.path}/$name.json') 会把文件写到 data 目录之外（桌面端
      // 可越出 app 数据目录；写失败被 _writeNow 吞、读失败被 _read 吞=静默）。
      await LocalStore.writeJson('../escaped', {'k': 1});
      // `..` 归一为 `_`：不得存在 data/../escaped.json（越界）、也不得
      // 存在 tmp/escaped.json（data 父目录）——文件只在 data 内。
      expect(File('${tmp.path}/data/../escaped.json').existsSync(), isFalse,
          reason: '路径注入 key 不得写到 data 目录之外');
      expect(File('${tmp.path}/escaped.json').existsSync(), isFalse,
          reason: '不得越出 data 父目录');
      // 归一后读写走同一映射：读回应命中 data 内文件、往返一致（非越界）。
      expect(await LocalStore.readJson('../escaped'), {'k': 1},
          reason: '归一后读写同一文件，往返一致');
    });

    test('writeJson 拒绝反斜杠/危险字符 key：归一为安全文件名不越界', () async {
      await LocalStore.init();
      await LocalStore.writeJson(r'a\b', {'k': 1});
      // 反斜杠归一为 _（Windows 路径分隔符不得插入路径）：
      // 文件落在 data/a_b.json，且读写走同一归一 → 往返一致。
      expect(File('${tmp.path}/data/a_b.json').existsSync(), isTrue,
          reason: r'a\b 应归一为 data 内的 a_b.json');
      expect(await LocalStore.readJson(r'a\b'), {'k': 1},
          reason: '读写走同一归一函数，往返必须命中同一文件');
    });
  });
}