import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// 一个超分档位的完整描述（供 UI 面板直接渲染）。
class SrPreset {
  /// 唯一 id，也是持久化时存的值。
  final String id;

  /// 面板上显示的名称。
  final String name;

  /// 一句话说明它做了什么。
  final String desc;

  /// GPU 开销星级 0~4，用来在面板上画小方块。
  final int cost;

  /// 需要加载的 shader 文件名（空列表 = 关闭）。
  final List<String> shaders;

  const SrPreset({
    required this.id,
    required this.name,
    required this.desc,
    required this.cost,
    required this.shaders,
  });

  bool get enabled => shaders.isNotEmpty;
}

/// Anime4K 视频超分管理。
///
/// 通过 mpv 的 `glsl-shaders` 属性加载 Anime4K（MIT 开源）CNN
/// 超分着色器，实现实时视频放大/修复，而不是简单的插值滤镜。
/// 另外附带一组 mpv 画质增强参数（去色带 + 高质量缩放核），
/// 这部分开销极小但对动画观感提升明显。
class Anime4KManager {
  Anime4KManager._();

  static const _assetDir = 'assets/anime4k';

  /// 全部档位，顺序即 UI 展示顺序。
  static const List<SrPreset> levels = [
    SrPreset(
      id: 'off',
      name: '关闭',
      desc: '原始画面，零额外开销',
      cost: 0,
      shaders: [],
    ),
    SrPreset(
      id: 'restore',
      name: '智能降噪',
      desc: '只修复压缩噪点与线条，不放大，低端机可用',
      cost: 1,
      shaders: ['Anime4K_Restore_CNN_M.glsl'],
    ),
    SrPreset(
      id: 'perf',
      name: '轻量超分',
      desc: '修复 + 2x 放大（S 模型），流畅优先',
      cost: 2,
      shaders: [
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ],
    ),
    SrPreset(
      id: 'quality',
      name: '均衡超分',
      desc: '修复 + 2x 放大（M 模型），推荐中高端机',
      cost: 3,
      shaders: [
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ],
    ),
    SrPreset(
      id: 'ultimate',
      name: '极致超分',
      desc: '修复 + 2x 放大（VL 模型），画质最强，很吃 GPU',
      cost: 4,
      shaders: [
        'Anime4K_Restore_CNN_VL.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl',
      ],
    ),
  ];

  /// mpv 画质增强参数：高质量缩放核 + 去色带。
  /// 动画大面积渐变最容易出色带，deband 收益很高。
  static const Map<String, String> enhanceProps = {
    'scale': 'ewa_lanczossharp',
    'cscale': 'ewa_lanczossoft',
    'dscale': 'mitchell',
    'correct-downscaling': 'yes',
    'sigmoid-upscaling': 'yes',
    'deband': 'yes',
    'deband-iterations': '2',
    'deband-threshold': '35',
    'deband-range': '20',
  };

  /// 关掉画质增强时用的还原值。
  static const Map<String, String> enhanceOffProps = {
    'scale': 'bilinear',
    'cscale': 'bilinear',
    'dscale': 'bilinear',
    'correct-downscaling': 'no',
    'sigmoid-upscaling': 'no',
    'deband': 'no',
  };

  static SrPreset presetById(String id) =>
      levels.firstWhere((e) => e.id == id, orElse: () => levels.first);

  static int indexOfId(String id) {
    final i = levels.indexWhere((e) => e.id == id);
    return i < 0 ? 0 : i;
  }

  static Future<Directory> _appDir() async {
    final dir = await getApplicationSupportDirectory();
    final shaderDir = Directory('${dir.path}/anime4k');
    if (!shaderDir.existsSync()) shaderDir.createSync(recursive: true);
    return shaderDir;
  }

  static bool _shadersReady = false;

  /// 把 assets 里的 shader 复制到应用目录（mpv 需要真实文件路径）。
  static Future<void> ensureShaders() async {
    if (_shadersReady) return;
    final dir = await _appDir();
    for (final preset in levels) {
      for (final name in preset.shaders) {
        final target = File('${dir.path}/$name');
        if (target.existsSync() && target.lengthSync() > 0) continue;
        try {
          final data = await rootBundle.load('$_assetDir/$name');
          await target.writeAsBytes(data.buffer.asUint8List());
        } catch (_) {
          // 资源缺失时忽略，播放器回退到无超分
        }
      }
    }
    _shadersReady = true;
  }

  /// 获取指定档位的 mpv `glsl-shaders` 属性值（逗号分隔的 shader 路径）。
  /// 关闭档或资源缺失时返回空串，调用方直接写空串即可清除 shader。
  static Future<String> shaderListFor(String presetId) async {
    final preset = presetById(presetId);
    if (!preset.enabled) return '';
    await ensureShaders();
    final dir = await _appDir();
    final paths = <String>[];
    for (final n in preset.shaders) {
      final f = File('${dir.path}/$n');
      if (f.existsSync() && f.lengthSync() > 0) paths.add(f.path);
    }
    return paths.join(',');
  }
}
