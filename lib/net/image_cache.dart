import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'http_client.dart';

/// 轻量图片缓存：内存（上限 [memoryLimit] 张，FIFO 淘汰）+ 磁盘（data/images/<md5>.img）。
///
/// 同一 URL 并发去重：同时只发一次网络请求，其余等待同一 Future。
/// 借鉴 JHenTai / extended_image 的缓存思想，零额外依赖实现；
/// 后续若需要更完整的生命周期管理（TTL/配额/失败策略），可平移到 extended_image。
class ImageCacheManager {
  static final Map<String, Uint8List> _mem = {};
  static final Map<String, Future<Uint8List>> _inflight = {};
  static const int memoryLimit = 256;
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

  /// 加载图片字节：内存 → 磁盘 → 网络（并回写内存+磁盘）。
  ///
  /// 可传入 [fetch] 自定义下载逻辑（如带解扰），默认走 [Net.getBytes]。
  static Future<Uint8List> load(
    String url, {
    Map<String, String>? headers,
    Future<Uint8List> Function()? fetch,
  }) {
    final mem = _mem[url];
    if (mem != null) return Future.value(mem);
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
    // 1) 磁盘
    final f = File('${(await _imagesDir()).path}/${_key(url)}.img');
    try {
      if (f.existsSync()) {
        final b = await f.readAsBytes();
        _putMem(url, b);
        return b;
      }
    } catch (_) {}
    // 2) 网络
    final bytes = fetch != null
        ? await fetch()
        : Uint8List.fromList(await Net.getBytes(url, headers: headers));
    _putMem(url, bytes);
    try {
      await f.writeAsBytes(bytes, flush: true);
    } catch (_) {}
    return bytes;
  }

  static void _putMem(String url, Uint8List b) {
    if (_mem.length >= memoryLimit && _mem.isNotEmpty) {
      _mem.remove(_mem.keys.first);
    }
    _mem[url] = b;
  }

  /// 预取（失败静默，不影响阅读流）。
  static Future<void> preload(String url, {Map<String, String>? headers}) async {
    try {
      await load(url, headers: headers);
    } catch (_) {}
  }

  static int get memoryCount => _mem.length;

  /// 磁盘缓存文件列表（测试/统计用）。
  static Future<List<File>> diskFiles() async {
    final d = await _imagesDir();
    return d.existsSync() ? d.listSync().whereType<File>().toList() : const [];
  }

  /// 清空内存 + 磁盘缓存。
  static Future<void> clear() async {
    _mem.clear();
    try {
      final d = await _imagesDir();
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    _dir = null;
  }
}
