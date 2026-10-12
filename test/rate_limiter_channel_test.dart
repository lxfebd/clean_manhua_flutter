import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';

/// 分通道限流的语义守护（修复「封面图把同域数据接口饿死 → 首页列表转圈、
/// 一屏封面排队 6s+ 才开拉」的回归）。
///
/// 旧实现 API 与图片共用一个 3 req/s、并发 ≤5 的小桶：
/// 一屏 24 张封面瞬间耗光 burst，列表接口排在 24 张图后面拿不到令牌。
/// 分通道后 (channel, host) 各自独立计费，本文件断言隔离性成立。
void main() {
  setUp(() {
    RateLimiter.debugForceEnabled = true;
    RateLimiter.reset();
  });
  tearDown(() {
    RateLimiter.debugForceEnabled = false;
    RateLimiter.reset();
  });

  test('API 桶耗尽后，同域名的 asset 通道立即放行（互不饿死）', () async {
    // 占满 API 通道：burst(5) 全部消耗且不释放 → API 再 acquire 必然排队
    for (var i = 0; i < 5; i++) {
      await RateLimiter.acquire('same.host');
    }
    expect(RateLimiter.debugInflight('same.host'), 5);

    // 同域名的静态资源通道必须立即可用——这是修复的核心语义
    final sw = Stopwatch()..start();
    await RateLimiter.acquire('same.host', channel: RateChannel.asset)
        .timeout(const Duration(seconds: 2),
            onTimeout: () => fail('asset 被 API 桶饿死：修复未生效'));
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(250));
    expect(RateLimiter.debugInflight('same.host'), 5,
        reason: 'API 并发计数不受 asset 通道影响');
    expect(RateLimiter.debugInflight('same.host', channel: RateChannel.asset),
        1);
  });

  test('asset 通道并发上限 6（浏览器级），API 上限 5 保持不变', () async {
    // asset 放满 6 个并发（burst 12 足够，考验的是并发槽位）
    await Future.wait([
      for (var i = 0; i < 6; i++)
        RateLimiter.acquire('c.host', channel: RateChannel.asset)
    ]);
    expect(
        RateLimiter.debugInflight('c.host', channel: RateChannel.asset), 6);

    var seventhDone = false;
    final seventh = RateLimiter
        .acquire('c.host', channel: RateChannel.asset)
        .then((_) => seventhDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(seventhDone, false, reason: 'asset 第 7 个并发应排队');

    // API 通道的并发上限必须仍是 5（爬虫礼仪未放松）
    await Future.wait([
      for (var i = 0; i < 5; i++) RateLimiter.acquire('c.host')
    ]);
    expect(RateLimiter.debugInflight('c.host'), 5);
    var apiSixthDone = false;
    final apiSixth =
        RateLimiter.acquire('c.host').then((_) => apiSixthDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(apiSixthDone, false, reason: 'API 第 6 个并发必须排队（礼仪未放松）');

    // 清理，避免悬挂 Future 触发 fake-async 报错
    for (var i = 0; i < 6; i++) {
      RateLimiter.release('c.host', channel: RateChannel.asset);
    }
    for (var i = 0; i < 5; i++) {
      RateLimiter.release('c.host');
    }
    await seventh;
    await apiSixth;
  });
}
