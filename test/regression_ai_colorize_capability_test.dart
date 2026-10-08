import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/ai_colorize_capability.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/utils/colorizer_manager.dart';

/// M4 契约：AI 上色插件壳回归——注册/门闸/权重分发/调用透传。
///
/// 断言契约 §2 核心：上色走主 isolate 直调（不包 Isolate.run）、失败返回
/// CapabilityFailure 带中文原因、null=降级原图原样透传。不触碰 colorizer
/// 内部实现（只读调用 ColorizerManager 公开接口）。
///
/// R2：`AiColorizePlugin.colorize` 转发壳已删（阅读器直调
/// [ColorizerManager.colorize]），本文件改为覆盖能力生命周期（元数据/
/// 平台门闸/ensureModel 下载失败路径/模型就绪反映到接口）。
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

  group('AiColorizePlugin 平台门闸与模型状态', () {
    test('桌面平台下 isModelReady 反映 ColorizerManager（未加载 = false）', () {
      expect(AiColorizePlugin.isModelReady(),
          ColorizerManager.instance.isAvailable);
    });

    test('ensureModel 权重地址已配置但下载失败（网络错误）→ 明确原因', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // 先注册（幂等），确保 byId 命中并可见权重直链。
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.colorize.ddcolor') == null) {
        await mgr.install(AiColorizePlugin());
      }
      // 测试环境无真实网络（dart:io 在 flutter_test 下无 channel，HttpClient
      // 直接抛 400）→ 走到下载失败分支，而不是「地址未配置」。
      final err = await AiColorizePlugin.ensureModel();
      expect(err, isNotNull);
      expect(err, isNot(contains('地址未配置'))); // 地址已发布，不再是占位空串
      expect(err, contains('下载')); // 网络失败路径给明确下载原因
    });
  });
}
