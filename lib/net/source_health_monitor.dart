import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../net/local_store.dart';
import '../sources/source_config.dart';
import '../sources/source_manager.dart';

/// 单主机探测结果（复用网络工具页的 TCP+TLS 方案）。
class HostProbeResult {
  final String host;
  final bool ok;
  final int latencyMs;
  final String? error;
  const HostProbeResult(this.host, this.ok, this.latencyMs, this.error);
}

/// 源健康度（综合评分）结果。
///
/// 评分 0-100：连通性 40 + 延迟 30 + 成功率 30。
/// - 连通性：主域名 TCP+TLS 可达。
/// - 延迟：latencyMs 映射（≤800ms 满分，每 +500ms 扣 5 分，>10s 记 0）。
/// - 成功率：最近 N 次检测成功占比。
class SourceHealth {
  final String sourceId;
  final String sourceName;
  final int score; // 0-100
  final bool reachable; // 主域名连通
  final int latencyMs;
  final double successRate; // 0-1
  final String? error;
  final int checkedAt; // epoch ms
  const SourceHealth({
    required this.sourceId,
    required this.sourceName,
    required this.score,
    required this.reachable,
    required this.latencyMs,
    required this.successRate,
    this.error,
    required this.checkedAt,
  });

  String get scoreLabel {
    if (score >= 80) return '健康';
    if (score >= 50) return '一般';
    if (score >= 25) return '较差';
    return '不可用';
  }
}

/// 源健康监控（单例）。
///
/// 职责：
/// - [start]：启动后台任务，先做一次快速检测，再每 2 小时静默检测一次。
/// - 熔断：某源连续失败 3 次后进入 30 分钟冷却（不再反复请求），冷却结束自动重试。
/// - 结果缓存供 UI（源管理页灯/健康度）读取，并持久化（source_health）。
/// - 轻量：并发 3，单主机超时 5s，全程不阻塞主流程。
class SourceHealthMonitor {
  SourceHealthMonitor._();

  static final SourceHealthMonitor instance = SourceHealthMonitor._();

  static const String _file = 'source_health';

  static const int _probeTimeoutMs = 5000;
  static const int _coolDownMs = 30 * 60 * 1000; // 熔断冷却 30 分钟
  static const int _failThreshold = 3; // 连续失败 N 次触发熔断
  static const Duration _interval = Duration(hours: 2);

  Timer? _timer;
  bool _running = false;
  bool _busy = false;

  final Map<String, SourceHealth> _cache = {};
  final Map<String, int> _consecutiveFails = {};
  final Map<String, int> _coolDownUntil = {};

  /// 最近结果（按源 id）。未检测过的源不在内。
  Map<String, SourceHealth> get results => Map.unmodifiable(_cache);

  SourceHealth? healthOf(String sourceId) => _cache[sourceId];

  ValueNotifier<int>? _revision;
  /// UI 监听健康度刷新。
  ValueNotifier<int> get revision => _revision ??= ValueNotifier<int>(0);

