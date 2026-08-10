import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'http_client.dart';

class RouteDiagnostic {
  const RouteDiagnostic();

  static Future<String?> fastest(List<String> candidates,
      {String? testPath, Duration timeout = const Duration(seconds: 4)}) async {
    if (candidates.isEmpty) return null;
    final completer = Completer<String>();
    var pending = candidates.length;

    for (final url in candidates) {
      _check(url, testPath, timeout).then((ok) {
        if (!completer.isCompleted && ok) {
          completer.complete(url);
        } else {
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }).onError((_, __) {
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }
    return completer.future;
  }

  static Future<bool> _check(String base, String? path, Duration timeout) async {
    final sw = Stopwatch()..start();
    try {
      final testUrl = path != null && path.isNotEmpty ? '$base$path' : base;
      final client = _SimpleHttp(timeout);
      final ok = await client.get(testUrl);
      client.close();
      if (ok) {
        debugPrint('Route OK: $testUrl ${sw.elapsedMilliseconds}ms');
      }
      return ok;
    } catch (e) {
      debugPrint('Route FAIL: $base${path ?? ""} ($e)');
      return false;
    }
  }
}

class _SimpleHttp {
  final HttpClient _client;
  _SimpleHttp(Duration timeout)
      : _client = (HttpClient()
          ..badCertificateCallback = (_, __, ___) => true)
  {
    _client.connectionTimeout = timeout;
  }

  Future<bool> get(String url) async {
    try {
      final req = await _client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', Net.defaultUA);
      final res = await req.close();
      await res.drain();
      return res.statusCode >= 200 && res.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  void close() => _client.close(force: true);
}