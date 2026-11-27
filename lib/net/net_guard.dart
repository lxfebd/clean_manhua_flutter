/// 出网地址护栏（P1-04）。
///
/// ## 为什么需要
/// 自定义源（JSON DSL）允许用户写任意 URL 规则。旧实现只在 `validate()` 里
/// 校验 `baseUrl` 一个字符串，而 `searchUrl` / `picListUrl` / `detailUrl` 是
/// 安装后逐次拼出来的——**baseUrl 合法完全不能阻止它们指向内网**。
/// 恶意源可以让 App 替它请求 `127.0.0.1`、路由器管理页、局域网 NAS。
///
/// 实测旧实现漏掉的形式（2026-11-27，写测试时当场命中）：
/// | 写法 | 等价于 | 旧实现 |
/// |---|---|---|
/// | `http://2130706433` | 127.0.0.1 | ❌ 放行 |
/// | `http://0x7f000001` | 127.0.0.1 | ❌ 放行 |
/// | `http://017700000001` | 127.0.0.1 | ❌ 放行 |
/// | `http://127.1` | 127.0.0.1 | ❌ 放行 |
/// | `http://localhost.` | localhost | ❌ 放行 |
///
/// 这些不是臆想——浏览器和 libcurl 都接受这种写法，攻击者一直在用。
///
/// ## 分层策略
/// 1. [checkUrl]：**字符串层**的快速拒绝。只做能静态判定的（协议、userinfo、
///    各种 IP 写法、明显的内网主机名）。这一层不联网，任何请求都要先过。
/// 2. [resolveAndCheck]：**DNS 层**。把主机解析成全部 A/AAAA，任一落在内网
///    就拒绝。这一层防 DNS 重绑定与"域名看起来合法、实际解析到内网"。
/// 3. 重定向：每一次跳转都要重新走 1+2——只在入口校验等于没校验。
///
/// ## 一个刻意的取舍
/// 默认**只对自定义源（DSL）强制**这套护栏，内置源走白名单放行。
/// 原因：内置源大量使用国内 CDN，其中个别会解析到 100.64/10 之类的
/// 运营商地址；对内置源一刀切会直接砍掉可用性。而内置源的域名是我们自己
/// 维护的、不来自不可信输入，风险面完全不同。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 出网被拒绝的原因。
class NetGuardViolation implements Exception {
  NetGuardViolation(this.reason, {this.url = ''});

  /// 中文拒绝理由（直接可展示）。
  final String reason;

  /// 触发拒绝的 URL。
  final String url;

  @override
  String toString() => 'NetGuardViolation: $reason${url.isEmpty ? '' : ' ($url)'}';
}

/// 出网策略。
enum NetGuardPolicy {
  /// 强制校验（自定义源/DSL 用）。拒绝一切内网目标。
  strict,

  /// 放行（内置源用）。仍拒绝非 http(s) 与 userinfo——这两种不存在任何
  /// 合法用途，放行只会掩盖 bug。
  permissive,
}

/// 检查结果。
class NetGuardResult {
  const NetGuardResult.ok() : violation = null;
  const NetGuardResult.reject(this.violation);

  final NetGuardViolation? violation;

  bool get allowed => violation == null;
}

/// 统一出网护栏。
class NetGuard {
  /// 全局开关：测试与极端场景可关闭。默认开启。
  ///
  /// ⚠️ 关闭后 SSRF 防护完全失效。除测试外不要动。
  static bool enabled = true;

  /// 测试专用豁免：允许访问的**本机端口**集合。
  ///
  /// ## 为什么需要
  /// 大量回归测试用 `HttpServer.bind(127.0.0.1, 0)` 起本地服务器来模拟源站
  /// （DSL 解析、市场索引、WebDAV 同步等）。P1-04 之后这些请求会被护栏
  /// 正确拦下——但那是测试基础设施，不是真实攻击面。
  ///
  /// ## 为什么不用"测试里关掉 NetGuard"
  /// 因为那样跑的就是**未经护栏的代码路径**，测试通过也不代表生产安全；
  /// 而且一旦某个测试忘了恢复开关，后续测试全都在无防护状态下跑。
  ///
  /// 用端口白名单：只有测试显式登记过的回环端口才放行，其它内网目标照拦。
  /// 生产路径永远不会调用 [allowLoopbackPortForTest]，集合恒空。
  static final Set<int> _testAllowedLoopbackPorts = <int>{};

