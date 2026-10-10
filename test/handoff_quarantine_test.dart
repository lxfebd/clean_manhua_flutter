import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/handoff_quarantine.dart';

void main() {
  group('HandoffQuarantine.normalize', () {
    test('去掉 query 与片段，只保留 scheme://host + path', () {
      expect(
        HandoffQuarantine.normalize(
            'https://cdn.example.com/video/123/index.m3u8?sign=abc&ts=1234'),
        'https://cdn.example.com/video/123/index.m3u8',
      );
    });

    test('签名轮换（query 不同）归一化后键相同', () {
      final a = HandoffQuarantine.normalize(
          'https://cdn.example.com/video/123/index.m3u8?sign=aaa&ts=1');
      final b = HandoffQuarantine.normalize(
          'https://cdn.example.com/video/123/index.m3u8?sign=bbb&ts=2');
      expect(a, b);
      expect(a, isNot(equals('https://cdn.example.com/video/123/index.m3u8?sign=aaa&ts=1')));
    });

    test('端口保留，host 大小写归一', () {
      expect(
        HandoffQuarantine.normalize('http://CDN.Example.com:8080/v.m3u8?x=1'),
        'http://cdn.example.com:8080/v.m3u8',
      );
    });

    test('无 path 时归一为 /', () {
      expect(HandoffQuarantine.normalize('https://cdn.example.com?x=1'),
          'https://cdn.example.com/');
    });

    test('非 http(s)（blob:）返回空串，不参与隔离', () {
      expect(HandoffQuarantine.normalize('blob:https://site.com/uuid'), '');
      expect(HandoffQuarantine.normalize(''), '');
      expect(HandoffQuarantine.normalize('not a url'), '');
    });
  });

  group('HandoffQuarantine 隔离判定', () {
    test('同一资源失败 maxFailures 次后隔离', () {
      final q = HandoffQuarantine();
      const url = 'https://cdn.example.com/v/1.m3u8?sign=a';
      expect(q.isQuarantined(url), isFalse);
      // 第 1 次失败未达标
      expect(q.recordFailure(url), isFalse);
      expect(q.isQuarantined(url), isFalse);
      // 第 2 次失败达标（maxFailures=2）
      expect(q.recordFailure(url), isTrue);
      expect(q.isQuarantined(url), isTrue);
    });

    test('签名轮换不会重置计数（同一资源隔离持续生效）', () {
      final q = HandoffQuarantine();
      const a = 'https://cdn.example.com/v/1.m3u8?sign=aaa';
      const b = 'https://cdn.example.com/v/1.m3u8?sign=bbb';
      q.recordFailure(a);
      expect(q.isQuarantined(b), isFalse);
      q.recordFailure(b);
      expect(q.isQuarantined(a), isTrue);
      expect(q.isQuarantined(b), isTrue);
    });

    test('recordSuccess 清除该资源计数，可再次尝试', () {
      final q = HandoffQuarantine();
      const url = 'https://cdn.example.com/v/1.m3u8';
      q.recordFailure(url);
      q.recordFailure(url);
      expect(q.isQuarantined(url), isTrue);
      q.clear(url);
      expect(q.isQuarantined(url), isFalse);
      expect(q.recordFailure(url), isFalse);
    });

    test('不同资源（path 不同）独立计数', () {
      final q = HandoffQuarantine();
      q.recordFailure('https://cdn.example.com/v/1.m3u8');
      q.recordFailure('https://cdn.example.com/v/1.m3u8');
      expect(q.isQuarantined('https://cdn.example.com/v/1.m3u8'), isTrue);
      // 换集 → path 变 → 新资源未被隔离
      expect(q.isQuarantined('https://cdn.example.com/v/2.m3u8'), isFalse);
    });

    test('不可归一化 URL（blob:）永不隔离', () {
      final q = HandoffQuarantine();
      q.recordFailure('blob:https://site.com/uuid');
      expect(q.isQuarantined('blob:https://site.com/uuid'), isFalse);
      expect(q.quarantinedCount, 0);
    });

    test('resetAll 清空全部', () {
      final q = HandoffQuarantine();
      q.recordFailure('https://a.com/1.m3u8');
      q.recordFailure('https://a.com/1.m3u8');
      q.recordFailure('https://b.com/2.m3u8');
      q.recordFailure('https://b.com/2.m3u8');
      expect(q.quarantinedCount, 2);
      q.resetAll();
      expect(q.quarantinedCount, 0);
      expect(q.isQuarantined('https://a.com/1.m3u8'), isFalse);
    });

    test('quarantinedCount 只统计达标键', () {
      final q = HandoffQuarantine();
      q.recordFailure('https://a.com/1.m3u8'); // 1 次，未达标
      expect(q.quarantinedCount, 0);
      q.recordFailure('https://a.com/1.m3u8'); // 2 次，达标
      expect(q.quarantinedCount, 1);
    });
  });
}
