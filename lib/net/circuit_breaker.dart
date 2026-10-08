import 'dart:async';
import 'dart:io';

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

  /// half-open 试探是否在进行中：冷却结束后只放行**一个**探针请求，
  /// 其余请求继续拒（防止冷却一到 N 个并发请求同时涌入已挂死的源——
  /// 试探的语义就是"一次一探"，并发探针会让 half-open 失效）。
  bool _probeInFlight = false;

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
          if (_probeInFlight) return false; // 已有探针在飞，其余请求继续拒
          _probeInFlight = true;
          _state = CircuitState.halfOpen;
          return true;
        }
        return false;
      case CircuitState.halfOpen:
        // 理论上 _probeInFlight 恒为 true；防御性兜底：异常路径丢失标记时
        // 也不放行第二个探针。
        return _probeInFlight;
    }
  }

  void recordSuccess() {
    _failures = 0;
    _state = CircuitState.closed;
    _probeInFlight = false;
  }

  void recordFailure() {
    if (_state == CircuitState.halfOpen) {
      // 探针失败：立即回到 open（重置冷却），不等 failureThreshold——
      // 半开试探的目的就是"确认源是否复活"，一次失败就足以否定。
      _probeInFlight = false;
      _state = CircuitState.open;
      _openedAt = DateTime.now();
      _failures = 0;
      return;
    }
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
/// 成功时直接返回结果；失败时抛 [SourceError]（已是类型化错误则原样透传，
/// 其余异常归约为 network/parse/service/unknown），调用方按类型 catch。
Future<T> withCircuit<T>(
  String key,
  Future<T> Function() fn,
) async {
  final cb = CircuitBreakerRegistry.forHost(key);
  if (!cb.allowRequest()) {
    throw SourceError.service(
      '源「$key」连续失败已进入熔断冷却，稍后自动恢复（可检查网络/代理或更换域名）',
    );
  }
  try {
    final r = await fn();
    cb.recordSuccess();
    return r;
  } catch (e) {
    cb.recordFailure();
    if (e is SourceError) rethrow;
    if (e is FormatException) {
      throw SourceError.parse(e.message);
    }
    if (e is TimeoutException) {
      throw SourceError.network(e.message);
    }
    if (e is SocketException) {
      throw SourceError.network(e.message);
    }
    if (e is HttpException) {
      throw SourceError.service(e.message);
    }
    throw SourceError.unknown(e.toString());
  }
}