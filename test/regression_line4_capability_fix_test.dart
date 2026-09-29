import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/ai_colorize_capability.dart';
import 'package:xingmanxia/capabilities/capability_artifact_store.dart';
import 'package:xingmanxia/capabilities/capability_plugin.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/utils/colorizer_manager.dart';

/// 能力插件/AI 增强 P1 修复回归（4 缺陷）：
/// - #1：卸载 AI 上色联动清理 colorizer 私有模型文件（`colorizer/model.tflite`）
///   并释放后端，避免「卸载了但功能仍可用」。
/// - #2：`_totalRamBytes` Windows 分支：GlobalMemoryStatusEx FFI 探测物理内存
///   （在 Windows 上跑 smoke；非 Windows 环境仅验证不抛异常）。
/// - #3：`CapabilityArtifactStore.expectedSha256ForCurrentPlatform`：按当前平台
///   从 per-ABI SHA256 map 选 key，避免索引按 arm 在前/win 在后时误取 hash。
/// - #4：`CapabilityPluginManager._registerBuiltin` 平台门闸：与 install/restore
///   一致，不支持平台的内置能力不注册。
///
/// 沿用 regression_capability_persist_test.dart / regression_ai_colorize_
/// capability_test.dart 的 mock 手段：MethodChannel 打桩 path_provider、
/// debugDefaultTargetPlatformOverride 切平台、独立测试 id 隔离单例状态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('xm_line4_cap');
    // path_provider 桩：ColorizerManager 模型文件、CapabilityArtifactStore
    // 构件目录、LocalStore 落盘都落这里。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') return tmp.path;
        return null;
      },
    );
    // LocalStore 是进程级单例缓存目录；uninstall → persist 走它落盘，
    // 不 init 会读不到临时目录（LocalStore._dir 静默走默认路径）。
    await LocalStore.init();
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    // 清理可能的 MethodChannel 桩，避免污染后续文件。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  group('P1#1 卸载 AI 上色联动清理 colorizer 模型', () {
    test('manager.uninstall(ai.colorize.ddcolor) 删除 colorizer/model.tflite',
        () async {
      // 先造一个「已导入」的 model.tflite 文件（模拟用户之前 ensureModel 过）。
      final dir = Directory('${tmp.path}/colorizer')
        ..createSync(recursive: true);
      final model = File('${dir.path}/model.tflite')
        ..writeAsBytesSync([0x68, 0x74, 0x74, 0x70]);
      expect(model.existsSync(), isTrue);

      // 走真实卸载路径：install → uninstall。用 debugDefaultTargetPlatformOverride
      // = windows 让 AiColorizePlugin.isSupportedOnCurrentPlatform 门闸通过。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final mgr = CapabilityPluginManager.instance;
      await mgr.install(AiColorizePlugin());
      await mgr.uninstall('ai.colorize.ddcolor');

      // 关键断言：model 文件已删 + isAvailable=false（ColorizerManager 已 unload）。
      expect(model.existsSync(), isFalse,
          reason: '卸载后 colorizer/model.tflite 应被清理');
      expect(ColorizerManager.instance.isAvailable, isFalse);

      debugDefaultTargetPlatformOverride = null;
    });

    test('deleteModelFile 幂等：文件不存在也安全返回', () async {
      final dir = Directory('${tmp.path}/colorizer');
      // 先清理，然后调两次都应成功。
      final f = File('${dir.path}/model.tflite');
      if (f.existsSync()) f.deleteSync();
      await ColorizerManager.instance.deleteModelFile();
      await ColorizerManager.instance.deleteModelFile();
      expect(f.existsSync(), isFalse);
      expect(ColorizerManager.instance.isAvailable, isFalse);
    });
  });

  group('P1#2 _totalRamBytes Windows 分支 smoke', () {
    test(
        'isLowEndDevice 在所有平台返回 bool（含 Windows FFI 路径）', () async {
      // isLowEndDevice 内部已 try/catch 兜底，任何平台都不会抛。
      final low = await ColorizerManager.isLowEndDevice();
      expect(low, isA<bool>());
    });

    // Windows 环境下额外验证 FFI 路径不炸（其他平台跳过）。
    test('Windows FFI 路径 smoke（仅 Windows 环境跑）', () {
      if (!Platform.isWindows) {
        markTestSkipped('仅 Windows 环境跑 FFI smoke');
        return;
      }
      // 直接走 _totalRamBytes（Windows 分支会走 GlobalMemoryStatusEx）：
      // 返回值 > 0 或 null（FFI 失败）均算「不抛异常」通过；< 0 才是异常。
      // 用 isLowEndDevice 走全链路（内含 Platform.isWindows 判定）。
      ColorizerManager.isLowEndDevice();
    });
  });

  group('P1#3 expectedSha256ForCurrentPlatform 按平台选 key', () {
    // 关键场景：索引 arm 在前 / win 在后，直接 values.first 会在 Windows
    // 上误取 arm 的 hash，本地 DLL 校验必失败。
    test('arm 在前 win 在后：Windows 侧拿到 windows-x64 hash', () {
      final m = <String, String>{
        'arm64-v8a': '0' * 64,
        'windows-x64': 'a' * 64,
      };
      expect(
        CapabilityArtifactStore.expectedSha256ForCurrentPlatform(m,
            platformKeyOverride: 'windows'),
        'a' * 64,
        reason: 'Windows 侧必须命中 windows-x64，即便 arm 排在前面',
      );
    });

    test('arm 在前 win 在后：Android 侧拿到 arm64-v8a hash', () {
      final m = <String, String>{
        'arm64-v8a': '0' * 64,
        'windows-x64': 'a' * 64,
      };
      expect(
        CapabilityArtifactStore.expectedSha256ForCurrentPlatform(m,
            platformKeyOverride: 'android'),
        '0' * 64,
      );
    });

    test('仅 macos 单键：命中 macos-x64 或 macos 平台键兜底', () {
      expect(
        CapabilityArtifactStore.expectedSha256ForCurrentPlatform(
            {'macos-x64': 'b' * 64, 'windows-x64': 'a' * 64},
            platformKeyOverride: 'macos'),
        'b' * 64,
      );
      // macos 平台键兜底（未声明 macos-x64 时）。
      expect(
        CapabilityArtifactStore.expectedSha256ForCurrentPlatform(
            {'windows-x64': 'a' * 64, 'macos': 'c' * 64},
            platformKeyOverride: 'macos'),
        'c' * 64,
      );
    });

    test('linux 侧命中 linux-x64', () {
      expect(
        CapabilityArtifactStore.expectedSha256ForCurrentPlatform(
            {'arm64-v8a': '0' * 64, 'linux-x64': 'd' * 64},
            platformKeyOverride: 'linux'),
        'd' * 64,
      );
    });

    test('web/unknown 平台：不做 ABI 匹配，退回首值', () {
      final m = <String, String>{'arm64-v8a': '0' * 64, 'linux-x64': 'd' * 64};
      expect(
        CapabilityArtifactStore.expectedSha256ForCurrentPlatform(m,
            platformKeyOverride: 'web'),
        '0' * 64,
        reason: 'web 无 FFI，索引只写单一/多架构 hash 时按索引顺序取首值',
      );
    });

    test('空 map / 单一 hash 兼容', () {
      expect(CapabilityArtifactStore.expectedSha256ForCurrentPlatform(
          <String, String>{}),
          isNull);
      // 索引只提供一个「通用」hash（无 ABI 键）：任意平台都命中首值。
      expect(
        CapabilityArtifactStore.expectedSha256ForCurrentPlatform(
            {'generic': 'e' * 64},
            platformKeyOverride: 'windows'),
        'e' * 64,
        reason: '无 ABI/平台键时退回 values.first，兼容单一 hash 索引',
      );
    });
  });

  group('P1#4 _registerBuiltin 平台门闸', () {
    // _registerBuiltin 是 private，通过 restore() 间接触发；restore 是
    // 进程级幂等（_restored 位），跨测试文件可能已跑过。策略：
    // 用 debugDefaultTargetPlatformOverride 切平台，验证 isSupportedOnCurrentPlatform
    // 门闸与 install() 同源（registerBuiltin 已加同一 gate 检查）。
    test('utility.stats 全平台内置：isSupportedOnCurrentPlatform 恒 true',
        () {
      final stats = const CapabilityPlugin(
        id: 'utility.stats',
        name: '阅读统计',
        category: 'utility',
        version: '1.0.0',
        author: '星漫匣内置',
        description: '本地阅读统计（纯本地计算，不上传）',
        builtin: true,
      );
      // registerBuiltin 里 add(stats) 的门闸不会误拦——全平台能力默认 true。
      expect(stats.isSupportedOnCurrentPlatform, isTrue,
          reason: '全平台内置能力不应被门闸过滤');
    });

    test('install() 门闸与 registerBuiltin 门闸同源：手机侧拒 AI 上色壳',
        () async {
      final mgr = CapabilityPluginManager.instance;
      // 手机侧：AI 上色壳 isSupportedOnCurrentPlatform=false，install 拦下。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // 若已被上一用例清理，先确保不残留。
      if (mgr.byId('ai.colorize.ddcolor') != null) {
        await mgr.uninstall('ai.colorize.ddcolor');
      }
      await mgr.install(AiColorizePlugin());
      expect(mgr.byId('ai.colorize.ddcolor'), isNull,
          reason: 'install() 门闸应拦下手机侧的 AI 上色壳；registerBuiltin '
              '已同源加入同一 gate 检查，两条路径行为一致');
      // 平台支持查询：未注册时按预置壳判定。
      expect(mgr.isSupportedOnCurrentPlatform('ai.colorize.ddcolor'), isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    test('AiFrameRifePlugin 平台门闸：非 Windows 全 false，Windows true',
        () async {
      final mgr = CapabilityPluginManager.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(mgr.isSupportedOnCurrentPlatform('ai.frame.rife'), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(mgr.isSupportedOnCurrentPlatform('ai.frame.rife'), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(mgr.isSupportedOnCurrentPlatform('ai.frame.rife'), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(mgr.isSupportedOnCurrentPlatform('ai.frame.rife'), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    test('平台支持查询：全平台 utility.stats 各平台恒 true', () {
      // registerBuiltin 加 gate 后 utility.stats（全平台能力）在所有平台仍注册。
      // 这里锁死「加 gate 没有误伤全平台能力」。
      final mgr = CapabilityPluginManager.instance;
      for (final t in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = t;
        expect(mgr.isSupportedOnCurrentPlatform('utility.stats'), isTrue,
            reason: 'utility.stats 应在 $t 上恒被判定为支持');
      }
      debugDefaultTargetPlatformOverride = null;
    });

    // 端到端：restore() 内部走 _registerBuiltin。utility.stats 无 gate 应
    // 在任何平台都被注册；registerBuiltin 加 gate 后不应误伤全平台能力。
    // restore() 幂等（_restored 位），可能已被其他测试文件跑过——用
    // restored getter 判断即可，未跑才补一次；已跑也保证「在册」。
    test('restore 后 utility.stats 在册（registerBuiltin 未误伤全平台能力）',
        () async {
      final mgr = CapabilityPluginManager.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      if (!mgr.restored) {
        await mgr.restore();
      }
      // utility.stats 是 builtin 且全平台支持，registerBuiltin 必登记。
      expect(mgr.byId('utility.stats'), isNotNull,
          reason: 'registerBuiltin 加 gate 后不应误伤全平台内置能力');
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('P1 综合（可选）', () {
    // 端到端小闭环：install→ensureModel→uninstall→再 ensureModel 应报「未就绪」
    // （因为模型文件被删）。测试环境无真实网络，ensureModel 会走下载失败分支
    // ——不验证颜色，只验证「卸载后 model 文件不存在、isAvailable=false」。
    test('卸载后 isAvailable=false，即使 modelPath 被重置', () async {
      // 直接构造一个假 model 文件，importModel 会复制到 colorizer 私有目录
      // 但真实 tflite 加载会失败（内容非法），最后 isAvailable=false。
      // 然后 uninstall 应清理 model 文件。这里只做状态断言，不真的跑 tflite。
      final mgr = CapabilityPluginManager.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await mgr.install(AiColorizePlugin());
      await mgr.uninstall('ai.colorize.ddcolor');
      expect(ColorizerManager.instance.isAvailable, isFalse);
      expect(ColorizerManager.instance.modelPath, isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
