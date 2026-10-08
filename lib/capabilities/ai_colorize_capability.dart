import 'package:flutter/foundation.dart' show kIsWeb;

import '../ui/responsive.dart' show DesktopUi;
import '../utils/colorizer_manager.dart' show ColorizerManager;
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';
import 'capability_plugin_manager.dart';

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

  /// 权重 SHA256 —— models-v1 Release 唯一发布物（版本钉死，绝不自动滚动）。
  static const String modelSha256 =
      'c08aa1f86d84c7c514b6e80e8925a75a7dd51fa17df670c85610b28b7b813cc7';

  /// 体积（约 215MB，UI 展示下载大小用）。
  static const int modelSizeBytes = 225863636;

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
              // models-v1 Release 附件直链（与索引 JSON 同源，SHA256 钉死）。
              url: 'https://github.com/lxfebd/xingmanxia-sources/releases/download/models-v1/ddcolor_fp32.tflite',
              sizeBytes: modelSizeBytes,
              sha256: modelSha256,
            ),
          ],
        );

  /// 仅桌面端支持（手机端已撤下，DesktopUi 门闸×3；权重/模型链路均按桌面
  /// 设计）：能力中心/市场/注册恢复统一按此过滤，手机/Web 不显示、不可装。
  @override
  bool get isSupportedOnCurrentPlatform =>
      !kIsWeb && DesktopUi.isDesktopPlatform;

  /// 权重就绪检查：模型布尔就绪（ColorizerManager.isAvailable）。
  /// 供能力中心 UI 展示「模型未就绪」前调用，判断是否需要下载权重。
  static bool isModelReady() => ColorizerManager.instance.isAvailable;

  /// 模型权重就绪：下载权重到 `.model_cache/<id>/` 并让 colorizer 加载。
  ///
  /// M4 契约 §5 过渡期：colorizer 路径注入未做前，权重下载到 `.model_cache`
  /// 后经现有 `importModel(sourcePath)` 载入（复制到 colorizer 私有模型目录，
  /// 代价双份 225MB，仅作过渡；正式版走路径注入）。
  ///
  /// [onProgress]：下载进度回调 `(received, total)`，能力中心 UI 展示用
  /// （仅下载阶段生效；total 为 content-length，缺失时 null）。
  /// 返回 null 表示成功（模型已就绪）；失败返回用户可读原因。
  static Future<String?> ensureModel({
    void Function(int received, int? total)? onProgress,
  }) async {
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
    final file = await store.downloadWeight(id, weight, onProgress: onProgress);
    if (file == null) {
      return store.lastError ?? '权重下载失败';
    }

    // 过渡期：经 importModel 让 colorizer 载入（复制到其私有模型目录）。
    // importModel 幂等（已存在即复用）。
    final ok = await m.importModel(file.path);
    return ok ? null : '模型载入失败（文件可能损坏或非 DDColor 格式）';
  }

  /// 上色调用已收敛：能力壳不再提供 colorize 转发（R2 死代码清理）。
  /// 阅读器直调 [ColorizerManager.colorize]，平台门闸/启用校验/模型就绪
  /// 由调用侧各自完成；本类只保留能力生命周期两件事——[isModelReady]
  /// （能力中心展示模型状态）与 [ensureModel]（权重下载 + 载入）。
}
