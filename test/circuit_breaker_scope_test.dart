import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/circuit_breaker.dart';
import 'package:xingmanxia/net/net_conn.dart';
import 'package:xingmanxia/sources/source_result.dart';

/// P2-15 熔断「计数范围」与「HTTP 状态码转换」回归。
///
/// 审计实测出的两个真 bug：
/// 1. `recordFailure()` 无条件计数 → 解析失败（页面拿到了、选择器失效）
///    和一个 404 就能把源推进 2 分钟冷却，服务端明明是好的；
/// 2. `HttpStatusException` 只 `implements Exception`（不是 `HttpException`），
///    熔断层的 `is HttpException` 分支匹配不到 → 所有 404/429/500 都落进
///    `SourceError.unknown`，上层「5xx 换 host」「429 归限流」全部静默失效。
///
/// 测试用唯一 key（注册表是全局 Map，没有 reset），避免用例互相污染。
int _seq = 0;
String _key(String tag) => 'cb-scope-test:$tag:${_seq++}';

void main() {
  group('计数范围（P2-15）', () {
    test('解析失败大量出现也不熔断（页面拿到了，是选择器问题）', () async {
      final k = _key('parse');
      for (var i = 0; i < 12; i++) {
        await expectLater(
          withCircuit<String>(
              k, () async => throw const SourceError.parse('选择器未命中')),
          throwsA(isA<SourceParse>()),
        );
      }
      expect(CircuitBreakerRegistry.stateOf(k), CircuitState.closed,
          reason: '解析失败不代表 host 不健康，不能把源冷却掉');
    });

    test('404 / 401 / 403 不计熔断（路径或凭据问题）', () async {
      for (final c in [404, 401, 403]) {
        final k = _key('4xx-$c');
        for (var i = 0; i < 12; i++) {
          await expectLater(
            withCircuit<String>(
                k, () async => throw HttpStatusException(c, 'nope')),
            throwsA(isA<SourceService>()),
          );
        }
        expect(CircuitBreakerRegistry.stateOf(k), CircuitState.closed,
            reason: 'HTTP $c 是请求自身的问题，不该冷却源');
      }
    });

    test('5xx 累计到阈值后进入 open', () async {
      final k = _key('5xx');
      for (var i = 0; i < 3; i++) {
        await expectLater(
          withCircuit<String>(
              k, () async => throw HttpStatusException(503, 'down')),
          throwsA(isA<SourceService>()),
        );
      }
      expect(CircuitBreakerRegistry.stateOf(k), CircuitState.open,
          reason: '连续 3 次服务端错误 → 熔断（默认阈值 3）');
    });

    test('熔断期间请求被快速拒绝（抛 service 冷却提示）', () async {
      final k = _key('open-reject');
      for (var i = 0; i < 3; i++) {
        await expectLater(
            withCircuit<String>(
                k, () async => throw const SourceError.network('连接被重置')),
            throwsA(isA<SourceError>()));
      }
      expect(CircuitBreakerRegistry.stateOf(k), CircuitState.open);
      await expectLater(
        withCircuit<String>(k, () async => 'ok'),
        throwsA(isA<SourceService>()),
        reason: '冷却期内的请求应直接抛 service 提示，不再真实发网',
      );
    });

    test('成功后熔断器复位', () async {
      final k = _key('reset');
      for (var i = 0; i < 2; i++) {
        await expectLater(
            withCircuit<String>(
                k, () async => throw const SourceError.network('x')),
            throwsA(isA<SourceError>()));
      }
      expect(await withCircuit<String>(k, () async => 'ok'), 'ok');
      expect(CircuitBreakerRegistry.stateOf(k), CircuitState.closed);
    });
  });

  group('HTTP 状态码转换（P2-15）', () {
    test('HttpStatusException → SourceService 且带结构化 statusCode', () async {
      final k = _key('convert');
      await expectLater(
        withCircuit<String>(
            k, () async => throw HttpStatusException(429, 'slow down')),
        throwsA(
          isA<SourceService>()
              .having((e) => e.statusCode, 'statusCode', 429),
        ),
      );
    });

    test('每个状态码都带对（不是只落在 unknown）', () async {
      for (final c in [404, 403, 429, 500, 502]) {
        final k = _key('code-$c');
        await expectLater(
          withCircuit<String>(
              k, () async => throw HttpStatusException(c, 'body')),
          throwsA(isA<SourceService>()
              .having((e) => e.statusCode, 'statusCode', c)),
          reason: 'HTTP $c 必须带结构化状态码',
        );
      }
    });

    test('传输层 HttpException → network（换 host 才对症）', () async {
      final k = _key('httpexc');
      await expectLater(
        withCircuit<String>(k,
            () async => throw HttpException('连接在收完整响应头前被关闭')),
        throwsA(isA<SourceNetwork>()),
      );
    });

    test('未知异常 → unknown（不猜）', () async {
      final k = _key('unknown');
      await expectLater(
        withCircuit<String>(k, () async => throw StateError('boom')),
        throwsA(isA<SourceUnknown>()),
      );
    });
  });
}
