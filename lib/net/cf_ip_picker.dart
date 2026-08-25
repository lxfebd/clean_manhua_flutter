import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Cloudflare 优选 IP 探测。
///
/// 用途：部分源（如 TvTFun）走系统 DNS 可能解析到不可达/慢的 CF 节点，
/// 本工具从 CF 官方 IPv4 段中找出当前网络下延迟最低、可连通（TLS 握手成功）的节点，
/// 供 [Net.preferredHostIps] 直连使用（与 `http_client.dart` 的优选 IP 机制一致）。
class CfIpPicker {
  CfIpPicker._();

  /// 官方 /ips-v4 拉取失败时的内置兜底段（常用 CF 段）。
  static const List<String> _seedCidrs = [
    '104.16.0.0/13',
    '172.64.0.0/13',
    '162.158.0.0/15',
    '173.245.48.0/20',
    '188.114.96.0/20',
  ];

  /// 单 IP 探测超时（TCP 连接 + TLS 握手）。
  static const Duration _probeTimeout = Duration(seconds: 5);

  /// 探测并发数。
  static const int _concurrency = 12;

  /// 候选 IP 上限。
  static const int _maxIps = 80;

  /// 拉取 CF 官方 IPv4 段并采样出候选 IP 列表；失败时回退内置段。
  static Future<List<String>> candidateIps() async {
    final cidrs = <String>[];
    try {
      final req = await HttpClient()
          .getUrl(Uri.parse('https://www.cloudflare.com/ips-v4'))
          .timeout(const Duration(seconds: 8));
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        for (final line in body.split('\n')) {
          final c = line.trim();
          if (c.isNotEmpty && c.contains('/')) cidrs.add(c);
        }
      }
    } catch (_) {
      // 拉取失败，走内置兜底
    }
    if (cidrs.isEmpty) cidrs.addAll(_seedCidrs);
    return _sample(cidrs);
  }

  /// 从 CIDR 段中采样：每段在主机范围内加随机抖动取 1 个可用 IP，去重并限容。
  /// 抖动使多次扫描探索到不同节点，提高找到更低延迟 IP 的概率。
  static List<String> _sample(List<String> cidrs) {
    final out = <String>[];
    final seen = <int>{};
    final rand = Random();
    for (final cidr in cidrs) {
      if (out.length >= _maxIps) break;
      final slash = cidr.indexOf('/');
      if (slash <= 0) continue;
      final prefix = int.tryParse(cidr.substring(slash + 1));
      if (prefix == null || prefix < 0 || prefix > 32) continue;
      final base = _ipv4ToInt(cidr.substring(0, slash));
      if (base < 0) continue;
      final hostBits = 32 - prefix;
      // 抖动上限：/8 段(2^24)取满即可，更大段(hostBits<8)不可能出现。
      final maxOffset = hostBits <= 24 ? (1 << hostBits) : (1 << 24);
      final v = (base & (0xffffffff << hostBits)) + 2 + rand.nextInt(maxOffset);
      if (seen.add(v)) out.add(_intToIpv4(v));
    }
    return out;
  }

  static int _ipv4ToInt(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return -1;
    int v = 0;
    for (final s in p) {
      final n = int.tryParse(s);
      if (n == null || n < 0 || n > 255) return -1;
      v = (v << 8) | n;
    }
    return v;
  }

  static String _intToIpv4(int v) =>
      '${(v >> 24) & 0xff}.${(v >> 16) & 0xff}.${(v >> 8) & 0xff}.${v & 0xff}';

  /// 并发探测每个 IP：TCP 443 连接 + TLS 握手（SNI=domain，忽略证书校验）。
  /// 握手成功即视为该 IP 可连通该域名；返回按延迟升序的结果。
  static Future<List<CfIpResult>> probe(
    String domain,
    List<String> ips, {
    void Function(int done, int total)? onProgress,
  }) async {
    final results = <CfIpResult>[];
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= ips.length) return;
        final ip = ips[i];
        try {
          final sw = Stopwatch()..start();
          final raw = await Socket.connect(ip, 443, timeout: _probeTimeout);
          try {
            final secure = await SecureSocket.secure(raw,
                    host: domain, onBadCertificate: (_) => true)
                .timeout(_probeTimeout);
            sw.stop();
            secure.destroy();
            results.add(CfIpResult(ip, sw.elapsedMilliseconds));
          } catch (_) {
            raw.destroy();
          }
        } catch (_) {
          // 连接失败，忽略
        }
        done++;
        onProgress?.call(done, ips.length);
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    results.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    return results;
  }
}

/// 单个候选 IP 的探测结果。
class CfIpResult {
  final String ip;
  final int latencyMs;
  const CfIpResult(this.ip, this.latencyMs);
}
