/// 自签证书信任策略（P1-27）。
///
/// ## 旧实现的问题
/// `clientForRequest` 里一行：
/// ```dart
/// if (trustSelfSigned) {
///   client.badCertificateCallback = (cert, h, port) => true;
/// }
/// ```
/// 用户为了连家里的 NAS 打开了这个开关，结果是**整个 App 的所有 HTTPS
/// 请求**都不再校验证书——包括 GitHub（更新包）、源市场索引、各类内容源。
/// 一个中间人只要伪造任意证书就能同时拿到：更新包的下载权、市场源的注入权、
/// 全部阅读数据。这是「为了一个小便利放弃全部 MITM 防护」的典型。
///
/// ## 现在的做法
/// 信任范围收敛到**具体主机 + 证书指纹**：
/// - 只有用户在设置里显式登记的 `(host, 指纹)` 组合才放行。
/// - 指纹用 SHA-256，比较时忽略大小写与冒号分隔符。
/// - **关键主机永远严格**：GitHub / 源市场 / 更新链 / 备份服务，
///   即使指纹匹配也拒绝放行（见 [kNeverTrustedHosts]）。
///
/// ## 兼容性
/// 旧开关 `trust_self_signed = true` 仍能读出来，但**不再有任何放行效果**——
/// 只是保留这个 key 避免升级后设置项状态丢失。真正生效必须登记指纹。
/// 这是有意的破坏性变更：旧语义本身不安全。
library;

import 'dart:io';

/// 一条自签信任规则。
class SelfSignedTrustRule {
  /// 主机名（不含端口，小写）。
  final String host;

  /// 证书指纹（十六进制，可带冒号，比较时归一）。
  ///
  /// ⚠️ 实际是 **SHA-1**，不是 SHA-256：dart:io 的 [X509Certificate] 只暴露
  /// `sha1` 属性（没有 sha256），拿不到更强的摘要。这是 SDK 限制，不是选择。
  ///
  /// SHA-1 在这里的风险可接受：我们比对的是**用户自己手工核对过**的指纹
  /// （自签证书场景，主机是我们明确信任的那一台），不是公网 CA 体系下
  /// 需要抗碰撞的对抗场景。用户从 NAS 管理页抄指纹，SHA-1 足够区分。
  final String fingerprint;

  const SelfSignedTrustRule({
    required this.host,
    required this.fingerprint,
  });

  /// 备注（用户自己填，便于分辨是哪台 NAS）。
  static const String notePrefix = 'note';

  Map<String, dynamic> toJson() => {
        'host': host,
        'fingerprint': fingerprint,
      };

  static SelfSignedTrustRule? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final h = raw['host'];
    // 兼容早期写的 'sha256' 键名（值是同一个 SHA-1 摘要）。
    final f = raw['fingerprint'] ?? raw['sha256'];
    if (h is! String || h.trim().isEmpty) return null;
    if (f is! String || f.trim().isEmpty) return null;
    return SelfSignedTrustRule(
      host: h.trim().toLowerCase(),
      fingerprint: normalizeFingerprint(f),
    );
  }
}

/// 指纹归一：去掉冒号/空格与常见前缀（sha1$ / SHA-1:），转小写。
String normalizeFingerprint(String raw) {
  var s = raw.toLowerCase().trim();
  // 兼容从 openssl / 浏览器 / NAS 管理页复制来的各种前缀写法
  for (final p in ['sha1\$', 'sha-1:', 'sha1:', 'sha-1 ', 'sha1 ']) {
    if (s.startsWith(p)) s = s.substring(p.length);
  }
  s = s.replaceAll(RegExp(r'[:\s\-]'), '');
  return s;
}

/// 字节 → 小写十六进制（无分隔）。
String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// **永远不信任自签的主机**（无论指纹是否匹配）。
///
/// 这些主机承载的是「代码/配置的下发通道」——一旦被中间人接管，
/// 攻击者能推送恶意更新包、注入恶意源索引、篡改同步备份。
/// 用自签信任去便利一台 NAS，代价绝不能是这些通道失去 MITM 防护。
const Set<String> kNeverTrustedHosts = {
  'github.com',
  'api.github.com',
  'objects.githubusercontent.com',
  'raw.githubusercontent.com',
  'codeload.github.com',
  'ghproxy.com',
  'ghfast.top',
  'gh-proxy.com',
};

