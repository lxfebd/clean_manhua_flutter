import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';

void main() {
  group('RateLimiter', () {
    setUp(() => RateLimiter.debugForceEnabled = true);
    tearDown(() {
      RateLimiter.debugForceEnabled = false;
      RateLimiter.reset();
    });

    test('acquire 后并发计数 +1，release 后归位', () async {
      await RateLimiter.acquire('a.com');
      expect(RateLimiter.debugInflight('a.com'), 1);
      RateLimiter.release('a.com');
      expect(RateLimiter.debugInflight('a.com'), 0);
    });

    test('并发超过上限时排队，释放后才放行', () async {
      await Future.wait(
          [for (var i = 0; i < 5; i++) RateLimiter.acquire('a.com')]);
      expect(RateLimiter.debugInflight('a.com'), 5);

      var sixthDone = false;
      final sixth = RateLimiter.acquire('a.com').then((_) => sixthDone = true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(sixthDone, isFalse, reason: '并发已满，第 6 个请求必须排队');

      RateLimiter.release('a.com');
      await sixth;
      expect(sixthDone, isTrue);
      expect(RateLimiter.debugInflight('a.com'), 5);
    });

    test('令牌耗尽后 acquire 会等待补充（约 333ms/令牌）', () async {
      // 耗掉 burst 令牌（桶满 5 个），再释放全部并发槽位
      await Future.wait(
          [for (var i = 0; i < 5; i++) RateLimiter.acquire('b.com')]);
      for (var i = 0; i < 5; i++) {
        RateLimiter.release('b.com');
      }
      final t0 = DateTime.now();
      await RateLimiter.acquire('b.com');
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      expect(elapsed, greaterThanOrEqualTo(150),
          reason: '令牌需要时间补充，而不是立刻放行');
    });

    test('不同域名互不影响', () async {
      await Future.wait([
        RateLimiter.acquire('x.com'),
        RateLimiter.acquire('y.com'),
        RateLimiter.acquire('z.com'),
      ]);
      expect(RateLimiter.debugInflight('x.com'), 1);
      expect(RateLimiter.debugInflight('y.com'), 1);
      expect(RateLimiter.debugInflight('z.com'), 1);
    });
  });
}