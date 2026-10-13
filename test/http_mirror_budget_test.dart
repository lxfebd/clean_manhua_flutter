import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';

/// 镜像链总预算（totalTimeout）的纯逻辑单测：锁死「每个候选的实际超时 =
/// min(自身 timeout, 剩余预算)」的时序，防止将来改坏 deadline 语义。
///
/// flutter_test 的 HttpOverrides 拦截真实网络（恒 400），无法端到端验证
/// getBytesMirrors 的实测超时；把预算计算抽成纯函数 [_candidateBudget]，
/// 这里直接锁它的返回值语义。
void main() {
  final base = DateTime(2026, 1, 1, 0, 0, 0);

  test('无总预算：返回原 timeout（兼容旧调用方）', () {
    expect(Net.candidateBudget(const Duration(seconds: 12), null,
            now: base),
        const Duration(seconds: 12));
    // timeout 为空也原样返回 null
    expect(Net.candidateBudget(null, null, now: base), isNull);
  });

  test('预算充足：取自身 timeout（不被总预算缩短）', () {
    final deadline = base.add(const Duration(seconds: 30));
    // 距 deadline 还有 30s，自身 12s 更短 → 用 12s
    expect(Net.candidateBudget(const Duration(seconds: 12), deadline,
            now: base),
        const Duration(seconds: 12));
  });

  test('预算不足：被剩余预算截断', () {
    // 已过 25s，剩 5s；自身 12s 更长 → 截到 5s
    final deadline = base.add(const Duration(seconds: 30));
    expect(Net.candidateBudget(const Duration(seconds: 12), deadline,
            now: base.add(const Duration(seconds: 25))),
        const Duration(seconds: 5));
  });

  test('预算恰好耗尽：返回 null（调用方随后抛 TimeoutException）', () {
    final deadline = base.add(const Duration(seconds: 30));
    // now == deadline：剩余 0 → null
    expect(Net.candidateBudget(const Duration(seconds: 12), deadline,
            now: deadline),
        isNull);
    // now 已过 deadline → null
    expect(Net.candidateBudget(const Duration(seconds: 12), deadline,
            now: deadline.add(const Duration(seconds: 1))),
        isNull);
  });

  test('无自身 timeout 时：跟随剩余预算', () {
    final deadline = base.add(const Duration(seconds: 20));
    expect(Net.candidateBudget(null, deadline,
            now: base.add(const Duration(seconds: 8))),
        const Duration(seconds: 12));
    // 预算剩 0 → null
    expect(Net.candidateBudget(null, deadline, now: deadline), isNull);
  });
}