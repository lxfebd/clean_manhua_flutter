import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';

/// 验证令牌桶限流：burst 耗尽后按目标速率（3 req/s）持续补充令牌。
///
/// 回归场景：`_bucketFor` 曾在每次 acquire 时重置 `lastRefillMs`，
/// 使 `refill()` 恒计算 elapsed≈0，令牌永不补充——burst 耗尽后
/// 该域名的所有请求在 `acquire` 的 while(true) 循环中永久挂起。
/// 本测试以超时断言捕获该活锁（缺陷下等待 >2s 失败），修复后应即时返回。
void main() {
  setUp(() {
    RateLimiter.debugForceEnabled = true;
    RateLimiter.reset();
  });

  tearDown(() {
    RateLimiter.reset();
  });

  test('burst 耗尽后等待 1 秒，下一次 acquire 应快速拿到令牌（不活锁）', () async {
    // 连发 5 次，消耗完 burst（每次立即释放并发槽位）
    for (var i = 0; i < 5; i++) {
      await RateLimiter.acquire('www.example.com');
      RateLimiter.release('www.example.com');
    }

    // 等待 1 秒：按 3 req/s 设计，应补充约 3 个令牌
    await Future<void>.delayed(const Duration(seconds: 1));

    final sw = Stopwatch()..start();
    // 缺陷实现下这里会活锁挂起（>2s 触发超时失败）；
    // 修复后桶内已有令牌，应立即返回。
    await RateLimiter.acquire('www.example.com')
        .timeout(const Duration(seconds: 2));
    RateLimiter.release('www.example.com');
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(250));
  });
}