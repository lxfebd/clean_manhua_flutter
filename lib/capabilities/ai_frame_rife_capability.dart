import 'dart:async' show TimeoutException;
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../ui/responsive.dart' show DesktopUi;
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'capability_plugin_manager.dart';
import 'capability_runtime.dart';

/// AI 视频插帧能力（RIFE 引擎，桌面专属插件）。
///
/// 技术路线（docs/frame-interpolation-research.md §2.2 定案，2026-09-18 实测修正）：
/// - 模型：RIFE v4.6（Real-Time Intermediate Flow Estimation，双帧输入 →
///   中间帧输出），ncnn .bin/.param 格式（flownet.bin + flownet.param）。
/// - 引擎：**rife.exe 子进程**（不用 FFI 裸调 ncnn dll）——子进程崩溃不伤
///   主 App（FFI 的 SIGSEGV 是进程级崩溃无法隔离）。GPU 优先（Vulkan，
///   实测 RTX 5090 1080p 单对 23-29ms 可实时）；无 Vulkan 设备时引擎内部
///   自动 CPU 兜底（小分辨率可实时，720p+ 仅离线可用）。
/// - 输入输出：**裸 RGB24**（不吃 PNG）——两帧写 .rgb 文件 → 子进程
///   `<modeldir> <w> <h> <threads> <midbase> <in0.rgb> <in1.rgb> [...]` →
///   读 `<midbase>_0.rgb`。支持一次批量多帧（每对相邻帧插 1 中间帧）。
///
/// 边界（与 AiColorizePlugin 对齐，docs/colorizer-capability-contract.md）：
/// - **调用不占主线程**：子进程跑在独立进程，主线程零阻塞；超时/失败降级
///   原速播放，不打断观看、不抛异常。
/// - **版本钉死**：artifact/weights 带精确 SHA256，绝不自动滚动 latest。
///
/// 阶段：F1 桌面 PoC 打通「单帧补帧」推理链（两帧 → 中间帧）；F2 离线导出
/// / F3 实时补帧（限分辨率档 + 失败降级）/ F4 Android 后置。
class AiFrameRifePlugin extends CapabilityPlugin {
  /// 引擎包文件名（zip：rife.exe + flownet.bin/.param + LICENSE）。
  static const String engineZipName = 'rife-engine-win.zip';

  /// 引擎包 SHA256（2026-09-18 从 xmq-video-ai 构建产物打包，版本钉死）。
  static const String engineSha256 =
      '48a0b0fc040b50bcd98b07ebe62a574016fcfed3a4a3e9f707eb129d9c03b5c0';

  /// 引擎包体积（13.1MB，UI 展示下载大小用）。
  static const int engineSizeBytes = 13131869;

  /// 引擎 exe 名（zip 解压后）。
  static const String engineExeName = 'rife.exe';

  /// RIFE 模型目录名（zip 解压后，含 flownet.bin/.param）。
  static const String modelDirName = 'rife-v4.6';

  /// 模型文件（ncnn 格式，随引擎包分发，不再单独下载）。
  static const String modelName = 'flownet.bin';

  /// 单对推理超时（秒）。1080p GPU 实测 <30ms，CPU 小分辨率 <40ms；
  /// 60s 是防挂死的保守上限。
  static const Duration inferTimeout = Duration(seconds: 60);

  AiFrameRifePlugin()
      : super(
          id: 'ai.frame.rife',
          name: 'AI 插帧',
          category: 'video',
          version: '1.0.0',
          author: '星漫匣插帧团队',
          description: '本地 RIFE 视频补帧（桌面端，引擎运行期下载）',
          builtin: false, // 市场能力：可卸载，走 install/persist
          artifact: CapabilityArtifact(
            // 引擎包 zip：rife.exe + flownet.bin/.param。
            // 分发经 CapabilityArtifactStore.download（SHA256 校验后落盘）。
            url: '', // TODO(publish): 最终引擎包直链（GitHub release 或对象存储）
            sha256: const {'windows-x64': engineSha256},
          ),
          weights: const [], // 模型随引擎包分发，无独立权重下载
        );

