import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/ai_frame_rife_capability.dart';
import 'package:xingmanxia/capabilities/capability_artifact_store.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/capabilities/capability_runtime.dart';

/// AI 插帧插件回归：注册/门闸/引擎就绪/真实子进程补帧。
///
/// 对齐 AiColorizePlugin 的契约断言模式 + 新增真实补帧成功路径：
/// - 能力条目元数据（video 分类、非 builtin、artifact=引擎包）
/// - 未启用 → CapabilityFailure 带中文原因（不抛异常）
/// - ensureEngine 未配置直链 → 明确原因
/// - 引擎就绪 → 真实子进程 rife.exe 补帧出中间帧
///
/// 引擎来源：本机 `xmq-video-ai/bin/rife.exe` + `models/rife-v4.6`（开发机
/// 构建产物）。存在时启用「真实子进程」用例；不存在则跳过（CI 无引擎也能
/// 跑壳用例）。引擎包 zip 由测试在 setUp 里现场打包（rife.exe + 模型目录）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 引擎资产路径（开发机：xmq-video-ai 构建产物）。
  final engineDir =
      Directory('J:/xiangm_transfer/xiangm/back/xmq-video-ai/bin');
  final engineExe = File('${engineDir.path}/${AiFrameRifePlugin.engineExeName}');
  final modelDir = Directory('J:/xiangm_transfer/xiangm/back/xmq-video-ai/models/${AiFrameRifePlugin.modelDirName}');
  final hasEngine =
      engineExe.existsSync() && modelDir.existsSync() && engineExe.lengthSync() > 1_000_000;

  late Directory testDir;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    CapabilityPluginManager.instance.setEnabled('ai.frame.rife', true);
    // 隔离 artifactDir：每次用新临时目录，防跨用例污染。
    testDir = Directory.systemTemp.createTempSync('rife_cap_test');
    CapabilityArtifactStore.instance.testOverrideDir = testDir;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    CapabilityArtifactStore.instance.testOverrideDir = null;
    try {
      testDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('AiFrameRifePlugin 元数据', () {
    test('能力条目：video 分类、非 builtin、artifact=引擎包、无独立权重', () {
      final p = AiFrameRifePlugin();
      expect(p.id, 'ai.frame.rife');
      expect(p.category, 'video');
      expect(p.builtin, isFalse); // 市场能力：可卸载
      expect(p.artifact, isNotNull);
      expect(p.artifact!.url, isEmpty); // 发布时填，当前占位
      expect(p.weights, isEmpty); // 模型随引擎包分发，无独立权重
    });
  });

  group('AiFrameRifePlugin 调用门闸', () {
    test('未启用 → CapabilityFailure 带中文原因（不抛异常）', () async {
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.frame.rife') == null) {
        await mgr.install(AiFrameRifePlugin());
      }
      await mgr.setEnabled('ai.frame.rife', false);
      final r = await AiFrameRifePlugin.interpolate(
          Uint8List(0), Uint8List(0), 0, 0);
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('未启用'));
      await mgr.setEnabled('ai.frame.rife', true); // 还原
    });

    test('ensureEngine 未配置直链 → 明确原因', () async {
      final err = await AiFrameRifePlugin.ensureEngine();
      expect(err, isNotNull);
      expect(err, contains('引擎地址未配置'));
    });

    test('引擎未就绪（无 zip 无 url）→ interpolate 失败含「引擎」原因', () async {
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.frame.rife') == null) {
        await mgr.install(AiFrameRifePlugin());
      }
      await mgr.setEnabled('ai.frame.rife', true);
      final r = await AiFrameRifePlugin.interpolate(
          Uint8List(3 * 3), Uint8List(3 * 3), 3, 3);
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, anyOf(contains('引擎'), contains('构件')));
    });
  });

  group('AiFrameRifePlugin 真实补帧', () {
    test('引擎就绪 → 子进程补帧出中间帧', () async {
      if (!hasEngine) {
        markTestSkipped('本机无引擎（$engineExe），跳过真实推理');
        return;
      }
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.frame.rife') == null) {
        await mgr.install(AiFrameRifePlugin());
      }
      await mgr.setEnabled('ai.frame.rife', true);

      // 把引擎资产复制到 artifactDir（模拟 ensureEngine 成功路径：
      // 引擎目录 = rife.exe + rife-v4.6/ 模型）。
      final dir = await CapabilityArtifactStore.instance.artifactDir('ai.frame.rife');
      expect(dir, isNotNull);
      await engineExe.copy('${dir!.path}/${AiFrameRifePlugin.engineExeName}');
      await Directory('${dir.path}/${AiFrameRifePlugin.modelDirName}')
          .create(recursive: true);
      for (final f in modelDir.listSync()) {
        if (f is File) {
          await f.copy('${dir.path}/${AiFrameRifePlugin.modelDirName}/${f.uri.pathSegments.last}');
        }
      }
      expect(File('${dir.path}/${AiFrameRifePlugin.engineExeName}').existsSync(),
          isTrue);

      // 构造两帧（256x256 蓝底 + 白方块位移）→ 补帧 → 应有输出帧。
      const w = 256, h = 256;
      final a = Uint8List(w * h * 3);
      final b = Uint8List(w * h * 3);
      void fill(Uint8List buf, int offset) {
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 3;
            buf[i] = 20; buf[i + 1] = 80; buf[i + 2] = 220; // 蓝底
            if (x >= offset && x < offset + 24 && y >= 60 && y < 90) {
              buf[i] = 240; buf[i + 1] = 240; buf[i + 2] = 240; // 白方块
            }
          }
        }
      }
      fill(a, 20);
      fill(b, 160);

      final r = await AiFrameRifePlugin.interpolate(a, b, w, h);
      expect(r, isA<CapabilityOk>(), reason: '期望成功，实际: $r');
      final data = (r as CapabilityOk).data as Map<String, dynamic>;
      final frame = data['frame'] as Uint8List;
      expect(frame.length, w * h * 3);
      expect(data['engine'], contains('rife'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
