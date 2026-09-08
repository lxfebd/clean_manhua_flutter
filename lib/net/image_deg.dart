import 'package:flutter/foundation.dart';

/// 图片多级降级（原画 → 省空间 → 备用镜像 → 占位图）的 URL 归一化与降级链构造。
///
/// 思路：**同一张图的不同地址（原画 / 压缩图 / 备用镜像）在缓存里共享一个槽位**——
/// 缓存 key 一律按 [normalizeUrl] 归一化后的主 URL 计算，任一档位加载成功即落盘，
/// 下次无论从哪个地址来都能命中，还顺带消除了「同图多 URL 重复占缓存」的问题。
///
/// 降级链用 [fallbacks] 表达（URL 可选、构建函数可选，实际为动态枚举），
/// 即：原画 `u` 失败后先试「省空间压缩图」（默认禁用，源侧通过
/// [registerBuilder] 提供，如 MangaDex 的 data-saver API），再按
/// [buildMirrors] 顺序试备用镜像，全部失败由调用方落占位图。
class ImageDeg {
  ImageDeg._();

  /// 备用镜像构建函数注册表：engineId → 由主 URL 生成镜像 URL 的闭包。
  /// 由各源在初始化时注册（如 JM 的 CDN 镜像列表、MangaDex 的备用 data 节点）。
  static final Map<String, List<String Function(String url)>> _mirrors = {};

  /// 省空间（压缩图）URL 构建函数注册表：engineId → 压缩图 URL 闭包。
  /// 返回 null 表示该 URL 无压缩图（如 MangaDex 非 data-saver 档返回 null）。
  static final Map<String, String? Function(String url)?> _saver = {};

  /// 注册备用镜像构建函数（幂等，重复注册覆盖同 key）。
  static void registerMirror(String engineId, String Function(String url) fn) {
    _mirrors[engineId] = [...?_mirrors[engineId], fn];
  }

  /// 注册省空间压缩图 URL 构建函数（幂等）。null 表示清空。
  static void registerSaver(String engineId, String? Function(String url)? fn) {
    if (fn == null) {
      _saver.remove(engineId);
    } else {
      _saver[engineId] = fn;
    }
  }

  /// 归一化缓存 key：去掉 @jm:xxx 解扰标记，得到源图主 URL。
  static String normalizeUrl(String url) {
    final at = url.indexOf('@jm:');
    return at > 0 ? url.substring(0, at) : url;
  }

  /// 按顺序返回待尝试的 URL 列表：
  /// `[原画 u, 省空间压缩图（若有）, ...备用镜像]`，已按去重。
  /// [saver] 仅当主 URL 命中注册的引擎且该引擎开了省空间时生成；
  /// 备用镜像构建器接收**原 URL**（含 `@jm:` 等解扰标记），由源负责保留标记。
  static List<String> chain(String url, {String engineId = '', bool useSaver = false}) {
    final out = <String>[url];
    final norm = normalizeUrl(url);
    if (useSaver && engineId.isNotEmpty) {
      final f = _saver[engineId];
      if (f != null) {
        final s = f(norm);
        if (s != null && s.isNotEmpty && s != url) out.add(s);
      }
    }
    for (final f in _mirrors[engineId] ?? const <String Function(String)>[]) {
      final m = f(url);
      if (m.isNotEmpty && !out.contains(m)) out.add(m);
    }
    return out;
  }

  /// 尝试加载 [chain] 中每个 URL，返回 (bytes, 命中档位, 失败数)。
  /// [loader] 承担实际网络/缓存读取（ImageCacheManager.load 主 URL 的 fetch）。
  /// 第一级失败即认为可降级：返回 [ImageDegStatus.saver] 或 [ImageDegStatus.mirror]；
  /// 全部失败返回 [ImageDegStatus.failed]，由调用方落占位图。
  ///
  /// 档位按**链中命中的槽位**判定，而不是单纯数失败次数：链第二个槽位只有在
  /// 开了省空间的引擎里才是 saver（MangaDex data-saver），否则（如 JM 镜像）
  /// 一律记 mirror，避免「JM 镜像生效却报成省空间」的误导。
  static Future<ImageDegResult> loadWithChain(
    List<String> urls, {
    String engineId = '',
    bool useSaver = false,
    required Future<Uint8List> Function(String url, int index) loader,
  }) async {
    Uint8List? bytes;
    var failures = 0;
    var hit = -1;
    for (var i = 0; i < urls.length; i++) {
      try {
        bytes = await loader(urls[i], i);
        hit = i;
        break;
      } catch (_) {
        failures++;
      }
    }
    if (bytes == null) return ImageDegResult.failed(failures);
    final status = hit == 0
        ? ImageDegStatus.original
        : hit == 1 && useSaver && engineId.isNotEmpty
            ? ImageDegStatus.saver
            : ImageDegStatus.mirror;
    return ImageDegResult.ok(bytes, status, failures);
  }

  /// 供调试/测试读取注册表状态。
  @visibleForTesting
  static Map<String, int> debugRegistry() => {
        'mirrors': _mirrors.length,
        'saver': _saver.length,
      };
}

/// 降级档位。
enum ImageDegStatus {
  /// 原画直接成功。
  original,

  /// 原画失败、省空间（压缩图）成功。
  saver,

  /// 原画/省空间失败、备用镜像成功。
  mirror,

  /// 全部档位失败（调用方落占位图）。
  failed,
}

/// 降级加载结果。
class ImageDegResult {
  final Uint8List? bytes;
  final ImageDegStatus status;
  final int failures;
  const ImageDegResult(this.bytes, this.status, this.failures);

  ImageDegResult.ok(Uint8List b, ImageDegStatus s, int f)
      : this(b, s, f);
  ImageDegResult.failed(int f) : this(null, ImageDegStatus.failed, f);
}
