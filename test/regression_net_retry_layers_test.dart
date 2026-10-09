import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';

/// P0-2 回归守护：重试层数收敛为 1。
///
/// 审计发现：`SourceHttp`（外层 withTransientRetry，最多 2 次）与
/// `Net.get`（内建瞬时重试，最多 2 次）叠在一起，单个 GET 最坏产生
/// **4 次真实出网请求**。
///
/// 收敛方案：`Net.get`/`Net.getCronet` 增加 `retry` 开关，默认 true
/// （直接调用方行为不变）；`SourceHttp` 三条 GET 路径显式传
/// `retry: false`，重试只由外层承担。
///
/// 因测试环境无真实网络（HttpClient 被 Flutter 测试绑定替换为恒返回
/// 400 的假实现），这里用 [Net.debugIoGetAttempts] 计数器断言
/// 「关掉内建重试后，失败请求真实出网次数不再翻倍」。
void main() {
  setUp(() {
    Net.debugIoGetAttempts = 0;
    Net.debugCountIoGet = true;
  });

  tearDown(() {
    Net.debugCountIoGet = false;
    Net.debugIoGetAttempts = 0;
  });

  test('retry: false → 瞬时失败只出网一次（不再叠一层内建重试）', () async {
    // 无效地址触发网络层失败（测试环境 HttpClient 恒失败/400）。
    const url = 'http://127.0.0.1:1/never';
    try {
      await Net.get(url, timeout: const Duration(milliseconds: 200), retry: false);
    } catch (_) {
      // 失败是预期的；断言的是「尝试次数」
    }
    expect(Net.debugIoGetAttempts, 1,
        reason: 'retry:false 时必须只有 1 次真实出网尝试');
  });

  test('retry: true（默认）→ 瞬时失败重试一次，共 2 次出网', () async {
    const url = 'http://127.0.0.1:1/never';
    try {
      await Net.get(url, timeout: const Duration(milliseconds: 200));
    } catch (_) {
      // 同上：只关心尝试次数
    }
    expect(Net.debugIoGetAttempts, 2,
        reason: '默认路径保持既有行为：瞬时失败重试一次');
  });
}
