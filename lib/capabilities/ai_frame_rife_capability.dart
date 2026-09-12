import 'dart:async' show TimeoutException;
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;

import '../ui/responsive.dart' show DesktopUi;
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'capability_plugin_manager.dart';
import 'capability_runtime.dart';

/// AI 视频插帧能力（F1 桌面 PoC：RIFE 模型 + rife-ncnn-vulkan 引擎）。
///
/// 技术路线（docs/frame-interpolation-research.md §2.2 定案，F1 实测修正）：
/// - 模型：RIFE v4.6（Real-Time Intermediate Flow Estimation，双帧输入 →
///   中间帧输出，2x/4x/8x 可任意时间点插帧），ncnn .bin/.param 格式。
/// - 引擎：**rife-ncnn-vulkan.exe 子进程**（不用 FFI 裸调 ncnn dll）——
///   预编译 Windows 包实测可跑（RTX 5090 Vulkan），子进程崩溃不伤主 App
///   （比 FFI 更安全：FFI 的 SIGSEGV 是进程级崩溃无法隔离）。
///   引擎包 = exe + vcomp140.dll + rife-v4.6 模型 + LICENSE，整体 zip 分发。
///
/// 边界（与 AiColorizePlugin 对齐，docs/colorizer-capability-contract.md）：
/// - **调用不占主线程**：子进程跑在独立进程，主线程零阻塞；超时/失败降级
///   原速播放，不打断观看、不抛异常。
/// - **版本钉死**：artifact/weights 带精确 SHA256，绝不自动滚动 latest。
///
/// 阶段：F1 桌面 PoC 打通「单帧补帧」推理链（两帧 → 中间帧）；F2 离线导出
/// / F3 实时补帧（限分辨率档 + 失败降级）/ F4 Android 后置。
class AiFrameRifePlugin extends CapabilityPlugin {
  /// 引擎包文件名（zip：exe + vcomp140.dll + rife-v4.6/ + LICENSE）。
  static const String engineZipName = 'rife-engine-win.zip';

  /// 引擎包 SHA256（F1 打包产物，版本钉死）。
  static const String engineSha256 =
      'F2DF934B53D157F0C21BEA21BC921CB22CE5E9D1781F6538D2825B5D05D0CF98';

  /// 引擎包体积（12.2MB，UI 展示下载大小用）。
  static const int engineSizeBytes = 12240595;

  /// 引擎 exe 名（zip 解压后）。
  static const String engineExeName = 'rife-ncnn-vulkan.exe';

  /// RIFE 模型目录名（zip 解压后，含 flownet.bin/.param）。
  static const String modelDirName = 'rife-v4.6';

  /// 模型文件（ncnn 格式，随引擎包分发，不再单独下载）。
  static const String modelName = 'flownet.bin';

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
            // 引擎包 zip：exe + vcomp140.dll + rife-v4.6 模型 = 12.2MB。
            // 分发经 CapabilityArtifactStore.download（SHA256 校验后落盘）。
            // models-v1 Release 附件直链（与索引 JSON 同源，SHA256 钉死）。
            url: 'https://github.com/lxfebd/xingmanxia-sources/releases/download/models-v1/rife-engine-win.zip',
            sha256: {'windows-x64': engineSha256},
          ),
          weights: const [], // 模型随引擎包分发，无独立权重下载
        );

  /// 单帧补帧调用入口：**子进程调用 rife-ncnn-vulkan.exe**。
  ///
  /// 输入两帧 [frameA] / [frameB]（RGB888 原始像素，长度 = w*h*3），输出
  /// 中间帧（同样 RGB888，长度 = w*h*3）。失败返回 [CapabilityFailure]，
  /// 调用方降级原速播放，不打断观看。
  ///
  /// 实现：两帧写临时 PNG → 子进程 exe -0 f0 -1 f1 -o mid -m rife-v4.6 →
  /// 读中间帧 PNG → 清理临时文件。
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
    // 3. 引擎就绪：zip 解压后 exe + 模型必须存在（未就绪给明确原因）。
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

    // 5. 写临时帧文件（RGB→PNG）→ 子进程补帧 → 读结果（PNG→RGB）→ 清理。
    final tmp = await Directory.systemTemp.createTemp('rife_');
    try {
      final f0 = File('${tmp.path}/f0.png');
      final f1 = File('${tmp.path}/f1.png');
      final mid = File('${tmp.path}/mid.png');
      // RGB 像素 → PNG 文件（exe 只吃图片文件，不接受裸字节）。
      final imA = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: frameA.buffer,
        order: img.ChannelOrder.rgb,
      );
      final imB = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: frameB.buffer,
        order: img.ChannelOrder.rgb,
      );
      await f0.writeAsBytes(img.encodePng(imA), flush: true);
      await f1.writeAsBytes(img.encodePng(imB), flush: true);

      // 子进程：超时兜底（RIFE 推理慢于 60s 视为异常，防挂死）。
      final proc = await Process.start(exe.path, [
        '-0', f0.path, '-1', f1.path, '-o', mid.path, '-m', modelDir.path,
      ]);
      final code = await proc.exitCode.timeout(const Duration(seconds: 60));
      if (code != 0) {
        return CapabilityFailure(id, '插帧进程退出码 $code');
      }
      if (!await mid.exists()) {
        return const CapabilityFailure(id, '插帧无输出（引擎异常）');
      }
      // PNG → RGB 像素（对齐输入协议：RGB888，长度 w*h*3）。
      final decoded = img.decodeImage(await mid.readAsBytes());
      if (decoded == null) {
        return const CapabilityFailure(id, '插帧输出解码失败（引擎异常）');
      }
      if (decoded.width != w || decoded.height != h) {
        return CapabilityFailure(
            id, '插帧输出尺寸不符（期望 ${w}x$h，实际 ${decoded.width}x${decoded.height}）');
      }
      final outBytes = Uint8List.fromList(decoded.getBytes(order: img.ChannelOrder.rgb));
      return CapabilityOk(id, data: <String, dynamic>{
        'frame': outBytes,
        'width': w,
        'height': h,
        'engine': 'rife-ncnn-vulkan v4.6',
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