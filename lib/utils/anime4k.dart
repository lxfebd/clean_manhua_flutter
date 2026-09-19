import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// 测试专用：重置 [ensureShaders] 的准备完成缓存，
  /// 让单测进程内多次调用能各自走完整逻辑。
  @visibleForTesting
  static void resetShadersReadyForTest() {
    _shadersReady = false;
  }

  /// 计算「超分强制放大」的目标渲染尺寸（纯函数，供单元测试）。
  ///
  /// 背景：mpv 的 Anime4K `x2 Upscale` shader 有 `WHEN OUTPUT.w > MAIN.w`
  /// 硬门槛——只有渲染目标比源大时超分链才执行。桌面端若播放窗口较小
  /// （或源接近窗口尺寸），渲染目标=源尺寸，x2 链被静默跳过，表现为
  /// 「开了超分还是 640p」。
  ///
  /// 规则：源长边按等比放大到不超过 [cap]（2560 = 2K 长边），倍率上限 2x；
  /// 宽高比保持不变。sourceColor 为 null/无效或无需放大时返回 null。
  /// * 源 640×360 → 1280×720（x2 链激活，真实放大）
  /// * 源 1280×720 → 2560×1440（2K，顶到上限）
  /// * 源 1920×1080 → 2560×1440（2K 超采样，x2 上限 2.0 与 2K 取小）
  /// * 源 ≥2560 长边 → null（x2 链本就满足，且防 4K 纹理拖垮 GPU）
  static ({int w, int h})? srTargetSize({
    required int sw,
    required int sh,
    int cap = 2560,
  }) {
    if (sw <= 0 || sh <= 0) return null;
    // 源宽高比保持不变，长边顶到 cap。
    final scale = (cap / (sw > sh ? sw : sh)).clamp(1.0, 2.0);
    final w = (sw * scale).round();
    final h = (sh * scale).round();
    if (w <= sw && h <= sh) return null; // 源已超上限，不放大
    return (w: w, h: h);
  }

  // ── 超分「是否真的生效」的判据（2026-09-14 定案）──────────────────────
  /// x2 放大链的 WHEN 阈值：**必须与 assets 里 shader 的 `//!WHEN` 表达式
  /// 逐字同源**（`test/anime4k_asset_integrity_test.dart` 会校验一致性）。
  ///
  /// 为什么是 0.999 而不是 1.000：mpv 表达式是**严格大于**，而「渲染输出
  /// 恰好等于源尺寸」时比值精确为 1.0，`1.0 > 1.0` 为假 → 整条放大链被
  /// 静默跳过（1080p 源铺满 1080p 屏、或窗口与源等大，都是这种情况），
  /// 用户看到的就是「开了超分毫无变化」。0.999 让这类场景下比值
  /// `1.0 > 0.999` 成立 → 链执行 → x2 放大后由 VO 缩回屏幕（SSAA 超采样），
  /// 这也是 Anime4K 官方对 1080p 屏的推荐用法。
  static const double upsampleWhenThreshold = 0.999;

  /// x2 放大链是否具备执行条件（纯函数，与 shader 的 `//!WHEN` 同源）。
  ///
  /// 语义：`(outW/srcW > 阈值) && (outH/srcH > 阈值)`，宽高需**同时**成立
  /// （任一方向在缩小就说明整体是缩小播放，此时只该跑修复链）。
  /// 尺寸缺失/非法返回 false（"未知"由调用方按三态处理）。
  static bool srChainEligible({
    required int srcW,
    required int srcH,
    required int outW,
    required int outH,
  }) {
    if (srcW <= 0 || srcH <= 0 || outW <= 0 || outH <= 0) return false;
    final rw = outW / srcW;
    final rh = outH / srcH;
    return rw > upsampleWhenThreshold && rh > upsampleWhenThreshold;
  }

  /// 统计 mpv `vo-passes` 里**真正在执行的用户着色器 pass 数**。
  ///
  /// 这是超分生效的唯一可靠判据：`glsl-shaders` 读回非空**完全不能证明**
  /// 生效（真机实测过「读回两个路径、vo-passes 里 0 个用户 pass」的静默
  /// 失效）。用户着色器 pass 的 desc 形如
  /// `user shader: Anime4K-v3.2-Upscale-CNN-x2-(M)-Conv-4x3x3x3 (rgb)`。
  /// 空值 / `ERR(...)` / 解析不出来都返回 0，不抛异常。
  static int userShaderPassCount(String? passes) {
    if (passes == null || passes.isEmpty) return 0;
    if (passes.startsWith('ERR(')) return 0;
    // 不绑死 Anime4K 名字：任何用户着色器 pass 都计入。
    return RegExp(r'user shader:').allMatches(passes).length;
  }

  // ── shader 版本管理 ──────────────────────────
  /// 每次修改 assets/anime4k 下的 shader（如放宽 WHEN 阈值）都必须 +1：
  /// 老用户磁盘上可能躺着旧版文件，只看 existsSync 会当作「已就绪」跳过，
  /// 新版永远不生效。这里约定：shader 目录里写一个 `.version` 标记文件，
  /// 内容为当前版本号；**版本号与磁盘上的旧标记不一致就强制重写全部**
  /// shader，一致才跳过。
  ///
  /// 为什么不用「内容指纹」：所有 shader 都以 `// MIT License` 开头，
  /// 新旧版首行完全相同，靠首行无法区分版本，指纹方案会形同虚设。
  /// v3 = 修 shader 首行（`// MIT License`）；v4 = WHEN 阈值 1.000 → 0.999
  /// （必须 +1，否则老设备上磁盘里的旧 shader 不会被覆盖重写）。
  static const int _shaderVersion = 4;
  static const String _versionFileName = '.version';

  /// 把 ByteData 转成完整的字节数组。不能直接 `buffer.asUint8List()`
  /// ——rootBundle 返回的 ByteData 可能带 offset，直接转换会把 offset 前
  /// 的无关字节也带进来，写出的 shader 文件头会多出脏字节。
  static Uint8List _assetBytes(ByteData data) =>
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

  /// 把 assets 里的 shader 复制到应用目录（mpv 需要真实文件路径）。
  /// 版本一致才跳过；版本不一致或文件缺失/损坏时覆盖为最新 assets 内容，
  /// 并在写完后把当前版本号落盘到 `.version`。写盘前去掉 BOM。
  static Future<void> ensureShaders() async {
    if (_shadersReady) return;
    final dir = await _appDir();
    final versionFile = File('${dir.path}/$_versionFileName');
    var upToDate = false;
    try {
      final v = int.tryParse(versionFile.readAsStringSync().trim());
      upToDate = v == _shaderVersion;
    } catch (_) {
      upToDate = false;
    }
    // 全部 shader 都已存在且版本一致 → 无需任何 IO，直接收工。
    if (upToDate &&
        levels.every((p) => p.shaders.every((n) {
              final f = File('${dir.path}/$n');
              return f.existsSync() && f.lengthSync() > 0;
            }))) {
      _shadersReady = true;
      return;
    }
    // 版本不一致（或首次安装/文件缺失）：重写全部 shader。
    for (final preset in levels) {
      for (final name in preset.shaders) {
        final target = File('${dir.path}/$name');
        ByteData? data;
        try {
          data = await rootBundle.load('$_assetDir/$name');
        } catch (_) {
          // 资源缺失时忽略，播放器回退到无超分
          continue;
        }
        var bytes = _assetBytes(data);
        // 去除 UTF-8 BOM（EF BB BF）。shader 解析器按行读指令，
        // 首个 `//!` 若被 BOM 污染会整条失效，超分被静默跳过。
        if (bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF) {
          bytes = bytes.sublist(3);
        }
        try {
          await target.writeAsBytes(bytes, flush: true);
        } catch (_) {
          // IO 失败忽略，播放器回退到无超分
        }
      }
    }
    // 全部写完再落盘版本标记，避免中途失败误判为已更新。
    try {
      versionFile.writeAsStringSync('$_shaderVersion', flush: true);
    } catch (_) {}
    _shadersReady = true;
  }

  /// 获取指定档位的 mpv `glsl-shaders` 属性值（逗号分隔的 shader 路径）。
  /// 关闭档或资源缺失时返回空串，调用方直接写空串即可清除 shader。
  ///
  /// Windows 上返回的路径统一转成 **正斜杠**（`C:/Users/.../file.glsl`）：
  /// mpv 的 command/change-list 会对 `\` 做转义解析（`\U`、`\A` 会被当
  /// 转义序列破坏路径），且 path-list 会把 `:` 当分隔符；正斜杠路径两者
  /// 都能安全绕过，盘符 `C:` 后紧跟 `/` 时 mpv 识别为盘符而非分隔符。
  static Future<String> shaderListFor(String presetId) async {
    final preset = presetById(presetId);
    if (!preset.enabled) return '';
    await ensureShaders();
    final dir = await _appDir();
    final paths = <String>[];
    for (final n in preset.shaders) {
      final f = File('${dir.path}/$n');
      if (f.existsSync() && f.lengthSync() > 0) {
        paths.add(Platform.isWindows ? f.path.replaceAll('\\', '/') : f.path);
      }
    }
    return paths.join(',');
  }
}