  /// 仅测试用：允许访问 `127.0.0.1:<port>`。返回撤销函数。
  @visibleForTesting
  static void Function() allowLoopbackPortForTest(int port) {
    _testAllowedLoopbackPorts.add(port);
    return () => _testAllowedLoopbackPorts.remove(port);
  }

  /// 仅测试用：清空豁免集合。
  @visibleForTesting
  static void clearTestLoopbackPorts() => _testAllowedLoopbackPorts.clear();

  /// 当前策略。由 `SourceHttp.getUrl` 在每次请求前按源类型临时切换。
  ///
  /// **默认 permissive**：内置源是绝大多数请求的来源，它们的域名由本项目
  /// 维护、不来自不可信输入；且个别国内 CDN 会解析到 100.64/10 之类的
  /// 运营商地址，一刀切会直接砍掉可用性。只有自定义源（DSL）才切到 strict。
  ///
  /// 用静态字段而不是参数透传：请求链路上有 6 个入口（get / getCronet /
  /// getBytes / downloadBytes / …），逐个加参数必然漏。
  static NetGuardPolicy policy = NetGuardPolicy.permissive;

  /// 仅测试用：临时切换策略并返回还原函数。
  static NetGuardPolicy Function() testSwapPolicy(NetGuardPolicy p) {
    final old = policy;
    policy = p;
    return () => policy = old;
  }

  /// 字符串层检查：不联网，任何请求的第一步。
  static NetGuardResult checkUrl(String rawUrl) {
    if (!enabled) return const NetGuardResult.ok();
    final u = Uri.tryParse(rawUrl);
    if (u == null) {
      return NetGuardResult.reject(
          NetGuardViolation('URL 格式非法', url: rawUrl));
    }
    // 仅 http(s)。file:// / ftp:// / data: / javascript: 一律拒。
    if (u.scheme != 'http' && u.scheme != 'https') {
      return NetGuardResult.reject(
          NetGuardViolation('仅允许 http/https 协议，当前为 ${u.scheme}', url: rawUrl));
    }
    // userinfo（http://user:pass@host/）不存在合法的图片/API 用途，
    // 而且历史上有大量解析器差异被用来做 SSRF 绕过（不同组件对 @ 前后
    // 哪段是 host 判断不一致）。
    if (u.userInfo.isNotEmpty) {
      return NetGuardResult.reject(
          NetGuardViolation('URL 不得包含用户信息（user:pass@）', url: rawUrl));
    }
    final host = u.host;
    if (host.isEmpty) {
      return NetGuardResult.reject(
          NetGuardViolation('URL 缺少主机名', url: rawUrl));
    }
    if (policy == NetGuardPolicy.permissive) {
      return const NetGuardResult.ok();
    }
    // 测试豁免：显式登记过的回环端口放行（生产路径集合恒空）。
    if (_isTestAllowedLoopback(u)) return const NetGuardResult.ok();
    final reason = _internalHostReason(host);
    if (reason != null) {
      return NetGuardResult.reject(NetGuardViolation(reason, url: rawUrl));
    }
    return const NetGuardResult.ok();
  }

  /// URL 是否为测试豁免的「回环地址 + 已登记端口」。
  static bool _isTestAllowedLoopback(Uri u) {
    if (_testAllowedLoopbackPorts.isEmpty) return false;
    if (!_testAllowedLoopbackPorts.contains(u.port)) return false;
    final h = u.host.trim().toLowerCase();
    return h == '127.0.0.1' ||
        h == 'localhost' ||
        h == '::1' ||
        h == '0:0:0:0:0:0:0:1';
  }

