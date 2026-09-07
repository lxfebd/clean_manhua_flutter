import 'package:connectivity_plus/connectivity_plus.dart';

/// 网络类型（智能预取策略依据）。
enum NetKind { wifi, cellular, none, unknown }

/// 智能预取策略器：按当前网络类型决定预取深度，
/// 避免移动数据下过度消耗流量、无网络下做无用请求。
///
/// 策略：
/// - Wi-Fi / 以太网：深度预取（当前章后 5 页 + 下章 5 页）
/// - 蜂窝网络：轻量预取（当前章后 2 页 + 下章 2 页）
/// - 无网络：不预取，节省电量与请求
///
/// 探测是异步的，翻页时机的大多数位置只能同步读取快照：
/// 应用打开阅读器时调用一次 [warmUp] 触发探测并缓存，
/// 此后 [cachedNetwork] / 深度查询都是同步返回，不阻塞翻页。
class SmartPrefetch {
  /// 探测结果缓存（秒），避免每翻一页都查系统网络状态。
  static const Duration _cacheTtl = Duration(seconds: 20);

  static NetKind? _cached;
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// WiFi / 以太网等不计流量的网络。
  static bool _isUnmetered(ConnectivityResult r) =>
      r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet;

  /// 探测当前网络类型并缓存（[._cacheTtl] 内重复调用直接返回缓存）。
  /// 阅读器打开时调用一次预热即可。
  static Future<NetKind> warmUp() async {
    final now = DateTime.now();
    if (_cached != null && now.difference(_cachedAt) < _cacheTtl) {
      return _cached!;
    }
    NetKind kind;
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.isEmpty ||
          results.every((r) => r == ConnectivityResult.none)) {
        kind = NetKind.none;
      } else if (results.any(_isUnmetered)) {
        // 有任意一种非计费网络即按 Wi-Fi 策略（Android 双栈时 VPN+WiFi 并存）
        kind = NetKind.wifi;
      } else if (results.any((r) => r == ConnectivityResult.mobile)) {
        kind = NetKind.cellular;
      } else {
        kind = NetKind.unknown;
      }
    } catch (_) {
      kind = NetKind.unknown; // 探测失败按保守策略处理：不预取
    }
    _cached = kind;
    _cachedAt = now;
    return kind;
  }

  /// 同步读取最近一次探测结果；从未探测时为 null（调用方按旧默认深度处理）。
  static NetKind? cachedNetwork() => _cached;

  /// 当前章向后预取页数。null=尚未探测 → 3（延用旧默认，保证首章体验不退步）。
  static int chapterDepth(NetKind? kind) => switch (kind) {
        NetKind.wifi => 5,
        NetKind.cellular => 2,
        NetKind.none => 0,
        NetKind.unknown => 2, // 探测失败，保守轻量
        null => 3,
      };

  /// 下一章预取页数。null=尚未探测 → 2（与旧行为一致）。
  static int nextChapterDepth(NetKind? kind) => switch (kind) {
        NetKind.wifi => 5,
        NetKind.cellular => 2,
        NetKind.none => 0,
        NetKind.unknown => 2,
        null => 2,
      };

  /// 测试用：清空缓存，强制下次重新探测。
  static void resetCache() {
    _cached = null;
    _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }
}