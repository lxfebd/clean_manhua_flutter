import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:path_provider/path_provider.dart';

import 'http_client.dart';
import 'image_deg.dart';

class ImageCacheManager {
  static final LinkedHashMap<String, Uint8List> _mem = LinkedHashMap();
  static final Map<String, Future<Uint8List>> _inflight = {};

  /// 降级链专用 in-flight 去重（与 [_inflight] 分开，避免返回类型冲突；
  /// 同 key 两条链并发时各跑各的，先完成者写盘，后续命中磁盘缓存）。
  static final Map<String, Future<ImageDegResult>> _inflightDeg = {};
  static int _memBytes = 0;

  /// 设备内存分档探测结果；null=未探测（用平台默认档）。
  /// 仅移动端有意义，桌面端内存宽裕不主动收紧。
  static int? _deviceMemBytes;

  /// 按设备总内存探测图片缓存预算（启动时调用一次，异步）。
  /// 低端机收紧防 OOM，高端机放开提升连读流畅度。
  static Future<void> probeDeviceMemory() async {
    try {
      if (kIsWeb) return;
      final info = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await info.androidInfo;
          // isLowRamDevice 是系统判定（如 go_rogue 低内存设备），优先采纳
          if (a.isLowRamDevice) {
            _deviceMemBytes = 20 * 1024 * 1024;
            return;
          }
          _deviceMemBytes = debugTierForRamMb(a.physicalRamSize >> 20);
        case TargetPlatform.iOS:
          _deviceMemBytes =
              debugTierForRamMb((await info.iosInfo).physicalRamSize >> 20);
        default:
          return; // 桌面端沿用平台默认，不收紧
      }
    } catch (_) {
      // 探测失败沿用平台默认档
    }
  }

  /// 内存缓存预算（字节）。优先设备分档，其次平台默认。
  /// 图片字节数：JM 长条图单张可达十几 MB，预算本质是"能同时保留几张"。
  static int get _maxMemBytes {
    if (_deviceMemBytes != null) return _deviceMemBytes!;
    if (kIsWeb) return 40 * 1024 * 1024;
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => 96 * 1024 * 1024,
      _ => 40 * 1024 * 1024,
    };
  }

  /// 按总内存（MB）给出缓存预算档位，供单元测试直接校验分档逻辑。
  @visibleForTesting
  static int debugTierForRamMb(int ramMb) => switch (ramMb) {
        < 3072 => 24 * 1024 * 1024, // 低端 <3GB
        <= 6144 => 40 * 1024 * 1024, // 中端 3-6GB（原默认）
        _ => 64 * 1024 * 1024, // 高端 >6GB
      };

  /// 当前生效的内存缓存预算（字节）。生产代码（阅读器连读缓存分级等）
  /// 应使用本公开 getter；单元测试仍可用 [debugMemBudget] 兼容别名。
  static int get memoryBudgetBytes => _maxMemBytes;

  /// 当前生效的内存缓存预算（字节），供测试/诊断读取。
  @visibleForTesting
  static int debugMemBudget() => memoryBudgetBytes;

  /// 当前生效的磁盘缓存预算（字节），供测试/诊断读取。
  @visibleForTesting
  static int debugDiskBudget() => _maxDiskBytes;

  static const int _maxMemCount = 24;
  static Directory? _dir;

  static Future<Directory> _imagesDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/data/images');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  static String _key(String url) =>
      md5.convert(utf8.encode(ImageDeg.normalizeUrl(url))).toString();

  /// 归一化后的主 URL（去 @jm: 解扰标记），供调用方区分降级档位。
  /// 同图不同地址（原画/省空间/备用镜像）共享一个缓存槽，命中即算成功。
  static String primaryUrl(String url) => ImageDeg.normalizeUrl(url);

  /// 多级降级加载：先读主 URL 缓存（含磁盘），未命中时 fetch 内部自动按
  /// 原画 → 省空间 → 备用镜像 降级；返回结果携带实际命中的档位。
  ///
  /// 与 [load] 的区别：后者只请求 [url] 一个地址，失败即抛；本方法在
  /// 加载失败时继续尝试降级链（网络失败/解码失败均视为可降级），
  /// 全部失败仍抛异常，由调用方落占位图。成功结果不区分档位落缓存，
  /// 保证「任一档位成功即持久化」。
  ///
  /// [loader] 按链中每个具体 URL 调用（默认用 [Net.getBytesAuto] + 代理）；
  /// 需要特殊处理的源（如 JM 的解扰）可传入自定义 loader。
  static Future<ImageDegResult> loadDegraded(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function(String url, int index)? loader,
    String? proxy,
    String engineId = '',
    bool useSaver = false,
  }) async {
    final norm = primaryUrl(url);
    final mem = _mem[norm];
    if (mem != null) {
      _mem.remove(norm);
      _mem[norm] = mem;
      return ImageDegResult.ok(mem, ImageDegStatus.original, 0);
    }
    final running = _inflightDeg[norm];
    if (running != null) {
      return running;
    }
    final chain = ImageDeg.chain(norm, engineId: engineId, useSaver: useSaver);
    final future = _loadDegraded(
      chain,
      headers: headers,
      loader: loader,
      proxy: proxy,
      engineId: engineId,
      useSaver: useSaver,
    );
    _inflightDeg[norm] = future;
    future.whenComplete(() => _inflightDeg.remove(norm));
    return future;
  }

  static Future<ImageDegResult> _loadDegraded(
    List<String> chain, {
    Map<String, String>? headers,
    Future<Uint8List> Function(String url, int index)? loader,
    String? proxy,
    String engineId = '',
    bool useSaver = false,
  }) async {
    final norm = primaryUrl(chain.first);
    final f = File('${(await _imagesDir()).path}/${_key(norm)}.img');
    try {
      if (f.existsSync()) {
        final b = await f.readAsBytes();
        _putMem(norm, b);
        return ImageDegResult.ok(b, ImageDegStatus.original, 0);
      }
    } catch (_) {}
    final res = await ImageDeg.loadWithChain(
      chain,
      engineId: engineId,
      useSaver: useSaver,
      loader: (u, i) async {
        if (loader != null) return loader(u, i);
        return Uint8List.fromList(
            await Net.getBytesAuto(u, headers: headers, proxy: proxy));
      },
    );
    if (res.bytes == null) {
      throw Exception('图片降级链全部失败: ${chain.length} 个地址');
    }
    _putMem(norm, res.bytes!);
    try {
      await f.writeAsBytes(res.bytes!, flush: true);
      _maybeTrimDisk();
    } catch (_) {}
    return res;
  }

  static Future<Uint8List> load(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function()? fetch,
    String? proxy,
  }) {
    final norm = primaryUrl(url);
    final mem = _mem[norm];
    if (mem != null) {
      _mem.remove(norm);
      _mem[norm] = mem;
      return Future.value(mem);
    }
    final running = _inflight[norm];
    if (running != null) return running;
    final future = _load(norm, headers: headers, fetch: fetch, proxy: proxy);
    _inflight[norm] = future;
    future.whenComplete(() => _inflight.remove(norm));
    return future;
  }

  /// 内存/磁盘缓存使用统一的归一化 key：调用方 [load] 已先过 [primaryUrl]，
  /// 这里传入的 [url] 必为 norm（含 @jm: 等标记已被剥离），_putMem/_key 与
  /// [_loadDegraded] 保持同一 key 空间，避免带标记 URL 写入后查不到。
  static Future<Uint8List> _load(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function()? fetch,
    String? proxy,
  }) async {
    final f = File('${(await _imagesDir()).path}/${_key(url)}.img');
    try {
      if (f.existsSync()) {
        final b = await f.readAsBytes();
        _putMem(url, b);
        return b;
      }
    } catch (_) {}
    final bytes = fetch != null
        ? await fetch()
        : Uint8List.fromList(await Net.getBytesAuto(url, headers: headers, proxy: proxy));
    _putMem(url, bytes);
    try {
      await f.writeAsBytes(bytes, flush: true);
      _maybeTrimDisk();
    } catch (_) {}
    return bytes;
  }

  static void _putMem(String url, Uint8List b) {
    final old = _mem.remove(url);
    if (old != null) _memBytes -= old.length;
    _mem[url] = b;
    _memBytes += b.length;
    while (_mem.isNotEmpty &&
        (_memBytes > _maxMemBytes || _mem.length > _maxMemCount)) {
      final oldestKey = _mem.keys.first;
      final oldestVal = _mem.remove(oldestKey)!;
      _memBytes -= oldestVal.length;
    }
  }

  static Future<void> preload(String url, {Map<String, String>? headers, String? proxy}) async {
    try {
      await load(url, headers: headers, proxy: proxy);
    } catch (_) {}
  }

  /// 多级降级预加载：失败静默（不落占位图），供翻页/列表预取使用。
  static Future<void> preloadDegraded(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function(String url, int index)? loader,
    String? proxy,
    String engineId = '',
    bool useSaver = false,
  }) async {
    try {
      await loadDegraded(
        url,
        headers: headers,
        loader: loader,
        proxy: proxy,
        engineId: engineId,
        useSaver: useSaver,
      );
    } catch (_) {}
  }

  /// 磁盘缓存容量上限（字节）。低端机收紧（省存储），高端机放开（连读更顺）。
  /// 设备分档后按内存档位缩放：低 128MB / 中 256MB / 高 512MB（原默认）。
  static int get _maxDiskBytes {
    final b = _deviceMemBytes;
    if (b == null) return 512 * 1024 * 1024;
    return debugDiskBudgetForTier(b);
  }

  /// 按内存预算档位（字节）给出磁盘预算，供测试/诊断直接校验缩放逻辑。
  /// 档位边界与 [debugTierForRamMb] 一致：24MB→128MB，40MB→256MB，64MB→512MB。
  @visibleForTesting
  static int debugDiskBudgetForTier(int memBudgetBytes) {
    if (memBudgetBytes <= 24 * 1024 * 1024) return 128 * 1024 * 1024;
    if (memBudgetBytes <= 40 * 1024 * 1024) return 256 * 1024 * 1024;
    return 512 * 1024 * 1024;
  }

  /// 磁盘缓存文件数上限（防止海量小文件拖慢目录遍历）。
  static const int _maxDiskCount = 2000;

  /// 在写盘后按需清理：磁盘缓存超出上限时删除最旧文件。
  /// 每次写入后才检查，避免启动时全量扫描拖慢首帧。
  static void _maybeTrimDisk() {
    try {
      final d = _dir;
      if (d == null || !d.existsSync()) return;
      final files = d.listSync().whereType<File>().toList();
      if (files.length <= _maxDiskCount &&
          files.fold<int>(0, (s, f) => s + f.lengthSync()) <= _maxDiskBytes) {
        return;
      }
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      var total = files.fold<int>(0, (s, f) => s + f.lengthSync());
      var i = 0;
      while (i < files.length &&
          (total > _maxDiskBytes || files.length - i > _maxDiskCount)) {
        total -= files[i].lengthSync();
        try {
          files[i].deleteSync();
        } catch (_) {}
        i++;
      }
    } catch (_) {}
  }

  static int get memoryCount => _mem.length;
  static int get memoryBytes => _memBytes;

  /// 系统发出低内存警告（Android onTrimMemory/onLowMemory）时调用：
  /// 主动清空内存图片缓存（磁盘缓存保留，不会重复下载），
  /// 同时收缩 Flutter 引擎层 imageCache 预算，避免 OOM 被系统杀进程。
  static void onLowMemory() {
    _mem.clear();
    _memBytes = 0;
    try {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      cache.maximumSize = 8;
      cache.maximumSizeBytes = 8 * 1024 * 1024;
    } catch (_) {}
  }

  static Future<List<File>> diskFiles() async {
    final d = await _imagesDir();
    return d.existsSync() ? d.listSync().whereType<File>().toList() : const [];
  }

  static Future<void> clear() async {
    _mem.clear();
    _memBytes = 0;
    try {
      final d = await _imagesDir();
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    _dir = null;
  }
}
