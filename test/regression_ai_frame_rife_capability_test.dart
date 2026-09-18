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
    test('引擎 zip 就绪（解压）→ ensureEngine 就绪 → 子进程补帧出中间帧', () async {
      if (!hasEngine) {
        markTestSkipped('本机无引擎（$engineExe），跳过真实推理');
        return;
      }
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.frame.rife') == null) {
        await mgr.install(AiFrameRifePlugin());
      }
      await mgr.setEnabled('ai.frame.rife', true);

      // 引擎目录尚未就绪 → ensureEngine 应提示「引擎地址未配置」。
      final dir = await CapabilityArtifactStore.instance.artifactDir('ai.frame.rife');
      expect(dir, isNotNull);

      // 把 zip 放到 artifactDir 并模拟 download 产物（download 的 SHA256
      // 校验由 CapabilityArtifactStore.download 负责，此处直接验证解压链）。
      final zip = File('${dir!.path}/${AiFrameRifePlugin.engineZipName}');
      if (zip.existsSync()) zip.deleteSync();
      // 从打包好的引擎 zip 复制过来（若本地没有打包 zip，现场打包）。
      final prebuilt = File(
          r'C:\Users\31672\AppData\Local\Temp\rife_engine_pack\rife-engine-win.zip');
      if (prebuilt.existsSync()) {
        await prebuilt.copy(zip.path);
      } else {
        await engineExe.copy(zip.path); // 兜底：至少 exe 能就绪
      }
      expect(zip.existsSync(), isTrue, reason: '引擎 zip 应存在');

      // 解压（模拟 ensureEngine 成功路径：powershell Expand-Archive）。
      final out = await Process.run('powershell', [
        '-NoProfile', '-Command',
        'Expand-Archive -Path "${zip.path}" -DestinationPath "${dir.path}" -Force',
      ]);
      expect(out.exitCode, 0, reason: '解压引擎包失败: ${out.stderr}');
      expect(File('${dir.path}/${AiFrameRifePlugin.engineExeName}').existsSync(),
          isTrue, reason: '解压后应有 rife.exe');
      expect(
          Directory('${dir.path}/${AiFrameRifePlugin.modelDirName}').existsSync(),
          isTrue, reason: '解压后应有模型目录');

      // ensureEngine 现在应返回 null（就绪）。
      final eng = await AiFrameRifePlugin.ensureEngine();
      expect(eng, isNull, reason: '引擎应就绪，实际: $eng');

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

    test('真插帧铁证：白方块位移，中间帧方块居中（不是倍速假插帧）', () async {
      if (!hasEngine) {
        markTestSkipped('本机无引擎（$engineExe），跳过真实推理');
        return;
      }
      final mgr = CapabilityPluginManager.instance;
      if (mgr.byId('ai.frame.rife') == null) {
        await mgr.install(AiFrameRifePlugin());
      }
      await mgr.setEnabled('ai.frame.rife', true);

      // 引擎资产 → artifactDir（复用上一用例的部署方式）。
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

      // 白方块：192x192，帧A在 x=20，帧B在 x=140，方块宽 24。
      const w = 192, h = 192;
      final a = Uint8List(w * h * 3);
      final b = Uint8List(w * h * 3);
      void fill(Uint8List buf, int offset) {
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 3;
            buf[i] = 20; buf[i + 1] = 80; buf[i + 2] = 220; // 蓝底
            if (x >= offset && x < offset + 24 && y >= 84 && y < 108) {
              buf[i] = 240; buf[i + 1] = 240; buf[i + 2] = 240; // 白方块
            }
          }
        }
      }
      fill(a, 20);
      fill(b, 140);

      // 找出帧中白方块最左像素 x（运动位置）. 0xFFFFFF 像素块.
      int squareX(Uint8List buf) {
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 3;
            if (buf[i] > 200 && buf[i + 1] > 200 && buf[i + 2] > 200) return x;
          }
        }
        return -1;
      }

      final xA = squareX(a);
      final xB = squareX(b);
      expect(xA, 20);
      expect(xB, 140);

      // 插中间帧。
      final r = await AiFrameRifePlugin.interpolate(a, b, w, h);
      expect(r, isA<CapabilityOk>(), reason: '期望成功，实际: $r');
      final data = (r as CapabilityOk).data as Map<String, dynamic>;
      final mid = data['frame'] as Uint8List;
      final xMid = squareX(mid);

      // 铁证：中间帧方块位置应在 A 与 B 之间（≈居中 80），而不是等于 A 或 B。
      expect(xMid, greaterThan(xA), reason: '中间帧方块应离开起始位置（x=$xA）');
      expect(xMid, lessThan(xB), reason: '中间帧方块应未到终点（x=$xB）');
      // ∵ f0=20, f1=140, 居中 t=0.5 → x ≈ 80。允许 ±30 容差（RIFE 对快位移
      //   有平滑，且遮挡边缘可能让检测偏移几像素）。
      expect((xMid - 80).abs(), lessThan(30),
          reason: '中间帧方块应居中于 x≈80，实测 x=$xMid');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
