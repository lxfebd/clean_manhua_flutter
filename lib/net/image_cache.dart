import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'http_client.dart';

class ImageCacheManager {
  static final LinkedHashMap<String, Uint8List> _mem = LinkedHashMap();
  static final Map<String, Future<Uint8List>> _inflight = {};
  static int _memBytes = 0;

  /// 内存缓存预算（字节）。按平台取不同值：桌面内存宽裕可多缓存，
  /// 移动端（尤其 iOS 老设备）收紧防 OOM。
  /// 图片字节数：JM 长条图单张可达十几 MB，预算本质是"能同时保留几张"。
  static int get _maxMemBytes {
    if (kIsWeb) return 40 * 1024 * 1024;
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => 96 * 1024 * 1024,
      _ => 40 * 1024 * 1024,
    };
  }

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
