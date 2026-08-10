import 'dart:async';

import '../sources/source_result.dart';

/// 熔断器状态。
enum CircuitState { closed, open, halfOpen }

/// 每 host（或每源 engineId）一个熔断器：连续失败达到阈值后进入 open，停止请求，
/// 冷却时间过后进入 half-open 试探一次，成功则恢复 closed，失败则继续 open。
///
/// 这是"多源稳定性"的核心：一个源抖动不会拖垮整页，也不会对已知挂死的源反复发起无效请求。
class CircuitBreaker {
  final int failureThreshold;
  final Duration cooldown;

  int _failures = 0;
  CircuitState _state = CircuitState.closed;
  DateTime _openedAt = DateTime.fromMillisecondsSinceEpoch(0);

  CircuitBreaker({
    this.failureThreshold = 3,
    this.cooldown = const Duration(minutes: 2),
  });

  CircuitState get state => _state;
  bool get isOpen => _state == CircuitState.open;

  /// 是否允许本次请求。open 状态下只有冷却结束后才放行一次试探。
  bool allowRequest() {
    switch (_state) {
      case CircuitState.closed:
        return true;
      case CircuitState.open:
        if (DateTime.now().difference(_openedAt) >= cooldown) {
          _state = CircuitState.halfOpen;
          return true;
        }
        return false;
      case CircuitState.halfOpen:
        return true;
    }
  }

  void recordSuccess() {
    _failures = 0;
    _state = CircuitState.closed;
  }

  void recordFailure() {
    _failures++;
    if (_failures >= failureThreshold) {
      _state = CircuitState.open;
      _openedAt = DateTime.now();
    }
  }
}

/// 全局熔断器注册表，按 host / engineId 复用同一个实例。
class CircuitBreakerRegistry {
  static final Map<String, CircuitBreaker> _breakers = {};

  static CircuitBreaker forHost(String key) =>
      _breakers.putIfAbsent(key, () => CircuitBreaker());

  static CircuitState stateOf(String key) => forHost(key).state;
}

/// 带熔断保护的源调用：先查熔断器，再执行，最后回写成功/失败。
///
/// 返回 [SourceResult]，调用方无需关心熔断细节。
Future<SourceResult<T>> withCircuit<T>(
  String key,
  Future<T> Function() fn,
) async {
  final cb = CircuitBreakerRegistry.forHost(key);
  if (!cb.allowRequest()) {
    return SourceResult.err(SourceError.service(
      '源「$key」连续失败已进入熔断冷却，稍后自动恢复（可检查网络/代理或更换域名）',
    ));
  }
  final r = await runCatching(fn);
  if (r is SourceErr) {
    cb.recordFailure();
  } else {
    cb.recordSuccess();
  }
  return r;
}
