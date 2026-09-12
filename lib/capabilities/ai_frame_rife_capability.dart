import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../ui/responsive.dart' show DesktopUi;
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'capability_plugin_manager.dart';
import 'capability_runtime.dart';

/// AI 视频插帧能力（F1 桌面 PoC：RIFE 模型 + 推理引擎）。
///
/// 技术路线（docs/frame-interpolation-research.md §2.2 定案）：
/// - 模型：RIFE（Real-Time Intermediate Flow Estimation，双帧输入 → 中间帧
///   输出，2x/4x/8x 可任意时间点插帧）。
/// - 推理引擎：优先 ncnn-vulkan（与 AI 上色同构，Android 复用同一推理代码）；
///   桌面工具链卡壳时 fallback ONNX Runtime（onnxruntime.dll，官方 C API，
///   FFI 全进独立 Isolate）。
///
/// 边界（与 AiColorizePlugin 对齐，见 docs/colorizer-capability-contract.md）：
/// - **FFI 全进独立 Isolate**：`CapabilityRuntime.runNative` 在 isolate 内
///   DynamicLibrary.open + 调用导出函数。原生崩溃（SIGSEGV）无法被 Dart
///   捕获，只能前置防御 + isolate 隔离，绝不让主线程碰 FFI。
/// - **失败降级原速播放**：推理失败/超时 → 调用方按原帧率播放，不打断观看、
///   不抛异常。
/// - 版本钉死：artifact/weights 带精确 SHA256，绝不自动滚动 latest。
///
/// 阶段：F1 桌面 PoC 只打通「单帧补帧」推理链（输入两帧 → 输出中间帧）；
/// F2 离线导出 / F3 实时补帧（限分辨率档 + 失败降级）/ F4 Android 后置。
class AiFrameRifePlugin extends CapabilityPlugin {
  /// 推理引擎构件文件名（桌面 artifact：onnxruntime.dll 或 ncnn dll）。
  static const String engineName = 'onnxruntime.dll';

  /// RIFE 模型权重文件名（.model_cache 分发）。
  static const String modelName = 'rife.onnx';

  /// 引擎 SHA256 —— 由分发方发布时填入（版本钉死，绝不自动滚动）。
  static const String engineSha256 = ''; // TODO(publish): 真实引擎 SHA256

  /// 模型 SHA256 —— 由模型提供方发布时填入。
  static const String modelSha256 = ''; // TODO(publish): 真实模型 SHA256

  /// 模型体积（约 40MB，RIFE v4.x 档位浮动；UI 展示下载大小用）。
  static const int modelSizeBytes = 40 * 1024 * 1024;

  AiFrameRifePlugin()
      : super(
          id: 'ai.frame.rife',
          name: 'AI 插帧',
          category: 'video',
          version: '1.0.0',
          author: '星漫匣插帧团队',
          description: '本地 RIFE 视频补帧（桌面端，模型运行期下载）',
          builtin: false, // 市场能力：可卸载，走 install/persist
          artifact: CapabilityArtifact(
            // 桌面直链 .dll（onnxruntime 官方分发包自带 C API 导出：
            // OrtCreateSession/OrtRun 等，FFI 可直接调用）。
            url: '', // TODO(publish): 最终引擎直链
            sha256: {'windows-x64': engineSha256},
          ),
          weights: const [
            CapabilityWeight(
              name: modelName,
              url: '', // TODO(publish): 最终模型直链
              sizeBytes: modelSizeBytes,
              sha256: modelSha256,
            ),
          ],
        );

  /// 单帧补帧调用入口：**独立 Isolate 内加载引擎 + 推理**。
  ///
  /// 输入两帧 [frameA] / [frameB]（RGB888 原始像素，长度 = w*h*3），输出
  /// 中间帧（同样 RGB888，长度 = w*h*3）。失败返回 [CapabilityFailure]，
  /// 调用方降级原速播放，不打断观看。
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

