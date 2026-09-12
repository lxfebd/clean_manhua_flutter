import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/capability_plugin.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/capabilities/capability_market.dart';
import 'package:xingmanxia/net/local_store.dart';

/// 能力安装持久化回归：installed 快照落盘/卸载清出、预置壳卸载 removed
/// 落盘（restore 不重建的依据）、CapabilityPlugin 序列化 roundtrip。
///
/// Manager 是进程单例且无重置钩子：用独立测试 id 隔离，用例前 restore()
/// 确保预置壳在册（幂等，重复调用无副作用）。path_provider 打桩到临时
/// 目录（与 colorizer_manager_test 同款），否则 LocalStore 无 channel
/// 写盘静默失败、readJson 恒 null。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    // 共享一个临时目录装整个文件：LocalStore._dir 是进程内静态缓存，
    // 每用例重建 tmp 会导致读写目录错位（写进第一个 tmp，读到新 tmp）。
    tmp = Directory.systemTemp.createTempSync('xm_cap_persist');
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
    await LocalStore.init();
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('CapabilityPlugin 序列化 roundtrip', () {
    test('toJson → fromJson 还原同字段', () {
      const p = CapabilityPlugin(
        id: 'ai.roundtrip',
        name: '往返',
        category: 'ai',
        version: '1.2.3',
        author: '作者',
        description: '描述',
        builtin: false,
        rank: 3,
        weights: [
          CapabilityWeight(
              name: 'w.tflite',
              url: 'https://x/w.tflite',
              sizeBytes: 1024,
              sha256: 'abc'),
        ],
        artifact: CapabilityArtifact(
          url: 'https://x/a.zip',
          sha256: {'windows-x64': 'def'},
        ),
      );
      final restored = CapabilityPlugin.fromJson(p.toJson());
      expect(restored, isNotNull);
      expect(restored!.id, 'ai.roundtrip');
      expect(restored.name, '往返');
      expect(restored.category, 'ai');
      expect(restored.version, '1.2.3');
      expect(restored.author, '作者');
      expect(restored.description, '描述');
      expect(restored.builtin, isFalse);
      expect(restored.rank, 3);
      expect(restored.artifact!.url, 'https://x/a.zip');
      expect(restored.artifact!.sha256, {'windows-x64': 'def'});
      expect(restored.weights, hasLength(1));
      expect(restored.weights.first.name, 'w.tflite');
      expect(restored.weights.first.sha256, 'abc');
    });

    test('缺关键字段（无 id/name）→ null 跳过', () {
      expect(CapabilityPlugin.fromJson(const {'category': 'ai'}), isNull);
      expect(
          CapabilityPlugin.fromJson(const {'id': '', 'name': 'x'}), isNull);
    });
  });

  group('能力安装持久化', () {
    test('安装写入 installed 快照；卸载后清出', () async {
      final mgr = CapabilityPluginManager.instance;
      await mgr.restore(); // 预置壳在册（幂等）
      await mgr.uninstall('ai.persist.test'); // 清理可能残留
      await CapabilityMarket.install(MarketCapabilityEntry(
        id: 'ai.persist.test',
        name: '持久化',
        category: 'ai',
        version: '1.0.0',
        author: '测试',
      ));
      final persisted =
          await LocalStore.readJson('capability_plugins') as Map;
      final installed = (persisted['installed'] as List);
      expect(
          installed
              .any((m) => m is Map && m['id'] == 'ai.persist.test'),
          isTrue);

      await mgr.uninstall('ai.persist.test');
      final after = await LocalStore.readJson('capability_plugins') as Map;
      expect(after['installed'] as List,
          isNot(contains(anything)) /* 该 id 不应在清单 */);
      expect(
          (after['installed'] as List)
              .any((m) => m is Map && m['id'] == 'ai.persist.test'),
          isFalse);
    });

    test('卸载预置能力 → removed 落盘（restore 不重建的依据）', () async {
      final mgr = CapabilityPluginManager.instance;
      await mgr.restore(); // 确保上色预置壳在册
      expect(mgr.byId('ai.colorize.ddcolor'), isNotNull);
      await mgr.uninstall('ai.colorize.ddcolor');
      expect(mgr.byId('ai.colorize.ddcolor'), isNull);
      final persisted =
          await LocalStore.readJson('capability_plugins') as Map;
      expect((persisted['removed'] as List).contains('ai.colorize.ddcolor'),
          isTrue);
      // 还原（避免影响其它用例的执行上下文）
      await CapabilityMarket.install(MarketCapabilityEntry(
        id: 'ai.colorize.ddcolor',
        name: 'AI 上色',
        category: 'ai',
        version: '1.0.0',
        author: '星漫匣上色团队',
      ));
      expect(mgr.byId('ai.colorize.ddcolor'), isNotNull);
    });
  });
}