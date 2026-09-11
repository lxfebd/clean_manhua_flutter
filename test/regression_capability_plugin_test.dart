import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/builtin_capabilities.dart';
import 'package:xingmanxia/capabilities/capability_plugin.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/capabilities/capability_runtime.dart';

/// M1 能力插件框架回归：注册/启用/调用/禁用/卸载全流程 + 运行时隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CapabilityPluginManager 生命周期', () {
    test('内置能力注册（幂等）', () async {
      final mgr = CapabilityPluginManager.instance;
      // 每次用例前清空（单测间隔离）
      mgr.plugins.toList().forEach((p) {
        if (!p.builtin) mgr.uninstall(p.id);
      });
      await registerBuiltinCapabilities();
      final stats = mgr.byId('utility.stats');
      expect(stats, isNotNull);
      expect(stats!.builtin, isTrue);
      expect(stats.category, 'utility');
      // 幂等：重复注册不报错、不重复
      await registerBuiltinCapabilities();
      expect(mgr.byId('utility.stats'), isNotNull);
    });

    test('自定义能力安装→调用→禁用→卸载 全流程', () async {
      final mgr = CapabilityPluginManager.instance;
      final p = _DemoPlugin();
      await mgr.install(p);
      expect(mgr.byId(p.id), isNotNull);
      expect(mgr.isEnabledSync(p.id), isTrue);

      // 调用（Isolate 隔离）
      final r = await ChapterStatsPlugin.countWords('星漫匣 本地阅读统计 测试');
      expect(r, isA<CapabilityOk>());
      final data = (r as CapabilityOk).data as Map<String, dynamic>;
      expect(data['chars'], greaterThan(0));

      // 禁用 → acquire 失败带原因
      await mgr.setEnabled(p.id, false);
      expect(mgr.isEnabledSync(p.id), isFalse);
      final acq = await CapabilityRuntime.instance.acquire(p.id);
      expect(acq, isA<CapabilityFailure>());
      expect((acq as CapabilityFailure).reason, contains('未启用'));

      // 卸载（自定义可卸）
      final removed = await mgr.uninstall(p.id);
      expect(removed, isTrue);
      expect(mgr.byId(p.id), isNull);
    });

    test('内置能力不可卸载', () async {
      final mgr = CapabilityPluginManager.instance;
      await registerBuiltinCapabilities();
      final removed = await mgr.uninstall('utility.stats');
      expect(removed, isFalse);
      expect(mgr.byId('utility.stats'), isNotNull);
    });
  });

  group('CapabilityRuntime 隔离调用', () {
    test('run 在独立 isolate 执行并返回数据', () async {
      final r = await CapabilityRuntime.instance.run(
        'utility.stats',
        () => 'isolate:ok',
      );
      expect(r, isA<CapabilityOk>());
      expect((r as CapabilityOk).data, 'isolate:ok');
    });

    test('任务抛异常 → 包装成 CapabilityFailure（不抛出）', () async {
      final r = await CapabilityRuntime.instance.run(
        'utility.stats',
        () => throw StateError('boom'),
      );
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('执行失败'));
    });

    test('acquire 未启用 → 失败；启用 → 成功', () async {
      final mgr = CapabilityPluginManager.instance;
      await registerBuiltinCapabilities();
      final ok = await CapabilityRuntime.instance.acquire('utility.stats');
      expect(ok, isA<CapabilityOk>());

      await mgr.setEnabled('utility.stats', false);
      final fail = await CapabilityRuntime.instance.acquire('utility.stats');
      expect(fail, isA<CapabilityFailure>());
      // 还原
      await mgr.setEnabled('utility.stats', true);
    });
  });

  group('演示能力：章节字数统计', () {
    test('空文本返回 0', () async {
      final r = await ChapterStatsPlugin.countWords('   ');
      expect(r, isA<CapabilityOk>());
      final d = (r as CapabilityOk).data as Map<String, dynamic>;
      expect(d['chars'], 0);
      expect(d['words'], 0);
    });

    test('中文按字符统计（去空白）', () async {
      final r = await ChapterStatsPlugin.countWords('第一章 测试\n这是内容。\n');
      final d = (r as CapabilityOk).data as Map<String, dynamic>;
      // '第一章测试这是内容。' = 10 字符（去空白，标点计入）
      expect(d['chars'], 10);
      expect(d['paragraphs'], 2);
    });
  });
}

/// 一次性自定义能力（演示卸载流程，builtin=false）。
class _DemoPlugin extends CapabilityPlugin {
  _DemoPlugin()
      : super(
          id: 'demo.test',
          name: '演示能力',
          category: 'utility',
          version: '0.0.1',
          author: '测试',
        );

  int bindCount = 0;
  int unbindCount = 0;

  @override
  Future<void> bind() async => bindCount++;
  @override
  Future<void> unbind() async => unbindCount++;
}
