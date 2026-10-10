/// 直链 → 原生播放器接管的「失败隔离」决策。
///
/// 背景：网页通道每 900ms 轮询捕获 video src，交给 mpv 试开。防盗链源站
/// （签名/时间戳参数）每次返回的完整 URL 都不同，旧实现按「完整 URL 精确
/// 匹配」的记忆集去重，永远 miss → mpv 每失败一次宿主就重建 WebView → 轮询
/// 重新捕获 → 再试 → 再失败：无限横跳（抽搐）。
///
/// 本类按**归一化资源键**（scheme + host + path，去 query/片段）计数失败：
/// 签名刷新只变 query，键不变 → 同一资源的失败次数不会因签名轮换被重置；
/// 换集/换资源 path 变 → 键变 → 自动获得新的尝试机会。同一资源连续失败
/// [HandoffQuarantine.maxFailures] 次后判定为「隔离」：宿主应立即停止对该
/// 资源的一切接管尝试（秒拒，不再触发任何状态翻转/WebView 重建）。
class HandoffQuarantine {
  HandoffQuarantine({this.maxFailures = HandoffQuarantine.defaultMaxFailures});

  /// 同一资源允许的连续失败次数上限。达到后 [isQuarantined] 恒 true，
  /// 直到 [resetAll] 或 [clear] 清除。
  static const int defaultMaxFailures = 2;

  /// 上限（构造时可选覆盖，测试/诊断用）。
  final int maxFailures;

  /// 计数表：归一化键 → 连续失败次数。
  final Map<String, int> _failures = <String, int>{};

  /// 归一化资源键：scheme://host + path，去 query 与片段。
  /// 非 http(s) URL（blob: 等）返回空串 → 视为「不可归一化」，不参与隔离。
  static String normalize(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    if (uri.scheme != 'http' && uri.scheme != 'https') return '';
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return '';
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '${uri.scheme}://$host$port$path';
  }

  /// 该资源是否已被隔离（连续失败达到上限）。
  bool isQuarantined(String url) {
    final key = normalize(url);
    if (key.isEmpty) return false;
    return (_failures[key] ?? 0) >= maxFailures;
  }

  /// 记录一次失败；返回该资源现是否已达标隔离。
  bool recordFailure(String url) {
    final key = normalize(url);
    if (key.isEmpty) return false;
    final next = (_failures[key] ?? 0) + 1;
    _failures[key] = next;
    return next >= maxFailures;
  }

  /// 清除一次失败计数（如切换资源成功接管）。不存在的键无副作用。
  void clear(String url) {
    final key = normalize(url);
    if (key.isEmpty) return;
    _failures.remove(key);
  }

  /// 清空全部计数（换集/重新开始解析时调用）。
  void resetAll() => _failures.clear();

  /// 当前被隔离的资源键数（测试/诊断用）。
  int get quarantinedCount =>
      _failures.values.where((n) => n >= maxFailures).length;
}