/// 判断某 host 是否属于「永久严格」范围（含其子域）。
bool isAlwaysStrictHost(String host) {
  final h = host.toLowerCase().trim();
  if (h.isEmpty) return true;
  for (final strict in kNeverTrustedHosts) {
    if (h == strict || h.endsWith('.$strict')) return true;
  }
  return false;
}

/// 自签信任策略。
class SelfSignedTrust {
  SelfSignedTrust._();

  static List<SelfSignedTrustRule> _rules = const [];

  /// 仅测试用：替换规则集。
  static void testSetRules(List<SelfSignedTrustRule> rules) => _rules = rules;

  /// 仅测试用：清空。
  static void testReset() => _rules = const [];

  static List<SelfSignedTrustRule> get rules => List.unmodifiable(_rules);

  /// 该主机是否登记了信任规则（且不是永久严格主机）。
  static bool hasRuleFor(String host) {
    final h = host.toLowerCase().trim();
    if (isAlwaysStrictHost(h)) return false;
    return _rules.any((r) => r.host == h);
  }

  /// 校验回调：给定的证书是否可被该主机接受。
  ///
  /// 语义：
  /// - 永久严格主机 → 永不放行（返回 false，让连接按正常校验失败）。
  /// - 未登记该主机 → 不放行。
  /// - 已登记 → 指纹必须**完全匹配**。
  ///
  /// 注意：[X509Certificate] 只提供 `sha1`（dart:io 无 sha256），
  /// 所以指纹比对实际用的是 SHA-1。见 [SelfSignedTrustRule.fingerprint] 注释。
  static bool acceptCertificate(X509Certificate cert, String host) {
    final h = host.toLowerCase().trim();
    if (isAlwaysStrictHost(h)) return false;
    final want = _rules.where((r) => r.host == h).toList();
    if (want.isEmpty) return false;
    // dart:io 只给 sha1（无 sha256），且是原始字节，需转十六进制。
    // 见 SelfSignedTrustRule.fingerprint 注释。
    final got = normalizeFingerprint(_hex(cert.sha1));
    if (got.isEmpty) return false;
    for (final r in want) {
      if (normalizeFingerprint(r.fingerprint) == got) return true;
    }
    return false;
  }

  /// 生成 `badCertificateCallback`（给 [HttpClient] 用）。
  ///
  /// **没有规则时不设这个回调**——让 dart:io 走标准校验路径。
  /// 这一点很重要：设一个恒返回 false 的回调与不设，行为等价但会掩盖
  /// "为什么连不上"的诊断信息。
  static bool Function(X509Certificate cert, String host, int port)?
      callbackFor() {
    if (_rules.isEmpty) return null;
    return (cert, host, port) => acceptCertificate(cert, host);
  }

  /// 生成可用于优选 IP 直连路径的 `onBadCertificate`。
  ///
  /// 该回调只拿到 cert，拿不到 host，所以**只能用于已经确定主机的场景**
  /// （[NetConn.connectionTask] 知道 url.host）。为安全起见这里要求调用方
  /// 传入预期 host。
  static bool Function(X509Certificate cert)? onBadCertificateForHost(
      String host) {
    final h = host.toLowerCase().trim();
    if (isAlwaysStrictHost(h)) return null;
    if (!hasRuleFor(h)) return null;
    return (cert) => acceptCertificate(cert, h);
  }

  /// 从持久化恢复规则。启动时调用一次。
  static Future<void> restore(
      Future<dynamic> Function(String key) readJson) async {
    try {
      final raw = await readJson('self_signed_trust_rules');
      if (raw is! List) return;
      final out = <SelfSignedTrustRule>[];
      for (final e in raw) {
        final r = SelfSignedTrustRule.tryParse(e);
        // 单条坏数据跳过，不影响其它规则。
        if (r == null) continue;
        // 永久严格主机的规则直接丢弃（防止从备份/手改文件塞进来）。
        if (isAlwaysStrictHost(r.host)) continue;
        out.add(r);
      }
      _rules = out;
    } catch (_) {
      _rules = const [];
    }
  }

  /// 序列化当前规则（供持久化）。
  static List<Map<String, dynamic>> toJson() =>
      [for (final r in _rules) r.toJson()];

  /// 替换全部规则。
  static void replaceAll(List<SelfSignedTrustRule> next) {
    _rules = [
      for (final r in next)
        if (!isAlwaysStrictHost(r.host)) r,
    ];
  }
}
