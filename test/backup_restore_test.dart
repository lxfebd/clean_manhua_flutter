import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/backup_restore.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/source_config.dart';

/// 备份恢复统一入口回归（本地导入与 WebDAV 恢复共用 BackupRestore.apply）。
///
/// 核心断言：恢复后 SourceConfigStore 常驻缓存必须失效——否则恢复进来的
/// 源配置不生效，且随后任意 save 会把旧缓存全量回写、静默覆盖刚恢复的
/// 数据（webdav 路径曾单独修过，本地导入路径漏修，故收口单一入口守护）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('xm_backup_restore');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmpDir.path;
        }
        return null;
      },
    );
    // SourceConfigStore 走 LocalStore：每测试清静态缓存 + 归零磁盘配置。
    LocalStore.resetForTest();
    await LocalStore.init();
    SourceConfigStore.invalidateCache();
    await SourceConfigStore.resetToDefaults();
    SourceConfigStore.invalidateCache();
  });

  tearDown(() async {
    SourceConfigStore.invalidateCache();
    if (tmpDir.existsSync()) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('apply 恢复 sources_config：常驻缓存失效，恢复值立即可读', () async {
    // 让缓存停在「dm5 启用」：save 写盘并置缓存、刷新 _cacheAt（5 分钟
    // TTL 内 all() 不会重读盘——恢复若不失效缓存，读到的仍是这里的旧值）。
    await SourceConfigStore.save(const SourceConfig(
      engineId: 'dm5',
      id: 'dm5',
      name: '动漫屋',
      isEnabled: true,
      tier: SourceTier.primary,
    ));
    final before = await SourceConfigStore.all();
    expect(before.firstWhere((c) => c.engineId == 'dm5').isEnabled, isTrue);

    // 模拟备份恢复：盘上 sources_config 被恢复成「dm5 已禁用」。
    final restored = [
      for (final c in SourceConfigStore.defaults())
        {
          ...c.toJson(),
          'isEnabled': c.engineId == 'dm5' ? false : c.isEnabled,
        },
    ];
    final count = await BackupRestore.apply({'sources_config': restored});
    expect(count, 1, reason: 'sources_config 是唯一携带的字段，应计数 1');

    final after = await SourceConfigStore.all();
    expect(after.firstWhere((c) => c.engineId == 'dm5').isEnabled, isFalse,
        reason: '恢复值必须立即可见：缓存不失效则读到恢复前旧值（本地导入路径曾漏失效）');
  });

  test('restoreBackup 摄入口：sources_config 含坏条目，all() 不崩且跳过坏条目', () async {
    // 备份文件是磁盘数据（用户/WebDAV/旧版本可产生任意形状）。SourceConfig
    // .fromJson 对 id/engineId/name 用严格 as String，坏条目（类型错/缺字段）
    // 会让 SourceConfigStore.all() 抛 TypeError——restoreBackup 恢复后首次
    // all() 直接崩源管理/主页。
    final bad = [
      {'id': 123, 'name': '坏条目'}, // 类型错：engineId/id 缺失，fromJson as String 抛
      for (final c in SourceConfigStore.defaults())
        {
          ...c.toJson(),
          'isEnabled': c.engineId == 'dm5' ? false : c.isEnabled,
        },
    ];
    final count = await BackupRestore.apply({'sources_config': bad});
    expect(count, 1);
    // 坏条目跳过，好条目照常合并生效。
    final after = await SourceConfigStore.all();
    expect(after.firstWhere((c) => c.engineId == 'dm5').isEnabled, isFalse);
    expect(after.any((c) => c.id == '123'), isFalse, reason: '坏条目被跳过');
  });
}
