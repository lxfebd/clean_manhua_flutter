import 'dart:async';
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
import 'prune_directory.dart';
import '../utils/image_super_res.dart';

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
  static Directory? _srDir;

  static Future<Directory> _imagesDir() async {
    if (kIsWeb) {
      throw UnsupportedError('web 端无磁盘图片缓存，仅走内存');
    }
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/data/images');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  /// 超分导数（2x 放大图）独立磁盘目录：与封面原图分开存放，
  /// 配额独立（见 [_maxSrDiskBytes]），避免「开一次超分 = 磁盘用量翻倍」
  /// 把封面/连读缓存挤没。文件 key 与正常缓存同 md5 空间（URL 指针相同），
  /// 仅目录不同，同一张图两处各自一份。
  static Future<Directory> _srImagesDir() async {
    if (kIsWeb) {
      throw UnsupportedError('web 端无磁盘图片缓存，仅走内存');
    }
    if (_srDir != null) return _srDir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/data/images_sr');
    if (!d.existsSync()) d.createSync(recursive: true);
    _srDir = d;
    return d;
  }

  static String _key(String url) =>
      md5.convert(utf8.encode(ImageDeg.normalizeUrl(url))).toString();

  /// 超分导数磁盘 key：在 md5 后追加算法版本号——升级超分算法时旧的
  /// 超分缓存自动失效（与旧 [ImageSuperRes.algoVersion] key 语义对齐）。
  static String _srKey(String url) =>
      '${_key(url)}-${ImageSuperRes.algoVersion}';

  /// web 端无磁盘：所有磁盘读写在此收口，web 直接返回 null / 跳过。
  /// [sr] 为 true 时读写超分导数目录（key 带算法版本）。
  static Future<Uint8List?> _diskBytes(String url, {bool sr = false}) async {
    if (kIsWeb) return null;
    final f = File(
        '${(await (sr ? _srImagesDir() : _imagesDir())).path}/${sr ? _srKey(url) : _key(url)}.img');
    try {
      if (!f.existsSync()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _diskWrite(String url, Uint8List bytes,
      {bool sr = false}) async {
    if (kIsWeb) return;
    final f = File(
        '${(await (sr ? _srImagesDir() : _imagesDir())).path}/${sr ? _srKey(url) : _key(url)}.img');
    try {
      await f.writeAsBytes(bytes, flush: true);
      unawaited(_maybeTrimDisk(sr: sr));
    } catch (_) {}
  }

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
      // 复用 in-flight；失败 future 不再污染后续调用：消费方负责清槽并
      // 重新发起一次（避免失败 future 永久占槽，网络恢复后重试也拿不到
      // 成功结果）。若期间已有新 future 入槽则不动。
      return running.then<ImageDegResult>(
        (v) => v,
        onError: (Object e, StackTrace st) {
          if (identical(_inflightDeg[norm], running)) {
            _inflightDeg.remove(norm);
          }
          return _loadDegraded(
            ImageDeg.chain(norm, engineId: engineId, useSaver: useSaver),
            headers: headers,
            loader: loader,
            proxy: proxy,
            engineId: engineId,
            useSaver: useSaver,
          );
        },
      );
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
    final disk = await _diskBytes(norm);
    if (disk != null) {
      _putMem(norm, disk);
      return ImageDegResult.ok(disk, ImageDegStatus.original, 0);
    }
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
    await _diskWrite(norm, res.bytes!);
    return res;
  }

  static Future<Uint8List> load(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function()? fetch,
    String? proxy,
  }) {
    _maybeRecoverImageCache();
    final norm = primaryUrl(url);
    final mem = _mem[norm];
    if (mem != null) {
      _mem.remove(norm);
      _mem[norm] = mem;
      return Future.value(mem);
    }
    final running = _inflight[norm];
    if (running != null) {
      // 复用 in-flight；失败 future 不再污染后续调用：消费方负责清槽并
      // 重新发起一次（避免失败 future 永久占槽，网络恢复后重试也拿不到
      // 成功结果）。若期间已有新 future 入槽则不动。
      return running.then<Uint8List>(
        (v) => v,
        onError: (Object e, StackTrace st) {
          if (identical(_inflight[norm], running)) {
            _inflight.remove(norm);
          }
          return _load(norm, headers: headers, fetch: fetch, proxy: proxy);
        },
      );
    }
    final future = _load(norm, headers: headers, fetch: fetch, proxy: proxy);
    _inflight[norm] = future;
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
    final disk = await _diskBytes(url);
    if (disk != null) {
      _putMem(url, disk);
      return disk;
    }
    final bytes = fetch != null
        ? await fetch()
        : Uint8List.fromList(await Net.getBytesAuto(url, headers: headers, proxy: proxy));
    _putMem(url, bytes);
    await _diskWrite(url, bytes);
    return bytes;
  }

  /// 超分导数专用加载：独立磁盘目录（见 [_srImagesDir]），内存已另开 key
  /// 空间（`sr:` 前缀）——同 URL 原图/超分图并存不互相覆盖，原图读吐也不
  /// 会污染超分请求（[loadSuperRes] 与 [load] 的 `_mem` slot 互不串扰）。
  /// [readThrough] 为 null 时等价只读缓存命中（未中即抛）。
  static Future<Uint8List> loadSuperRes(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function()? readThrough,
  }) async {
    final norm = primaryUrl(url);
    final memKey = 'sr:$norm';
    final mem = _mem[memKey];
    if (mem != null) {
      _mem.remove(memKey);
      _mem[memKey] = mem;
      return mem;
    }
    final disk = await _diskBytes(norm, sr: true);
    if (disk != null) {
      _putSlottedMem(memKey, disk);
      return disk;
    }
    if (readThrough == null) {
      throw Exception('超分缓存未命中且无回源：$url');
    }
    final bytes = await readThrough();
    _putSlottedMem(memKey, bytes);
    await _diskWrite(norm, bytes, sr: true);
    return bytes;
  }

  /// 与 [_putMem] 同语义的带 slot key 版本（普通路径固定用 norm）。
  static void _putSlottedMem(String key, Uint8List b) {
    final old = _mem.remove(key);
    if (old != null) _memBytes -= old.length;
    _mem[key] = b;
    _memBytes += b.length;
    while (_mem.isNotEmpty &&
        (_memBytes > _maxMemBytes || _mem.length > _maxMemCount)) {
      final oldestKey = _mem.keys.first;
      final oldestVal = _mem.remove(oldestKey)!;
      _memBytes -= oldestVal.length;
    }
  }

  static void _putMem(String url, Uint8List b) {
    _putSlottedMem(url, b);
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

  /// 超分导数磁盘配额（字节）：独立于封面/连读缓存（[_maxDiskBytes]）。
  /// 超分图是「可选增强」，2x 放大后体积通常大于原图，若并入同一预算，
  /// 「开超分 = 磁盘用量翻倍」会把封面缓存挤没（列表连读降级、离线图缺失）。
  /// 固定取正常磁盘预算的下限档（256MB → 128MB），不随设备分档放大。
  static int get _maxSrDiskBytes =>
      _deviceMemBytes == null
          ? 128 * 1024 * 1024
          : debugSrDiskBudgetForTier(_deviceMemBytes!);

  /// 按内存预算档位给出超分磁盘配额，供测试/诊断直接校验。
  /// 档位边界与 [debugDiskBudgetForTier] 对齐，SR 取相邻低一档。
  @visibleForTesting
  static int debugSrDiskBudgetForTier(int memBudgetBytes) {
    if (memBudgetBytes <= 24 * 1024 * 1024) return 64 * 1024 * 1024;
    if (memBudgetBytes <= 40 * 1024 * 1024) return 128 * 1024 * 1024;
    return 256 * 1024 * 1024;
  }

  /// 在写盘后按需清理：磁盘缓存超出上限时删除最旧文件。
  /// 每次写入后才检查（异步执行，不阻塞写盘路径），避免启动时全量扫描拖慢首帧。
  /// [sr] 为 true 时清理超分导数目录（配额取 [_maxSrDiskBytes]）。
  /// 实现收敛到共享原语 [pruneLruDirectory]（P1-15，覆盖文件数上限）。
  static Future<void> _maybeTrimDisk({bool sr = false}) async {
    try {
      final d = sr ? _srDir : _dir;
      if (d == null || !d.existsSync()) return;
      await pruneLruDirectory(
        d,
        sr ? _maxSrDiskBytes : _maxDiskBytes,
        maxCount: _maxDiskCount,
      );
    } catch (_) {}
  }

  static int get memoryCount => _mem.length;
  static int get memoryBytes => _memBytes;

  /// 低内存压制后到该时刻为止不恢复引擎层 imageCache 预算。
  /// 空 = 未处于压制期。恢复 = 时间到达后下一次 [load] 时把预算调回
  /// 正常档（避免一次性恢复带来二次峰值）；再触发低内存会重新计时。
  static DateTime? _lowMemUntil;
  static int? _lowMemMaxSize;
  static int? _lowMemMaxBytes;

  /// 系统发出低内存警告（Android onTrimMemory/onLowMemory）时调用：
  /// 主动清空内存图片缓存（磁盘缓存保留，不会重复下载），
  /// 同时收缩 Flutter 引擎层 imageCache 预算，避免 OOM 被系统杀进程。
  static void onLowMemory() {
    _mem.clear();
    _memBytes = 0;
    try {
      final cache = PaintingBinding.instance.imageCache;
      _lowMemMaxSize ??= cache.maximumSize;
      _lowMemMaxBytes ??= cache.maximumSizeBytes;
      cache.clear();
      cache.clearLiveImages();
      cache.maximumSize = 8;
      cache.maximumSizeBytes = 8 * 1024 * 1024;
      _lowMemUntil = DateTime.now().add(const Duration(minutes: 1));
    } catch (_) {}
  }

  /// 低压期结束后恢复引擎层 imageCache 预算（在 [load] 入口触发，渐进而非
  /// 立即恢复，避免回升瞬间再次打高内存）。恢复后不再重复判断。
  static void _maybeRecoverImageCache() {
    final until = _lowMemUntil;
    if (until == null) return;
    if (!DateTime.now().isAfter(until)) return;
    _lowMemUntil = null;
    try {
      final cache = PaintingBinding.instance.imageCache;
      if (_lowMemMaxSize != null) cache.maximumSize = _lowMemMaxSize!;
      if (_lowMemMaxBytes != null) cache.maximumSizeBytes = _lowMemMaxBytes!;
      _lowMemMaxSize = null;
      _lowMemMaxBytes = null;
    } catch (_) {}
  }

  static Future<List<File>> diskFiles() async {
    if (kIsWeb) return const [];
    final d = await _imagesDir();
    return d.existsSync() ? d.listSync().whereType<File>().toList() : const [];
  }

  static Future<void> clear() async {
    _mem.clear();
    _memBytes = 0;
    if (!kIsWeb) {
      try {
        final d = await _imagesDir();
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
      _dir = null;
      try {
        final sd = await _srImagesDir();
        if (sd.existsSync()) sd.deleteSync(recursive: true);
      } catch (_) {}
      _srDir = null;
    }
  }
}
