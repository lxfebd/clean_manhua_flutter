import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../sources/comic_source.dart';
import '../sources/local_novel_source.dart';
import '../sources/novel_source.dart';
import '../sources/source_base.dart';
import '../sources/source_config.dart';
import '../sources/source_manager.dart';
import '../sources/video_source.dart';

/// 单主机探测结果（复用网络工具页的 TCP+TLS 方案）。
class HostProbeResult {
  final String host;
  final bool ok;
  final int latencyMs;
  final String? error;
  const HostProbeResult(this.host, this.ok, this.latencyMs, this.error);
}

/// 解析探测结果：一次真实列表请求能否解析出条目。
class _ParseResult {
  final bool ok;
  final int items;
  final String? error;
  const _ParseResult(this.ok, this.items, this.error);
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

  /// 解析探测：最近一次真实列表请求能否解析出条目。
  /// 传输层可达但解析为空 = 源站结构已变（选择器/接口失效），
  /// 这是「服务器还在，内容却刷不出来」那一类静默失效的唯一信号。
  /// 未跑过解析探测的源为 true（不误报）。
  final bool parseOk;
  final String? parseError;
  final int parseCheckedAt; // epoch ms，0 = 从未探测
  const SourceHealth({
    required this.sourceId,
    required this.sourceName,
    required this.score,
    required this.reachable,
    required this.latencyMs,
    required this.successRate,
    this.error,
    required this.checkedAt,
    this.parseOk = true,
    this.parseError,
    this.parseCheckedAt = 0,
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

  /// 解析探测超时：比传输探测（5s）宽，列表页要真拉 HTML/JSON。
  static const Duration _parseTimeout = Duration(milliseconds: 12000);

  Timer? _timer;
  bool _running = false;
  bool _busy = false;
  /// 首轮（冷启动那一次）只探传输，不跑解析：
  /// App 刚起就要给每个源补一次真实列表请求，冷网络下太贵。
  /// 稳态（每 2 小时）才带上解析探测。
  bool _firstCycleDone = false;

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
            parseOk: (m['parseOk'] as bool?) ?? true,
            parseError: m['parseError'] as String?,
            parseCheckedAt: (m['parseCheckedAt'] as num?)?.toInt() ?? 0,
          );
        }
      }
    } catch (e) {
      ErrorLogger.instance.warn('SourceHealthMonitor.restore failed: $e');
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
              'parseOk': h.parseOk,
              'parseError': h.parseError,
              'parseCheckedAt': h.parseCheckedAt,
            }).toList(),
      );
    } catch (e) {
      ErrorLogger.instance.warn('SourceHealthMonitor.persist failed: $e');
    }
  }

  /// 手动触发一次检测（源管理页「重新检测」）。
  Future<void> checkNow() => _runOnce(quick: false);

  // ── 仅供测试：把纯内存逻辑暴露出来，避免测试必须真跑网络 ─────────────
  // [_record] / [_applyParse] 本身不碰 IO，只是写缓存 + 算评分；直接调
  // [_runOnce] 才会真探网。测试要断言的是「解析字段继承 / 只改解析三字段」
  // 这类合并语义，用这两个入口即可覆盖，且不引入 flaky。

  @visibleForTesting
  void debugRecord(String id, String name, HostProbeResult r) =>
      _record(id, name, r);

  @visibleForTesting
  void debugApplyParse(String id, {required bool ok, String? error}) =>
      _applyParse(id, _ParseResult(ok, 0, error));

  /// 真网契约用：跑一次单个源的解析探测并返回结果。
  /// 单元测试不碰它（要发真实请求）；真网验证由
  /// `test/verify_source_parse_probe_test.dart` 覆盖，挂每日 workflow。
  @visibleForTesting
  Future<({bool ok, int items, String? error})> debugParseOne(
      AppSource s) async {
    final r = await _parseOne(s);
    return (ok: r.ok, items: r.items, error: r.error);
  }

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
      // 并发 3（文档宣称但实际 Future.wait 全量并发——修复：跑满 3 路
      // worker 池，超出的排队，避免一次探 40+ 个源打满连接/Socket）。
      const concurrency = 3;
      final results = <(({String id, String name, Uri uri}), HostProbeResult)>[];
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= todo.length) return;
          final t = todo[i];
          final r = await _probe(t.uri);
          results.add((t, r));
        }
      }
      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
      for (final (t, r) in results) {
        _record(t.id, t.name, r);
      }

      // 解析探测：只对传输层可达的源发真实列表请求。传输都不通的源
      // 再解析一次只是重复同一个失败、还多花一次请求，没有信息增量。
      final doParse = _firstCycleDone;
      _firstCycleDone = true;
      if (doParse) {
        final okIds =
            results.where((r) => r.$2.ok).map((r) => r.$1.id).toSet();
        final sources = (await _parseSources())
            .where((s) => okIds.contains(s.id))
            .toList();
        if (sources.isNotEmpty) {
          const pc = 3; // 与传输探测共用并发度
          final pres = <(AppSource, _ParseResult)>[];
          var pnext = 0;
          Future<void> pworker() async {
            while (true) {
              final i = pnext++;
              if (i >= sources.length) return;
              final s = sources[i];
              pres.add((s, await _parseOne(s)));
            }
          }
          await Future.wait([for (var i = 0; i < pc; i++) pworker()]);
          for (final (s, r) in pres) {
            _applyParse(s.id, r);
          }
        }
      }
      await _persist();
      _revision?.value++;
    } catch (e) {
      ErrorLogger.instance.warn('SourceHealthMonitor.runOnce failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// 配置里的 host 字符串 → Uri（P1-02）。
  ///
  /// 配置的 `hosts` 存的是**完整 URL**（`https://m.dm5.com`，见
  /// source_config.dart 的默认表），旧实现把它原样交给
  /// `InternetAddress.lookup`——带 scheme 的串不是合法主机名，DNS 阶段
  /// 必然抛错，于是**所有源的健康灯恒红**，健康监控形同虚设。
  /// 裸域名（历史配置/用户手填）按 https 兜底。纯函数，便于单测。
  static Uri? parseHostUri(String host) {
    final h = host.trim();
    if (h.isEmpty) return null;
    final u = Uri.tryParse(h.contains('://') ? h : 'https://$h');
    if (u == null || u.host.isEmpty) return null;
    return u;
  }

  /// 探测端口：显式端口优先；否则按 scheme（http=80，其余=443）。
  static int portFor(Uri u) =>
      u.hasPort ? u.port : (u.scheme == 'http' ? 80 : 443);

  /// 是否需要 TLS 握手：http 不做（鞍山影院那类「HTTPS 握手失效但 HTTP
  /// 正常」的源，旧实现固定打 443+TLS 会把可用源判成不可用）。
  static bool needsTls(Uri u) => u.scheme != 'http';

  Future<List<({String id, String name, Uri uri})>> _targets() async {
    final out = <({String id, String name, Uri uri})>[];
    final cfgs = await SourceConfigStore.all();

    /// 取该源第一个可用 host 的 Uri；没有返回 null。
    Uri? uriOf(String engineId, String name) {
      final c = cfgs.where((c) => c.engineId == engineId).firstOrNull;
      final hosts = c != null && c.hosts.isNotEmpty
          ? c.hosts
          : const <String>[];
      for (final h in hosts) {
        final u = parseHostUri(h);
        if (u != null) return u;
      }
      return null;
    }

    void addAllFrom(List<AppSource> sources) {
      for (final s in sources) {
        if (!s.isEnabled) continue;
        final u = uriOf(s.id, s.name);
        if (u != null) out.add((id: s.id, name: s.name, uri: u));
      }
    }

    // P1-01：三类源都要进传输探测。旧实现只加漫画+小说，视频源后又按
    // 「传输成功的 okIds」过滤解析探测——视频 id 根本不在传输结果里，
    // 于是视频源**永远不会**被解析探测（注释却说覆盖三类）。
    addAllFrom(SourceManager.sources);
    addAllFrom(SourceManager.novelSources);
    addAllFrom(SourceManager.videoSources);
    return out;
  }

  /// 参与解析探测的源：漫画 + 小说 + 视频（启用中的全部）。
  Future<List<AppSource>> _parseSources() async {
    final out = <AppSource>[];
    out.addAll(await SourceManager.enabledSources());
    for (final s in await SourceManager.enabledNovelSources()) {
      // LocalNovelSource 的 rank() 恒返回 const []——本地导入的书没有远端
      // 榜单，「拿空列表」是它的正常语义，不是解析失败。拿它去打真实网络
      // 请求只会恒报「榜单解析为空」，属于探针自身的假阳性（CI 首跑即暴露）。
      // 本地源的可用性由书架自身保证，不需要也不应该由健康探针裁决。
      if (s is LocalNovelSource) continue;
      out.add(s);
    }
    out.addAll(await SourceManager.enabledVideoSources());
    return out;
  }

  /// 单个源的解析探测：走一次真实列表请求，看还能不能解析出条目。
  ///
  /// 漫画/小说用 `rank(1)`（一次请求、不需要先取分类）；
  /// 视频没有 rank，先取分类再拉第一个分类的列表（两次请求）。
  Future<_ParseResult> _parseOne(AppSource s) async {
    try {
      if (s is ComicSource) {
        final list = await s.rank(1).timeout(_parseTimeout);
        return _ParseResult(list.isNotEmpty, list.length,
            list.isEmpty ? '榜单解析为空' : null);
      }
      if (s is NovelSource) {
        final list = await s.rank(1).timeout(_parseTimeout);
        return _ParseResult(list.isNotEmpty, list.length,
            list.isEmpty ? '榜单解析为空' : null);
      }
      if (s is VideoSource) {
        final cats = await s.categories().timeout(_parseTimeout);
        if (cats.isEmpty) return const _ParseResult(false, 0, '分类解析为空');
        final list =
            await s.listByCategory(cats.first.id, 1).timeout(_parseTimeout);
        return _ParseResult(list.isNotEmpty, list.length,
            list.isEmpty ? '列表解析为空' : null);
      }
      return const _ParseResult(false, 0, '不支持的源类型');
    } catch (e) {
      return _ParseResult(false, 0, _short(e));
    }
  }

  /// 把解析结果合并进缓存：只改解析三字段，不动传输层评分——
  /// 「慢」和「读不懂」是两种失效，不让连通性分数把后者洗白。
  void _applyParse(String id, _ParseResult r) {
    final prev = _cache[id];
    if (prev == null) return;
    _cache[id] = SourceHealth(
      sourceId: prev.sourceId,
      sourceName: prev.sourceName,
      score: prev.score,
      reachable: prev.reachable,
      latencyMs: prev.latencyMs,
      successRate: prev.successRate,
      error: prev.error,
      checkedAt: prev.checkedAt,
      parseOk: r.ok,
      parseError: r.error,
      parseCheckedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 单主机探测：DNS + TCP（按 scheme 选端口）+ TLS（仅 https，严格验证）。
  ///
  /// 三处修正（P1-02）：
  /// 1. DNS 只查 `uri.host`——旧实现把**完整 URL** 交给 lookup，带 scheme 的
  ///    串不是合法主机名，恒抛错 → 所有源健康灯恒红，监控形同虚设；
  /// 2. 端口按 scheme/显式端口——旧实现固定 443，HTTP-only 的源（README 记载
  ///    的鞍山影院）被错判成不可用；
  /// 3. 去掉 `onBadCertificate: (_) => true`——旧实现把自签/中间人证书一律
  ///    判「可达」，与真实业务路径的语义相反。现在证书问题单独报错。
  Future<HostProbeResult> _probe(Uri uri) async {
    final host = uri.host;
    final port = portFor(uri);
    final sw = Stopwatch()..start();
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(milliseconds: 4000));
      if (addrs.isEmpty) {
        return HostProbeResult(host, false, -1, 'DNS 无记录');
      }
      final raw = await Socket.connect(addrs.first, port,
              timeout: const Duration(milliseconds: _probeTimeoutMs))
          .timeout(const Duration(milliseconds: _probeTimeoutMs));
      if (!needsTls(uri)) {
        // HTTP-only：TCP 通即视为可达。不做 TLS——否则「HTTPS 握手失效但
        // HTTP 正常」的源会被误判不可用，而用户实际能看。
        sw.stop();
        raw.destroy();
        return HostProbeResult(host, true, sw.elapsedMilliseconds, null);
      }
      try {
        // 严格证书验证（不设 onBadCertificate）：与业务请求同一标准。
        final secure = await SecureSocket.secure(raw, host: host)
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
      // 新记录的解析字段继承上一次结论：本轮没探解析就不许把
      // 已知的「解析失败」擦回 true（默认），等 doParse 那轮写真实结果。
      parseOk: prev?.parseOk ?? true,
      parseError: prev?.parseError,
      parseCheckedAt: prev?.parseCheckedAt ?? 0,
    );
  }

  final Map<String, List<bool>> _history = {};
}