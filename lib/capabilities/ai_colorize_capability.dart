import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../ui/responsive.dart' show DesktopUi;
import '../utils/colorizer_manager.dart' show ColorizerManager;
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'capability_plugin_manager.dart';
import 'capability_runtime.dart';

/// AI 漫画上色能力（M4 契约落地：metadata shell，只读对接 colorizer）。
///
/// 边界（见 docs/colorizer-capability-contract.md §2）：
/// - 能力边界定在 `ColorizerManager.colorize(rgb, w, h)`，不深入到
///   `ColorizerBackend.inferAsync` 之下。
/// - **主 isolate 直调 ColorizerManager**，不包 `CapabilityRuntime.run`：
///   `run` 的闭包走 `Isolate.run`，新 isolate 里 `ColorizerManager.instance`
///   是全新单例（模型未加载，`isAvailable=false`），colorize 恒降级 null。
///   上色是纯 Dart 壳（TFLite 推理本来就在 colorizer 自己的 isolate 里），
///   直调即不会引入第二把锁，并发由 `ColorizerManager._mutex` 单一串行化。
/// - 失败返回 null = 降级原图，插件层原样透传，不抛异常、不打断阅读。
///
/// 本文件不修改任何 `colorizer*.dart`（红线 M4）；仅做能力体系侧对接。
class AiColorizePlugin extends CapabilityPlugin {
  /// 权重文件名（.model_cache 分发 + 过渡期 importModel 共用）。
  static const String modelName = 'ddcolor.tflite';

  /// 权重 SHA256 —— 由权重提供方发布时填入（版本钉死，绝不自动滚动）。
  static const String modelSha256 = ''; // TODO(publish): 真实权重 SHA256

  /// 体积（约 225MB，reader_page 注释量级；UI 展示下载大小用）。
  static const int modelSizeBytes = 225 * 1024 * 1024;

  AiColorizePlugin()
      : super(
          id: 'ai.colorize.ddcolor',
          name: 'AI 上色',
          category: 'ai',
          version: '1.0.0',
          author: '星漫匣上色团队',
          description: '本地 DDColor 黑白漫画上色（桌面端，权重运行期下载）',
          builtin: false, // 市场能力：可卸载，走 install/persist
          weights: const [
            CapabilityWeight(
              name: modelName,
              url: '', // TODO(publish): 最终权重直链
              sizeBytes: modelSizeBytes,
              sha256: modelSha256,
            ),
          ],
        );

  /// 权重就绪检查：模型布尔就绪（ColorizerManager.isAvailable）。
  /// 供能力中心 UI 展示「模型未就绪」前调用，判断是否需要下载权重。
  static bool isModelReady() => ColorizerManager.instance.isAvailable;

  /// 模型权重就绪：下载权重到 `.model_cache/<id>/` 并让 colorizer 加载。
  ///
  /// M4 契约 §5 过渡期：colorizer 路径注入未做前，权重下载到 `.model_cache`
  /// 后经现有 `importModel(sourcePath)` 载入（复制到 colorizer 私有模型目录，
  /// 代价双份 225MB，仅作过渡；正式版走路径注入）。
  ///
  /// 返回 null 表示成功（模型已就绪）；失败返回用户可读原因。
  static Future<String?> ensureModel() async {
    const id = 'ai.colorize.ddcolor';
    final m = ColorizerManager.instance;
    if (m.isAvailable) return null; // 已就绪
    if (kIsWeb || !DesktopUi.isDesktopPlatform) {
      return 'AI 上色仅支持桌面端（Windows/macOS/Linux）';
    }

    final plugin = CapabilityPluginManager.instance.byId(id);
    if (plugin == null || plugin.weights.isEmpty) {
      return '上色能力未注册或未配置权重';
    }
    final weight = plugin.weights.first;
    if (weight.url.isEmpty) {
      return '权重地址未配置（待发布方填写下载直链）';
    }

    // 下载 + SHA256 校验（幂等：已就绪复用）。
    final store = CapabilityArtifactStore.instance;
    final file = await store.downloadWeight(id, weight);
    if (file == null) {
      return store.lastError ?? '权重下载失败';
    }

    // 过渡期：经 importModel 让 colorizer 载入（复制到其私有模型目录）。
    // importModel 幂等（已存在即复用）。
    final ok = await m.importModel(file.path);
    return ok ? null : '模型载入失败（文件可能损坏或非 DDColor 格式）';
  }

  /// 上色调用入口：**主 isolate 直调 ColorizerManager**。
  ///
  /// 返回 [CapabilityOk.data.result] == null 时表示降级原图（colorizer 失败
  /// 语义），调用方照常显示原图。失败原因经 [CapabilityFailure.reason] 给出，
  /// 禁止静默降级。
  static Future<CapabilityResult> colorize(
    Uint8List rgb,
    int w,
    int h,
  ) async {
    const id = 'ai.colorize.ddcolor';

    // 1. 平台门闸：与 reader_page 现有 `_colorizeEnabled` 对齐——
    //    DesktopUi.isDesktopPlatform（不含 Android 真机），web 恒不可用。
    if (kIsWeb || !DesktopUi.isDesktopPlatform) {
      return const CapabilityFailure(id, 'AI 上色仅支持桌面端（Windows/macOS/Linux）');
    }

    // 2. 注册 + 启用开关：probe 不查开关（本能力无 artifact，纯注册校验），
    //    这里显式收口（与能力中心 UI 开关一致）。
    final p = await CapabilityRuntime.instance.probe(id);
    if (p is CapabilityFailure) return p;
    if (!CapabilityPluginManager.instance.isEnabledSync(id)) {
      return const CapabilityFailure(id, '能力未启用，请在能力中心打开');
    }

    // 3. 模型就绪：isAvailable = 模型存在 + loadAsync 就绪。
    final m = ColorizerManager.instance;
    if (!m.isAvailable) {
      return const CapabilityFailure(id, '上色模型未就绪（需导入 .tflite 模型）');
    }

    // 4. 主 isolate 直调：colorizer 自带锁 + 超时 + 降级，此处不引入第二把锁。
    //    null = 降级原图，原样透传（调用方照常显示原图）。
    final out = await m.colorize(rgb, w, h);
    return CapabilityOk(id, data: <String, dynamic>{'result': out});
  }
}
