import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/ai_frame_rife_capability.dart';
import 'package:xingmanxia/capabilities/capability_artifact_store.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/capabilities/capability_runtime.dart';

/// F1 桌面 PoC：AI 插帧插件回归——注册/门闸/引擎就绪/真实子进程补帧。
///
/// 对齐 AiColorizePlugin 的契约断言模式 + 新增真实补帧成功路径：
/// - 能力条目元数据（video 分类、非 builtin、artifact=引擎包）
/// - 未启用 → CapabilityFailure 带中文原因（不抛异常）
/// - ensureEngine 未配置直链 → 明确原因
/// - 引擎 zip 就绪 → 真实子进程 rife-ncnn-vulkan.exe 补帧出中间帧
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 引擎 zip（Windows 引擎包）路径：单测从本机临时目录读。
  // 存在时启用「真实子进程」用例；不存在则跳过（CI 无引擎包也能跑壳用例）。
  final engineZip = File('C:/Users/31672/AppData/Local/Temp/rife-engine-win.zip');
  final hasEngine = engineZip.existsSync() && engineZip.lengthSync() > 1_000_000;

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
      // models-v1 发布后：引擎包直链已填（空串 = 未发布占位）。
      expect(p.artifact!.url, isNotEmpty);
      expect(p.artifact!.url, contains('xingmanxia-sources'));
      expect(p.artifact!.sha256, isNotEmpty); // 版本钉死：SHA256 已填
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

    test('ensureEngine 直链已配置但下载失败（网络错误）→ 明确原因', () async {
      // 测试环境无真实网络（HttpClient 直接抛）→ 走到下载失败分支，
      // 不再是「地址未配置」（地址已发布）。
      final err = await AiFrameRifePlugin.ensureEngine();
      expect(err, isNotNull);
      expect(err, isNot(contains('地址未配置')));
      expect(err, anyOf(contains('下载'), contains('解压')));
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
    test('引擎 zip 就绪 → 子进程补帧出中间帧', () async {
      if (!hasEngine) {
        markTestSkipped('本机无引擎包（${engineZip.path}），跳过真实推理');
        return;
      }
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.frame.rife') == null) {
        await mgr.install(AiFrameRifePlugin());
      }
      await mgr.setEnabled('ai.frame.rife', true);

      // 把引擎 zip 放到 artifactDir 并解压（模拟 ensureEngine 成功路径）。
      final dir = await CapabilityArtifactStore.instance.artifactDir('ai.frame.rife');
      expect(dir, isNotNull);
      await engineZip.copy('${dir!.path}/${AiFrameRifePlugin.engineZipName}');
      // ensureEngine 未配置 url 时无法自动解压——手动解压到相同位置
      // （等价于 probe 下载+解压后的状态）。
      final out = await Process.run('powershell', [
        '-NoProfile', '-Command',
        'Expand-Archive -Path "${dir.path}/${AiFrameRifePlugin.engineZipName}" '
            '-DestinationPath "${dir.path}" -Force',
      ]);
      expect(out.exitCode, 0, reason: '解压引擎包失败: ${out.stderr}');
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