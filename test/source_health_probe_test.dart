import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/source_health_monitor.dart';

/// P1-01 / P1-02 健康探测的**纯函数**回归（不联网）。
///
/// 背景：配置里的 `hosts` 存的是完整 URL（`https://m.dm5.com`），旧探测把
/// 它原样交给 `InternetAddress.lookup` —— 带 scheme 的串不是合法主机名，
/// DNS 阶段必然抛错，于是**所有源的健康灯恒红**，源健康监控形同虚设。
/// 这三个纯函数就是那道分水岭，必须焊死。
void main() {
  group('parseHostUri（P1-02：配置 host → Uri）', () {
    test('完整 https URL 解出正确 host/scheme', () {
      final u = SourceHealthMonitor.parseHostUri('https://m.dm5.com')!;
      expect(u.host, 'm.dm5.com');
      expect(u.scheme, 'https');
      expect(u.hasPort, isFalse);
    });

    test('完整 http URL 保留 scheme（HTTP-only 源）', () {
      final u = SourceHealthMonitor.parseHostUri('http://www.dainyew.com')!;
      expect(u.host, 'www.dainyew.com');
      expect(u.scheme, 'http');
    });

    test('裸域名按 https 兜底（历史配置/用户手填）', () {
      final u = SourceHealthMonitor.parseHostUri('m.dm5.com')!;
      expect(u.host, 'm.dm5.com');
      expect(u.scheme, 'https');
    });

    test('带路径/带端点的 URL 只取主机部分', () {
      final u =
          SourceHealthMonitor.parseHostUri('https://api.mangadex.org/at-home')!;
      expect(u.host, 'api.mangadex.org');
    });

    test('空/非法输入返回 null（不让探测带着脏串去打 DNS）', () {
      expect(SourceHealthMonitor.parseHostUri(''), isNull);
      expect(SourceHealthMonitor.parseHostUri('   '), isNull);
      expect(SourceHealthMonitor.parseHostUri('https://'), isNull);
      expect(SourceHealthMonitor.parseHostUri('::::'), isNull);
    });

    test('解析结果交给 lookup 的必须是裸主机名', () {
      // 这条是「恒红」bug 的直接断言：任何配置形态解出的 host 都不得含 scheme。
      for (final raw in [
        'https://m.dm5.com',
        'http://www.dainyew.com',
        'https://api.mangadex.org/at-home',
        'm.dm5.com',
        'https://ghproxy.net/',
      ]) {
        final u = SourceHealthMonitor.parseHostUri(raw)!;
        expect(u.host.contains('://'), isFalse, reason: raw);
        expect(u.host.contains('/'), isFalse, reason: raw);
        expect(u.host, isNotEmpty, reason: raw);
      }
    });
  });

  group('portFor / needsTls（P1-02：不再固定 443+TLS）', () {
    Uri u(String s) => SourceHealthMonitor.parseHostUri(s)!;

    test('https 默认 443、http 默认 80', () {
      expect(SourceHealthMonitor.portFor(u('https://m.dm5.com')), 443);
      expect(SourceHealthMonitor.portFor(u('http://www.dainyew.com')), 80);
    });

    test('显式端口优先', () {
      expect(SourceHealthMonitor.portFor(u('https://a.com:8443')), 8443);
      expect(SourceHealthMonitor.portFor(u('http://a.com:8080')), 8080);
    });

    test('只有 http 不做 TLS', () {
      expect(SourceHealthMonitor.needsTls(u('https://m.dm5.com')), isTrue);
      expect(SourceHealthMonitor.needsTls(u('http://www.dainyew.com')),
          isFalse);
    });

    test('鞍山影院这类 HTTP-only 源：端口 80 且不握手（旧实现固定 443 会误判）',
        () {
      final dainyew = u('http://www.dainyew.com');
      expect(SourceHealthMonitor.portFor(dainyew), 80);
      expect(SourceHealthMonitor.needsTls(dainyew), isFalse);
    });
  });
}
