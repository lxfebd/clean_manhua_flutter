import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/ai_colorize_capability.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/capabilities/capability_runtime.dart';

/// M4 契约：AI 上色插件壳回归——注册/门闸/权重分发/调用透传。
///
/// 断言契约 §2 核心：上色走主 isolate 直调（不包 Isolate.run）、失败返回
/// CapabilityFailure 带中文原因、null=降级原图原样透传。不触碰 colorizer
/// 内部实现（只读调用 ColorizerManager 公开接口）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 整个文件模拟 Windows 桌面（VM 默认 android 会先撞平台门闸，
  // 无法测到启用/模型门闸分支）
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('AiColorizePlugin 元数据', () {
    test('能力条目：ai 分类、非 builtin（可卸载）、带权重声明', () {
      final p = AiColorizePlugin();
      expect(p.id, 'ai.colorize.ddcolor');
      expect(p.category, 'ai');
      expect(p.builtin, isFalse);
      expect(p.weights, hasLength(1));
      expect(p.weights.first.name, 'ddcolor.tflite');
      expect(p.weights.first.sha256, isEmpty); // 发布时填，当前占位
    });
  });

  group('AiColorizePlugin 调用门闸', () {
    test('未启用 → CapabilityFailure 带中文原因（不抛异常）', () async {
      final mgr = CapabilityPluginManager.instance;
      // 先注册（幂等），确保 byId 命中
      if (mgr.byId('ai.colorize.ddcolor') == null) {
        await mgr.install(AiColorizePlugin());
      }
      // 明确禁用 → 调用必须失败带「未启用」原因
      await mgr.setEnabled('ai.colorize.ddcolor', false);
      final r = await AiColorizePlugin.colorize(Uint8List(0), 0, 0);
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('未启用'));
      // 还原启用，避免影响其他用例
      await mgr.setEnabled('ai.colorize.ddcolor', true);
    });

    test('模型未就绪 → CapabilityFailure 提示导入模型', () async {
      // 覆盖平台为 Windows（VM 默认 android 会先撞平台门闸）
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.colorize.ddcolor') == null) {
        await mgr.install(AiColorizePlugin());
      }
      await mgr.setEnabled('ai.colorize.ddcolor', true);
      // Windows + 无模型 → 走到「模型未就绪」
      final r = await AiColorizePlugin.colorize(Uint8List(0), 0, 0);
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('模型未就绪'));
    });

    test('ensureModel 无权重地址 → 明确原因', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final err = await AiColorizePlugin.ensureModel();
      expect(err, isNotNull);
      expect(err, contains('权重地址未配置'));
    });
  });
}
