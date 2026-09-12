import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/builtin_capabilities.dart';
import 'package:xingmanxia/capabilities/capability_market.dart';
import 'package:xingmanxia/capabilities/capability_plugin.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';

/// 能力市场回归：索引解析（坏条目跳过/空 capabilities 容忍）+ 安装/卸载流程。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CapabilityMarket 索引解析', () {
    test('合法 capabilities 数组 → 解析出条目', () {
      const text = '''
      {
        "name": "测试能力市场",
        "capabilities": [
          {
            "id": "ai.test",
            "name": "测试 AI",
            "category": "ai",
            "version": "1.0.0",
            "author": "测试作者",
            "description": "测试描述",
            "weights": [
              {"name": "model.tflite", "url": "https://x/model.tflite",
               "sizeBytes": 1048576, "sha256": "abc"}
            ]
          }
        ]
      }
      ''';
      final entries = CapabilityMarket.parseIndex(text);
      expect(entries, hasLength(1));
      final e = entries.first;
      expect(e.id, 'ai.test');
      expect(e.name, '测试 AI');
      expect(e.category, 'ai');
      expect(e.version, '1.0.0');
      expect(e.author, '测试作者');
      expect(e.description, '测试描述');
      expect(e.weights, hasLength(1));
      expect(e.weights.first.name, 'model.tflite');
      expect(e.weights.first.url, 'https://x/model.tflite');
      expect(e.weights.first.sizeBytes, 1048576);
      expect(e.weights.first.sha256, 'abc');
    });

    test('坏条目（无 id/name）跳过、权重缺 url 跳过，不阻塞整个市场', () {
      const text = '''
      {"name": "测试", "capabilities": [
        {"id": "ok.legal", "name": "合法", "weights": [
          {"name": "w1", "url": "https://x/w1"},
          {"name": "w2"}
        ]},
        {"name": "无 id"},
        {"id": "无 name"},
        "不是对象",
        123
      ]}
      ''';
      final entries = CapabilityMarket.parseIndex(text);
      expect(entries, hasLength(1));
      expect(entries.first.id, 'ok.legal');
      // 无 url 的权重被跳过，只留 w1
      expect(entries.first.weights, hasLength(1));
      expect(entries.first.weights.first.name, 'w1');
    });

    test('无 capabilities 数组 → 返回空列表（不抛错）', () {
      const text = '{"name": "测试", "sources": [{"a":1}]}';
      expect(CapabilityMarket.parseIndex(text), isEmpty);
    });

    test('非法 JSON → 抛 FormatException（不吞错给上层错误 UI）', () {
      expect(() => CapabilityMarket.parseIndex('not json'), throwsFormatException);
    });

    test('MarketCapabilityEntry 字段映射', () {
      final e = MarketCapabilityEntry(
        id: 'ai.test',
        name: '测试 AI',
        category: 'ai',
        version: '1.0.0',
        author: '作者',
        description: '描述',
        weights: const [
          CapabilityWeight(
              name: 'w.tflite', url: 'https://x/w', sizeBytes: 1024, sha256: ''),
        ],
      );
      expect(e.id, 'ai.test');
      expect(e.category, 'ai');
      expect(e.weights, hasLength(1));
      expect(e.weights.first.sizeBytes, 1024);
    });
  });

  group('CapabilityMarket 安装/卸载', () {
    test('install 后 byId 命中、可卸载', () async {
      final mgr = CapabilityPluginManager.instance;
      // 清理可能残留
      await mgr.uninstall('ai.market.test');
      final entry = MarketCapabilityEntry(
        id: 'ai.market.test',
        name: '市场测试',
        category: 'ai',
        version: '1.0.0',
        author: '测试',
      );
      final ok = await CapabilityMarket.install(entry);
      expect(ok, isTrue);
      expect(mgr.byId('ai.market.test'), isNotNull);
      expect(mgr.byId('ai.market.test')!.builtin, isFalse);

      final removed = await CapabilityMarket.uninstall('ai.market.test');
      expect(removed, isTrue);
      expect(mgr.byId('ai.market.test'), isNull);
    });

    test('内置能力不可卸载（uninstall 返回 false）', () async {
      await registerBuiltinCapabilities();
      final removed = await CapabilityMarket.uninstall('utility.stats');
      expect(removed, isFalse);
    });
  });
}
