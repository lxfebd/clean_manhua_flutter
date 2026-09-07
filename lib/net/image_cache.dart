import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'http_client.dart';

class ImageCacheManager {
  static final LinkedHashMap<String, Uint8List> _mem = LinkedHashMap();
  static final Map<String, Future<Uint8List>> _inflight = {};
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

  /// 当前生效的内存缓存预算（字节），供测试/诊断读取。
  @visibleForTesting
  static int debugMemBudget() => _maxMemBytes;

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

  static String _key(String url) => md5.convert(utf8.encode(url)).toString();

  static Future<Uint8List> load(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function()? fetch,
  }) {
    final mem = _mem[url];
    if (mem != null) {
      _mem.remove(url);
      _mem[url] = mem;
      return Future.value(mem);
    }
    final running = _inflight[url];
    if (running != null) return running;
    final future = _load(url, headers: headers, fetch: fetch);
    _inflight[url] = future;
    future.whenComplete(() => _inflight.remove(url));
    return future;
  }

  static Future<Uint8List> _load(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function()? fetch,
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
        : Uint8List.fromList(await Net.getBytesAuto(url, headers: headers));
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

  static Future<void> preload(String url, {Map<String, String>? headers}) async {
    try {
      await load(url, headers: headers);
    } catch (_) {}
  }

  /// 磁盘缓存容量上限（字节）。图片长期看会越积越多，
  /// 超出时按文件修改时间从旧到新删除，直至低于上限。
  static const int _maxDiskBytes = 512 * 1024 * 1024;

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
