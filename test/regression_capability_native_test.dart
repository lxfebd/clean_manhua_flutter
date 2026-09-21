import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/builtin_capabilities.dart';
import 'package:xingmanxia/capabilities/capability_artifact_store.dart';
import 'package:xingmanxia/capabilities/capability_plugin.dart';
import 'package:xingmanxia/capabilities/capability_plugin_manager.dart';
import 'package:xingmanxia/capabilities/capability_runtime.dart';
import 'package:xingmanxia/capabilities/demo_native_capability.dart';

/// M2 桌面原生构件链路回归：
/// 下载(本地模拟) → SHA256 校验 → probe(ABI/落盘) → Isolate 内 FFI load → 调用
/// → 失败给明确原因（不静默降级）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 演示 DLL 资产路径（test/assets/demo_native/demo_math.dll）。
  late File demoDll;
  late Directory tmpDir;

  setUpAll(() async {
    final root = Directory.current;
    // 测试运行时 cwd 是包根目录。
    final asset = File('${root.path}/test/assets/demo_native/demo_math.dll');
    expect(
      asset.existsSync(),
      isTrue,
      reason: '缺少演示 DLL 资产，先编译 test/assets/demo_native/demo_math.c',
    );
    demoDll = asset;
    // flutter_test 下 path_provider 无 platform channel，注入临时目录。
    tmpDir = await Directory.systemTemp.createTemp('cap_native_test');
    CapabilityArtifactStore.instance.testOverrideDir = tmpDir;
    // 注册内置能力（含 DemoNativePlugin）。
    await registerBuiltinCapabilities();
  });

  tearDownAll(() async {
    CapabilityArtifactStore.instance.testOverrideDir = null;
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  group('CapabilityArtifactStore SHA256', () {
    test('计算本地文件 SHA256', () async {
      final h = await CapabilityArtifactStore.instance.sha256Of(demoDll);
      expect(h, DemoNativePlugin.demoSha256);
    });
  });

  group('probe 桌面 artifact 链路', () {
    test('probe 未注册能力 → 失败带原因', () async {
      final r = await CapabilityRuntime.instance.probe('not.registered');
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('未注册'));
    });

    test('probe 纯 Dart 能力直接 ok（无 artifact）', () async {
      await CapabilityPluginManager.instance.install(
        const CapabilityPlugin(
          id: 'utility.pure',
          name: '纯Dart',
          category: 'utility',
          version: '1.0.0',
          author: '测试',
        ),
      );
      final r = await CapabilityRuntime.instance.probe('utility.pure');
      expect(r, isA<CapabilityOk>());
    });

    test('probe 带 artifact：本地已落盘且 SHA256 匹配 → ok', () async {
      // 直接把演示 DLL 放入 artifact 目录（模拟已下载），校验通过。
      final store = CapabilityArtifactStore.instance;
      final dir = await store.artifactDir('utility.native');
      final target = File('${dir!.path}/demo_math.dll');
      await target.writeAsBytes(await demoDll.readAsBytes());

      final r = await CapabilityRuntime.instance.probe('utility.native');
      expect(r, isA<CapabilityOk>());
    });

    test('probe 落盘文件损坏（SHA256 不匹配）→ 尝试重下；无网 → 明确失败', () async {
      final store = CapabilityArtifactStore.instance;
      final dir = await store.artifactDir('utility.native');
      // 写一个损坏文件，模拟下载后 SHA256 校验失败。
      final target = File('${dir!.path}/demo_math.dll');
      await target.writeAsBytes([1, 2, 3, 4]);
      // 校验失败 → 删除 → 尝试从 example.com 下载（无网时报下载失败，
      // 有网时可能命中示例页导致 SHA256 校验失败——两种情况都是明确失败）。
      final r = await CapabilityRuntime.instance.probe('utility.native');
      expect(r, isA<CapabilityFailure>());
      expect(
        (r as CapabilityFailure).reason,
        contains('构件'),
        reason: '损坏文件必须走重下并给明确原因，不能静默通过',
      );
      // 恢复：重新放回正确 DLL，避免影响其他用例。
      await target.writeAsBytes(await demoDll.readAsBytes());
    });
  });

  // ⚠️ 顺序约束：Windows 上 DynamicLibrary.open 会锁住 DLL，之后无法删除/
  // 覆盖（errno=5/32）。故所有「文件写/删」用例必须排在 FFI 加载用例之前，
  // runNative 加载用例固定放最后。
  group('acquire 对带 artifact 能力的校验', () {
    test('启用 + artifact 就绪 → ok', () async {
      final store = CapabilityArtifactStore.instance;
      final dir = await store.artifactDir('utility.native');
      await File(
        '${dir!.path}/demo_math.dll',
      ).writeAsBytes(await demoDll.readAsBytes());

      final r = await CapabilityRuntime.instance.acquire('utility.native');
      expect(r, isA<CapabilityOk>());
    });

    test('未启用 → 失败（先于 artifact 校验）', () async {
      final mgr = CapabilityPluginManager.instance;
      await mgr.setEnabled('utility.native', false);
      final r = await CapabilityRuntime.instance.acquire('utility.native');
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('未启用'));
      await mgr.setEnabled('utility.native', true);
    });
  });

  group('M3 Android jniLibs 链路', () {
    test('jniLibs 源码布局存在（三个 ABI）', () {
      final root = Directory.current;
      for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
        final so = File(
          '${root.path}/android/app/src/main/jniLibs/$abi/libdemo_math.so',
        );
        expect(so.existsSync(), isTrue, reason: '缺少 $abi jniLibs 演示 so');
      }
    });

    test('jniLibs 产物与元数据 sha256 一致（版本钉死）', () async {
      final store = CapabilityArtifactStore.instance;
      final artifact = DemoNativePlugin().artifact!;
      // 构建期 bundle：jniLibs 里的 so 必须与能力插件元数据 sha256 一致，
      // 否则运行期加载的是未知版本（构建时应 fail-fast，此处单测兜底）。
      for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
        final so = File(
          '${Directory.current.path}/android/app/src/main/jniLibs/$abi/libdemo_math.so',
        );
        final h = await store.sha256Of(so);
        expect(h, artifact.sha256[abi], reason: '$abi so 与元数据 sha256 不一致');
      }
    });

    test('Android probe：sha256 含当前 ABI 键即就绪（构建期 bundle）', () async {
      // 注意：桌面测试环境 _currentAbi 返回 windows，无法走 Android 分支。
      // 该分支由 MuMu 真机验证；此处仅验证元数据键集完整。
      final artifact = DemoNativePlugin().artifact!;
      expect(artifact.sha256.containsKey('arm64-v8a'), isTrue);
      expect(artifact.sha256.containsKey('armeabi-v7a'), isTrue);
      expect(artifact.sha256.containsKey('x86_64'), isTrue);
      expect(artifact.jniLibsFile, 'libdemo_math.so');
    });
  });

  // 最后才加载 DLL：Windows 加载后会锁文件，其后的写/删用例会失败。
  // 组内同样：先「缺失」后「正常加载」（正常加载会锁文件）。
  group('Isolate 内 FFI 加载 + 调用', () {
    test('DLL 不存在 → 失败带明确原因（不静默）', () async {
      final store = CapabilityArtifactStore.instance;
      final dir = await store.artifactDir('utility.native');
      // 把 DLL 删掉，模拟构件缺失（此刻尚未 open 过，删除可成功）。
      final target = File('${dir!.path}/demo_math.dll');
      if (await target.exists()) await target.delete();

      final r = await DemoNativePlugin.sum(1, 1);
      expect(r, isA<CapabilityFailure>());
      // probe 先于 sum 运行：无网时返回「构件下载失败」，有网但下载非 DLL 时
      // 返回 SHA256 校验失败——两种情况都落到明确失败，绝不静默。
      expect((r as CapabilityFailure).reason, contains('构件'));
    });

    test(
      'runNative 加载真实 DLL 并调用导出函数',
      () async {
        final store = CapabilityArtifactStore.instance;
        final dir = await store.artifactDir('utility.native');
        final target = File('${dir!.path}/demo_math.dll');
        await target.writeAsBytes(await demoDll.readAsBytes());

        final r = await DemoNativePlugin.sum(40, 2);
        expect(r, isA<CapabilityOk>());
        final data = (r as CapabilityOk).data as Map<String, dynamic>;
        expect(data['sum'], 42);
        expect(data['version'], 0x20260911);
      },
      skip: Platform.isWindows ? false : '演示构件为 Windows DLL，CI 非 Windows 平台跳过',
    );
  });
}
