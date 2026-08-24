import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'http_client.dart';

class ImageCacheManager {
  static final LinkedHashMap<String, Uint8List> _mem = LinkedHashMap();
  static final Map<String, Future<Uint8List>> _inflight = {};
  static int _memBytes = 0;
  static const int _maxMemBytes = 40 * 1024 * 1024;
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