  /// DNS 层检查：解析全部 A/AAAA，任一落在内网就拒绝。
  ///
  /// 防的是「域名看着正常，解析结果指向内网」——包括 DNS 重绑定：
  /// 攻击者让同一个域名第一次解析到公网（骗过安装时校验），后续解析到
  /// 127.0.0.1。所以**每次请求都要重解析**，不能缓存判定结果。
  static Future<NetGuardResult> resolveAndCheck(String rawUrl) async {
    if (!enabled) return const NetGuardResult.ok();
    final base = checkUrl(rawUrl);
    if (!base.allowed) return base;
    if (policy == NetGuardPolicy.permissive) return const NetGuardResult.ok();

    final host = Uri.parse(rawUrl).host;
    // 已经是 IP 字面量：checkUrl 判过了，无需再解析。
    if (_looksLikeIpLiteral(host)) return const NetGuardResult.ok();

    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
      if (addrs.isEmpty) {
        // 解析不出地址 → 请求本来也会失败，交给正常错误路径，
        // 不在这里当成攻击（否则网络抖动会变成"安全事件"）。
        return const NetGuardResult.ok();
      }
      for (final a in addrs) {
        final reason = _internalIpReason(a.address);
        if (reason != null) {
          return NetGuardResult.reject(NetGuardViolation(
              '$host 解析到 $reason（${a.address}）',
              url: rawUrl));
        }
      }
    } catch (_) {
      // DNS 失败：不拦（正常错误路径会处理），避免把断网误判成攻击。
      return const NetGuardResult.ok();
    }
    return const NetGuardResult.ok();
  }

  /// 供 `validate()` 等同步场景使用的字符串层判定。
  ///
  /// 返回中文理由（null = 合法）。这是 [checkUrl] 的便捷包装。
  ///
  /// **始终按 strict 判定**，不受 [policy] 影响：这个函数只被
  /// 「自定义源安装/校验」调用，那个场景没有 permissive 的理由。
  /// （全局 [policy] 默认 permissive 是为了内置源的运行期请求，
  /// 两者不是一回事，混用会让安装校验静默失效。）
  static String? hostReason(String rawUrl) {
    if (!enabled) return null;
    final old = policy;
    policy = NetGuardPolicy.strict;
    try {
      return checkUrl(rawUrl).violation?.reason;
    } finally {
      policy = old;
    }
  }

  /// 供 [NetConn.clientForRequest] 使用的连接级校验。
  ///
  /// dart:io 在**每次建立连接前**都会调用 `connectionFactory`，
  /// 包括跟随重定向之后的连接。所以在这里校验等价于「每一次实际出网」，
  /// 这正是「重定向到内网」能被拦住的原因（只看入口 URL 是拦不住的：
  /// 进来时是公网域名，服务端返回 `Location: http://192.168.1.1/` 才变内网）。
  ///
  /// 抛 [NetGuardViolation] 让请求直接失败，不会悄悄重建连接。
  static Future<void> assertConnectAllowed(Uri url) async {
    if (!enabled) return;
    final u = checkUrl(url.toString());
    if (!u.allowed) {
      throw NetGuardViolation(u.violation!.reason, url: url.toString());
    }
    if (policy != NetGuardPolicy.strict) return;
    // strict 下还要查 DNS：重定向目标可能是「看着像公网域名、实际解析到
    // 127.0.0.1」的 DNS 重绑定写法。
    final r = await resolveAndCheck(url.toString());
    if (!r.allowed) {
      throw NetGuardViolation(r.violation!.reason, url: url.toString());
    }
  }

  /// 是否像 IP 字面量（含本项目支持的整数/十六进制/短形式）。
  static bool _looksLikeIpLiteral(String host) =>
      _parseLegacyIPv4(host) != null || host.contains(':');

  /// 解析「各种写法」的 IPv4，返回点分十进制（失败返回 null）。
  ///
  /// 覆盖浏览器/libcurl 接受的全部历史形式：
  /// - `127.0.0.1`（标准）
  /// - `127.1`（短形式：末段写到 32 位整数的剩余位）
  /// - `2130706433`（单段十进制）
  /// - `0x7f000001`（十六进制）
  /// - `017700000001`（八进制）
  /// - `0x7f.0.0.1`（混合）
  static String? _parseLegacyIPv4(String host) {
    final h = host.trim();
    if (h.isEmpty) return null;
    final parts = h.split('.');
    if (parts.length > 4) return null;

    final nums = <int>[];
    for (final p in parts) {
      if (p.isEmpty) return null;
      int? v;
      if (p.length > 1 && (p.startsWith('0x') || p.startsWith('0X'))) {
        v = int.tryParse(p.substring(2), radix: 16);
      } else if (p.length > 1 && p.startsWith('0')) {
        // 前导 0 → 八进制（与 inet_aton 一致）。全是数字才当八进制，
        // 否则视为普通十进制（避免把 "0" 之外的怪串误判）。
        v = int.tryParse(p, radix: 8) ?? int.tryParse(p);
      } else {
        v = int.tryParse(p);
      }
      if (v == null || v < 0) return null;
      nums.add(v);
    }

    // 按 inet_aton 语义组合：最后一段占用剩余字节
    int ip;
    switch (nums.length) {
      case 1:
        ip = nums[0];
        break;
      case 2:
        if (nums[0] > 0xff) return null;
        ip = (nums[0] << 24) | nums[1];
        break;
      case 3:
        if (nums[0] > 0xff || nums[1] > 0xff) return null;
        ip = (nums[0] << 24) | (nums[1] << 16) | nums[2];
        break;
      default:
        if (nums.any((n) => n > 0xff)) return null;
        ip = (nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | nums[3];
    }
    if (ip < 0 || ip > 0xffffffff) return null;
    return '${(ip >> 24) & 0xff}.${(ip >> 16) & 0xff}.${(ip >> 8) & 0xff}.${ip & 0xff}';
  }

  /// 主机名层判断（字符串）。返回中文理由或 null。
  static String? _internalHostReason(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    // 末尾点（localhost. 与 localhost 等价）——旧实现漏了这个。
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (host.isEmpty) return '主机名为空';

    // 常见本机别名
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == 'localhost.localdomain' ||
        host == 'ip6-localhost' ||
        host == 'ip6-loopback') {
      return '本机地址 $rawHost';
    }

    // IPv6 字面量（Uri.host 会剥方括号）
    if (host.contains(':')) {
      return _internalIpReason(host);
    }

    // 各种写法的 IPv4 —— 这是旧实现漏得最多的地方
    final dotted = _parseLegacyIPv4(host);
    if (dotted != null) {
      return _internalIpReason(dotted);
    }
    return null;
  }

  /// IP 字面量判断（点分十进制或 IPv6 文本）。返回中文理由或 null。
  static String? _internalIpReason(String ip) {
    final s = ip.trim().toLowerCase();

    // IPv6
    if (s.contains(':')) {
      var v6 = s;
      // 剥掉 zone id（fe80::1%eth0）
      final pct = v6.indexOf('%');
      if (pct >= 0) v6 = v6.substring(0, pct);
      if (v6 == '::1' || v6 == '0:0:0:0:0:0:0:1') return '本机地址 ::1';
      if (v6 == '::' || v6 == '0:0:0:0:0:0:0:0') return '未指定地址 ::';
      if (v6.startsWith('fe8') ||
          v6.startsWith('fe9') ||
          v6.startsWith('fea') ||
          v6.startsWith('feb')) {
        return '链路本地地址 fe80::/10';
      }
      if (v6.startsWith('fc') || v6.startsWith('fd')) return '内网地址 fc00::/7';
      // IPv4 映射/兼容写法：::ffff:127.0.0.1
      final lastColon = v6.lastIndexOf(':');
      if (lastColon >= 0) {
        final tail = v6.substring(lastColon + 1);
        if (tail.contains('.')) {
          final dotted = _parseLegacyIPv4(tail);
          if (dotted != null) {
            final r = _internalIpReason(dotted);
            if (r != null) return 'IPv6 内嵌 $r';
          }
        }
      }
      return null;
    }

    final parts = s.split('.');
    if (parts.length != 4) return null;
    final nums = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return null;
      nums.add(v);
    }
    final a = nums[0], b = nums[1];
    if (a == 127) return '本机地址 127/8';
    if (a == 0) return '保留地址 0/8';
    if (a == 10) return '内网地址 10/8';
    if (a == 172 && b >= 16 && b <= 31) return '内网地址 172.16/12';
    if (a == 192 && b == 168) return '内网地址 192.168/16';
    if (a == 169 && b == 254) return '链路本地地址 169.254/16';
    if (a == 100 && b >= 64 && b <= 127) return '运营商 NAT 保留段 100.64/10';
    // 组播 / 保留 / 广播
    if (a >= 224 && a <= 239) return '组播地址 224/4';
    if (a >= 240) return '保留地址 240/4';
    return null;
  }
}