    // 2. 注册 + 启用开关。
    final p = await CapabilityRuntime.instance.probe(id);
    if (p is CapabilityFailure) return p;
    if (!CapabilityPluginManager.instance.isEnabledSync(id)) {
      return const CapabilityFailure(id, '能力未启用，请在能力中心打开');
    }

    // 3. 权重就绪：模型必须在 .model_cache 已落盘（下载由 ensureModel 负责）。
    final store = CapabilityArtifactStore.instance;
    final wdir = await store.weightDir(id);
    final model = File('${(wdir?.path ?? '')}/$modelName');
    if (wdir == null || !await model.exists()) {
      return const CapabilityFailure(id, '插帧模型未就绪（需先下载模型权重）');
    }

    // 4. 引擎 artifact 已由 probe 落盘校验。找到本地 .dll（桌面）。
    final dir = await store.artifactDir(id);
    if (dir == null) {
      return const CapabilityFailure(id, '当前平台不支持本地构件');
    }
    final engine = dir.listSync().whereType<File>().firstWhere(
          (e) => e.path.endsWith('.dll') ||
              e.path.endsWith('.so') ||
              e.path.endsWith('.dylib'),
          orElse: () => File('${dir.path}/$engineName'),
        );
    if (!await engine.exists()) {
      return const CapabilityFailure(id, '插帧引擎未落盘，无法加载');
    }

    // 5. 独立 Isolate 内加载引擎 + 推理。FFI 全进 isolate（红线）。
    //    此处通过 CapabilityRuntime.runNative 在 isolate 内
    //    DynamicLibrary.open(engine) → 调 RIFE 导出（当前用导出函数占位，
    //    FFI 绑定随 onnxruntime C API 落地：OrtCreateSession/OrtRun）。
    return CapabilityRuntime.instance.runNative(id, engine.path,
        task: (DynamicLibrary lib) {
      // TODO(F1-4): onnxruntime C API 绑定
      //   OrtEnv* OrtCreateEnv(...); OrtSession* OrtCreateSession(...);
      //   OrtRun(session, ...) 输入 [1,2,3,H,W] 帧对 → 输出 [1,3,H,W] 中间帧。
      // F1 阶段用引擎内导出函数占位：demo 能力已验证 isolate 内 dlopen +
      // 调用导出函数全链路（DemoNativePlugin.sum），此处仅需换成真实绑定。
      final frameLen = w * h * 3;
      if (frameA.length != frameLen || frameB.length != frameLen) {
        throw CapabilityNativeException('帧尺寸与 w/h 不符');
      }
      // 占位推理：两帧取平均作为「参考中间帧」——真实 RIFE 推理（光流估算）
      // 替换此实现。占位结果足以验证「输入两帧 → 输出一帧」的管线形状。
      final out = Uint8List(frameLen);
      for (var i = 0; i < frameLen; i++) {
        out[i] = ((frameA[i] + frameB[i]) / 2).round();
      }
      return <String, dynamic>{
        'frame': out,
        'width': w,
        'height': h,
        'engine': 'onnxruntime(placeholder)',
      };
    });
  }

  /// 模型权重就绪：下载权重到 `.model_cache/<id>/`。
  ///
  /// 与 AiColorizePlugin.ensureModel 同构：幂等（已就绪复用）、失败返回
  /// 用户可读原因。F1 阶段模型直链未配置时返回明确提示。
  static Future<String?> ensureModel() async {
    const id = 'ai.frame.rife';
    if (kIsWeb || !DesktopUi.isDesktopPlatform) {
      return 'AI 插帧仅支持桌面端（Windows/macOS/Linux）';
    }

    final plugin = CapabilityPluginManager.instance.byId(id);
    if (plugin == null || plugin.weights.isEmpty) {
      return '插帧能力未注册或未配置权重';
    }
    final weight = plugin.weights.first;
    if (weight.url.isEmpty) {
      return '模型地址未配置（待发布方填写下载直链）';
    }

    final store = CapabilityArtifactStore.instance;
    final file = await store.downloadWeight(id, weight);
    if (file == null) {
      return store.lastError ?? '模型下载失败';
    }
    return null; // 成功
  }
}
