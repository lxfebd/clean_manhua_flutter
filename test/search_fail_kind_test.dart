import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/source_result.dart';
import 'package:xingmanxia/ui/search_providers.dart';

/// P1-14 搜索失败分类回归（纯函数，不联网）。
///
/// UI 要把「没有这部作品」和「源为什么失效」分开讲，才能给可操作提示。
/// 四种典型 fixture：超时 / 限流 / 人机验证 / 解析失败，各必须落到不同档位。
void main() {
  group('classifySearchFailure', () {
    test('超时 → timeout', () {
      expect(classifySearchFailure(TimeoutException('15s')),
          SearchFailKind.timeout);
      expect(classifySearchFailure(const SocketException('连接被重置')),
          SearchFailKind.timeout);
      expect(classifySearchFailure(const HandshakeException('TLS 失败')),
          SearchFailKind.timeout);
    });

    test('限流 → rateLimited', () {
      expect(
          classifySearchFailure(const SourceBlocked(BlockReason.rateLimited)),
          SearchFailKind.rateLimited);
      // P2-15 审计修复后：限流靠结构化 statusCode 判定，不数 message 字符串。
      expect(classifySearchFailure(SourceService('HTTP 429', 429)),
          SearchFailKind.rateLimited);
      expect(classifySearchFailure(Exception('HTTP 429 Too Many')),
          SearchFailKind.rateLimited);
    });

    test('人机验证 → captcha', () {
      expect(classifySearchFailure(const SourceBlocked(BlockReason.captcha)),
          SearchFailKind.captcha);
      expect(classifySearchFailure(const SourceBlocked(BlockReason.notFound)),
          SearchFailKind.captcha,
          reason: 'notFound 类的风控按 captcha 呈现（用户能做的动作相同）');
    });

    test('解析失败 → parse', () {
      expect(classifySearchFailure(const SourceParse('选择器未命中')),
          SearchFailKind.parse);
    });

    test('网络层 SourceError.network → timeout', () {
      expect(classifySearchFailure(const SourceNetwork('DNS 失败')),
          SearchFailKind.timeout);
    });

    test('其它 HTTP 4xx/5xx → other', () {
      for (final e in [
        SourceService('HTTP 500', 500),
        SourceService('HTTP 404', 404),
        const SourceUnauthorized('需要登录'),
        const SourceUnknown('boom'),
      ]) {
        expect(classifySearchFailure(e), SearchFailKind.other, reason: '$e');
      }
    });

    test('service 带状态码才可判限流（无状态码的业务错误不猜）', () {
      // 只写 message 不写状态码 → 不认定为 429，避免把业务错误误报成限流。
      expect(classifySearchFailure(const SourceService('HTTP 429')),
          SearchFailKind.other);
    });

    test('未知异常 → other（不猜）', () {
      expect(classifySearchFailure(StateError('x')), SearchFailKind.other);
      expect(classifySearchFailure('字符串错误'), SearchFailKind.other);
    });
  });

  group('searchFailLabel / SearchFailure.label', () {
    test('每个分类都有非空可读文案', () {
      for (final k in SearchFailKind.values) {
        expect(searchFailLabel(k), isNotEmpty, reason: '$k');
        expect(searchFailLabel(k).contains('\u5f02\u5e38'), isFalse,
            reason: '文案不能把原始异常透给用户');
      }
    });

    test('label 带源名 + 原因，但不含原始异常/URL', () {
      const f = SearchFailure('dm5', '动漫屋', SearchFailKind.timeout);
      expect(f.label, contains('动漫屋'));
      expect(f.label, contains('网络超时'));
      expect(f.label, isNot(contains('SocketException')));
    });
  });

  group('SourceSearchResult', () {
    test('成功时 ok=true、failure=null', () {
      const r = SourceSearchResult([], null);
      expect(r.ok, isTrue);
    });

    test('失败时 ok=false 且带明细', () {
      const r = SourceSearchResult(
          [], SearchFailure('dm5', '动漫屋', SearchFailKind.parse));
      expect(r.ok, isFalse);
      expect(r.failure!.kind, SearchFailKind.parse);
    });
  });
}
