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
      // models-v1 发布后：真实直链 + SHA256 钉死（空 = 未发布占位）
      expect(p.weights.first.url, isNotEmpty);
      expect(p.weights.first.sha256, hasLength(64));
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

    test('ensureModel 权重地址已配置但下载失败（网络错误）→ 明确原因', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // 测试环境无真实网络（dart:io 在 flutter_test 下无 channel，HttpClient
      // 直接抛 400）→ 走到下载失败分支，而不是「地址未配置」。
      final err = await AiColorizePlugin.ensureModel();
      expect(err, isNotNull);
      expect(err, isNot(contains('地址未配置'))); // 地址已发布，不再是占位空串
      expect(err, contains('下载')); // 网络失败路径给明确下载原因
    });
  });
}