  /// 单帧补帧调用入口：**子进程调用 rife.exe**。
  ///
  /// 输入两帧 [frameA] / [frameB]（RGB888 原始像素，长度 = w*h*3），输出
  /// 中间帧（同样 RGB888，长度 = w*h*3）。失败返回 [CapabilityFailure]，
  /// 调用方降级原速播放，不打断观看。
  ///
  /// 实现：两帧写临时 .rgb → 子进程 exe → 读中间帧 .rgb → 清理临时文件。
  static Future<CapabilityResult> interpolate(
    Uint8List frameA,
    Uint8List frameB,
    int w,
    int h,
  ) async {
    const id = 'ai.frame.rife';

    // 1. 平台门闸：桌面 PoC（web 恒不可用，手机端 F4 再定）。
    if (kIsWeb || !DesktopUi.isDesktopPlatform) {
      return const CapabilityFailure(id, 'AI 插帧仅支持桌面端（Windows/macOS/Linux）');
    }

    // 2. 启用开关（先于 probe——url 未配置时 probe 会报「构件不可用」，
    //    而启用检查是更前置的门闸；引擎就绪检查在下面给友好提示）。
    if (!CapabilityPluginManager.instance.isEnabledSync(id)) {
      return const CapabilityFailure(id, '能力未启用，请在能力中心打开');
    }
    // 3. 引擎就绪：解压后 exe + 模型必须存在（未就绪给明确原因）。
    final eng = await ensureEngine();
    if (eng != null) {
      return CapabilityFailure(id, eng);
    }

    // 4. 引擎目录 = artifactDir（zip 解压处）。
    final store = CapabilityArtifactStore.instance;
    final dir = await store.artifactDir(id);
    if (dir == null) {
      return const CapabilityFailure(id, '当前平台不支持本地构件');
    }
    final exe = File('${dir.path}/$engineExeName');
    final modelDir = Directory('${dir.path}/$modelDirName');
    if (!await exe.exists() || !await modelDir.exists()) {
      return const CapabilityFailure(id, '插帧引擎未就绪（解压不完整）');
    }

    // 5. 写临时帧文件（RGB→.rgb）→ 子进程补帧 → 读结果（.rgb→RGB）→ 清理。
    final tmp = await Directory.systemTemp.createTemp('rife_');
    try {
      final f0 = File('${tmp.path}/in0.rgb');
      final f1 = File('${tmp.path}/in1.rgb');
      await f0.writeAsBytes(frameA, flush: true);
      await f1.writeAsBytes(frameB, flush: true);

      // 子进程：超时兜底（RIFE 推理慢于 60s 视为异常，防挂死）。
      // RIFE_GPUID 不显式设置：默认 0 = GPU（Vulkan），无 Vulkan 设备时
      // 引擎内部自动 CPU 兜底，不 crash。
      final proc = await Process.start(exe.path, [
        modelDir.path,
        '$w',
        '$h',
        '4', // threads
        '${tmp.path}/mid',
        f0.path,
        f1.path,
      ]);
      final code = await proc.exitCode.timeout(inferTimeout);
      if (code != 0) {
        return CapabilityFailure(id, '插帧进程退出码 $code');
      }
      final mid = File('${tmp.path}/mid_0.rgb');
      if (!await mid.exists()) {
        return const CapabilityFailure(id, '插帧无输出（引擎异常）');
      }
      final outBytes = await mid.readAsBytes();
      if (outBytes.length != w * h * 3) {
        return CapabilityFailure(id,
            '插帧输出尺寸不符（期望 ${w}x$h = ${w * h * 3}B，实际 ${outBytes.length}B）');
      }
      return CapabilityOk(id, data: <String, dynamic>{
        'frame': outBytes,
        'width': w,
        'height': h,
        'engine': 'rife v4.6',
      });
    } catch (e) {
      if (e is TimeoutException) {
        return const CapabilityFailure(id, '插帧超时（60s），已放弃');
      }
      return CapabilityFailure(id, '插帧失败: $e');
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 引擎就绪检查/准备：zip 解压到 artifactDir（幂等）。
  ///
  /// 返回 null = 就绪；否则用户可读原因。zip 缺失且无 url → 明确提示
  /// 待发布方配置直链。
  static Future<String?> ensureEngine() async {
    const id = 'ai.frame.rife';
    if (kIsWeb || !DesktopUi.isDesktopPlatform) {
      return 'AI 插帧仅支持桌面端（Windows/macOS/Linux）';
    }
    final store = CapabilityArtifactStore.instance;
    final dir = await store.artifactDir(id);
    if (dir == null) {
      return '当前平台不支持本地构件';
    }
    // 已解压（exe + 模型都在）→ 就绪。
    if (await File('${dir.path}/$engineExeName').exists() &&
        await Directory('${dir.path}/$modelDirName').exists()) {
      return null;
    }
    // 未就绪 → 尝试下载 zip（probe 已校验 SHA256），再解压。
    final plugin = CapabilityPluginManager.instance.byId(id);
    final url = plugin?.artifact?.url;
    if (plugin == null || plugin.artifact == null || url == null || url.isEmpty) {
      return '引擎地址未配置（待发布方填写下载直链）';
    }
    final zip = await store.download(id, plugin.artifact!);
    if (zip == null || !await zip.exists()) {
      return store.lastError ?? '引擎包下载失败';
    }
    // 解压 zip 到 artifactDir（覆盖式，幂等）。
    try {
      final out = await Process.run('powershell', [
        '-NoProfile', '-Command',
        'Expand-Archive -Path "${zip.path}" -DestinationPath "${dir.path}" -Force',
      ]);
      if (out.exitCode != 0) {
        return '引擎包解压失败: ${out.stderr}';
      }
    } catch (e) {
      return '引擎包解压失败: $e';
    }
    if (!await File('${dir.path}/$engineExeName').exists()) {
      return '引擎包解压后缺少 $engineExeName';
    }
    return null; // 就绪
  }
}
