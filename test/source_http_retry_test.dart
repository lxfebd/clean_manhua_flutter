import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/source_http.dart';

void main() {
  group('SourceHttp.withTransientRetry', () {
    test('瞬时失败（SocketException）后重试成功', () async {
      var calls = 0;
      final r = await SourceHttp.withTransientRetry(() async {
        calls++;
        if (calls == 1) throw const SocketException('Connection reset');
        return 'ok';
      });
      expect(r, 'ok');
      expect(calls, 2);
    });

    test('超时（TimeoutException）后重试成功', () async {
      var calls = 0;
      final r = await SourceHttp.withTransientRetry(() async {
        calls++;
        if (calls == 1) throw TimeoutException('timed out');
        return 'ok';
      });
      expect(r, 'ok');
      expect(calls, 2);
    });

    test('HTTP 5xx 视为瞬时错误并重试', () async {
      var calls = 0;
      final r = await SourceHttp.withTransientRetry(() async {
        calls++;
        if (calls == 1) throw Exception('HTTP 503: Service Unavailable');
        return 'ok';
      });
      expect(r, 'ok');
      expect(calls, 2);
    });

    test('持续瞬时失败：重试 maxAttempts 次后抛出', () async {
      var calls = 0;
      await expectLater(
        SourceHttp.withTransientRetry(() async {
          calls++;
          throw const SocketException('down');
        }),
        throwsA(isA<SocketException>()),
      );
      expect(calls, SourceHttp.maxAttempts);
    });

    test('非瞬时错误（解析失败）不重试，立即抛出', () async {
      var calls = 0;
      await expectLater(
        SourceHttp.withTransientRetry(() async {
          calls++;
          throw const FormatException('bad html');
        }),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 1);
    });
  });
}