  /// 启动：先快速检测，再每 2 小时定时。幂等。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _restore();
    // 首检放后台，不阻塞启动时序
    unawaited(_runOnce(quick: true));
    _timer ??= Timer.periodic(_interval, (_) {
      unawaited(_runOnce(quick: true));
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  Future<void> _restore() async {
    try {
      final raw = await LocalStore.readJson(_file);
      if (raw is List) {
        for (final m in raw.whereType<Map>()) {
          final id = m['sourceId'] as String?;
          if (id == null) continue;
          _cache[id] = SourceHealth(
            sourceId: id,
            sourceName: (m['sourceName'] as String?) ?? id,
            score: (m['score'] as num?)?.toInt() ?? 0,
            reachable: (m['reachable'] as bool?) ?? false,
            latencyMs: (m['latencyMs'] as num?)?.toInt() ?? -1,
            successRate: (m['successRate'] as num?)?.toDouble() ?? 0,
            error: m['error'] as String?,
            checkedAt: (m['checkedAt'] as num?)?.toInt() ?? 0,
          );
        }
      }
    } catch (e) {
      debugPrint('SourceHealthMonitor.restore failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await LocalStore.writeJson(
        _file,
        _cache.values.map((h) => {
              'sourceId': h.sourceId,
              'sourceName': h.sourceName,
              'score': h.score,
              'reachable': h.reachable,
              'latencyMs': h.latencyMs,
              'successRate': h.successRate,
              'error': h.error,
              'checkedAt': h.checkedAt,
            }).toList(),
      );
    } catch (e) {
      debugPrint('SourceHealthMonitor.persist failed: $e');
    }
  }

  /// 手动触发一次检测（源管理页「重新检测」）。
  Future<void> checkNow() => _runOnce(quick: false);

  /// 执行一轮检测：漫画+小说源（启用中）各取主域名。
  Future<void> _runOnce({required bool quick}) async {
    if (_busy) return;
    _busy = true;
    try {
      final targets = await _targets();
      // 熔断过滤
      final now = DateTime.now().millisecondsSinceEpoch;
      final todo = targets.where((t) {
        final until = _coolDownUntil[t.id];
        return until == null || now >= until;
      }).toList();
      // 并发 3
      final results = await Future.wait(todo.map((t) async {
        final r = await _probe(t.host);
        return (t, r);
      }));
      for (final (t, r) in results) {
        _record(t.id, t.name, r);
      }
      await _persist();
      _revision?.value++;
    } catch (e) {
      debugPrint('SourceHealthMonitor.runOnce failed: $e');
    } finally {
      _busy = false;
    }
  }

  Future<List<({String id, String name, String host})>> _targets() async {
    final out = <({String id, String name, String host})>[];
    final cfgs = await SourceConfigStore.all();
    String hostOf(SourceConfig c, List<String> fallback) {
      final h = c.hosts.isNotEmpty ? c.hosts : fallback;
      return h.isNotEmpty ? h.first : '';
    }

    for (final s in SourceManager.sources) {
      if (!s.isEnabled) continue;
      final c = cfgs.where((c) => c.engineId == s.id).firstOrNull;
      final host = hostOf(c ?? SourceConfig(engineId: s.id, id: s.id, name: s.name), const []);
      if (host.isNotEmpty) out.add((id: s.id, name: s.name, host: host));
    }
    for (final s in SourceManager.novelSources) {
      if (!s.isEnabled) continue;
      final c = cfgs.where((c) => c.engineId == s.id).firstOrNull;
      final host = hostOf(c ?? SourceConfig(engineId: s.id, id: s.id, name: s.name), const []);
      if (host.isNotEmpty) out.add((id: s.id, name: s.name, host: host));
    }
    return out;
  }

  /// 单主机探测：DNS + TCP 443 + TLS（忽略证书），复用网络工具页方案。
  Future<HostProbeResult> _probe(String host) async {
    final sw = Stopwatch()..start();
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(milliseconds: 4000));
      if (addrs.isEmpty) {
        return HostProbeResult(host, false, -1, 'DNS 无记录');
      }
      final raw = await Socket.connect(addrs.first, 443,
              timeout: const Duration(milliseconds: _probeTimeoutMs))
          .timeout(const Duration(milliseconds: _probeTimeoutMs));
      try {
        final secure = await SecureSocket.secure(raw,
                host: host, onBadCertificate: (_) => true)
            .timeout(const Duration(milliseconds: _probeTimeoutMs));
        sw.stop();
        secure.destroy();
        return HostProbeResult(host, true, sw.elapsedMilliseconds, null);
      } catch (e) {
        raw.destroy();
        return HostProbeResult(host, false, -1, _short(e));
      }
    } catch (e) {
      sw.stop();
      return HostProbeResult(host, false, -1, _short(e));
    }
  }

  String _short(Object e) {
    final s = e.toString();
    final idx = s.indexOf(':');
    return idx > 0 ? s.substring(0, idx) : s;
  }

  /// 记录一次结果：更新连续失败/熔断、计算评分、写缓存。
  void _record(String id, String name, HostProbeResult r) {
    final prev = _cache[id];
    final failCount = r.ok ? 0 : (_consecutiveFails[id] ?? 0) + 1;
    _consecutiveFails[id] = failCount;
    if (!r.ok && failCount >= _failThreshold) {
      // 触发熔断：冷却 30 分钟
      _coolDownUntil[id] = DateTime.now().millisecondsSinceEpoch + _coolDownMs;
    }
    if (r.ok && failCount == 0 && _coolDownUntil.containsKey(id)) {
      _coolDownUntil.remove(id); // 恢复
    }

    // 成功率：最近 5 次滑动
    final history = _history[id] ?? <bool>[];
    history.add(r.ok);
    if (history.length > 5) history.removeAt(0);
    _history[id] = history;
    final success = history.where((b) => b).length / history.length;

    final latencyScore = r.ok
        ? (r.latencyMs <= 800
            ? 30
            : (30 - (((r.latencyMs - 800) ~/ 500) * 5)).clamp(0, 30))
        : 0;
    final connectivity = r.ok ? 40 : 0;
    final score = connectivity + latencyScore + (success * 30).round();

    _cache[id] = SourceHealth(
      sourceId: id,
      sourceName: name,
      score: score.clamp(0, 100),
      reachable: r.ok,
      latencyMs: r.ok ? r.latencyMs : (prev?.latencyMs ?? -1),
      successRate: success,
      error: r.ok ? null : r.error,
      checkedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  final Map<String, List<bool>> _history = {};
}