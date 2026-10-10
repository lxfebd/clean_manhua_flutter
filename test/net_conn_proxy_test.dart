import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/net_conn.dart';

/// [NetConn] 代理配置的纯逻辑回归测试（无网络）。
///
/// 覆盖 [NetConn._proxyDirective] / [NetConn.applyProxy] /
/// [NetConn.resolveProxyDirective] 三条契约：
///   1. 指令格式：socks5/socks5h → "SOCKS5 host:port"，socks4 → "SOCKS4"，
///      其余/裸 host:port → "PROXY host:port"（不认识的 scheme 兜底为 PROXY）
///   2. 优先级：单源代理（resolveProxyDirective 的 proxy 参数）> 全局代理
///      （NetConn.proxy + applyProxy）；单源空串 = 显式直连，压过全局
///   3. 全局代理开关：proxyDirective getter / proxyEnabled 与配置同步
///
/// resolveProxyDirective 为 @visibleForTesting 纯函数（clientForRequest 内部
/// 同款逻辑），测试直接断言返回值，无需真实 HttpClient/网络。
void main() {
  tearDown(() {
    NetConn.proxy = null;
    NetConn.applyProxy();
  });

  group('NetConn 代理指令格式', () {
    test('socks5 前缀 → SOCKS5 指令（含 socks5h 变体）', () {
      NetConn.proxy = 'socks5://127.0.0.1:1080';
      NetConn.applyProxy();
      expect(NetConn.proxyEnabled, isTrue);
      expect(NetConn.proxyDirective, 'SOCKS5 127.0.0.1:1080');

      NetConn.proxy = 'socks5h://proxy.example:1081';
      NetConn.applyProxy();
      expect(NetConn.proxyDirective, 'SOCKS5 proxy.example:1081');
    });

    test('socks4 前缀 → SOCKS4 指令', () {
      NetConn.proxy = 'socks4://10.0.0.1:4145';
      NetConn.applyProxy();
      expect(NetConn.proxyDirective, 'SOCKS4 10.0.0.1:4145');
    });

    test('裸 host:port 与 http/https 前缀 → PROXY 指令', () {
      NetConn.proxy = '192.168.1.1:8080';
      NetConn.applyProxy();
      expect(NetConn.proxyDirective, 'PROXY 192.168.1.1:8080');

      NetConn.proxy = 'http://proxy.example:3128';
      NetConn.applyProxy();
      expect(NetConn.proxyDirective, 'PROXY proxy.example:3128');

      // 不认识的 scheme 兜底为 PROXY（不是拒用）
      NetConn.proxy = 'weird://h:1';
      NetConn.applyProxy();
      expect(NetConn.proxyDirective, 'PROXY h:1');
    });

    test('null / 空串 / 空白 → 未启用代理（直连）', () {
      NetConn.proxy = null;
      NetConn.applyProxy();
      expect(NetConn.proxyEnabled, isFalse);
      expect(NetConn.proxyDirective, isNull);

      NetConn.proxy = '';
      NetConn.applyProxy();
      expect(NetConn.proxyEnabled, isFalse);

      NetConn.proxy = '   ';
      NetConn.applyProxy();
      expect(NetConn.proxyEnabled, isFalse);
    });
  });

  group('NetConn 代理优先级', () {
    test('单源代理 > 全局代理', () {
      NetConn.proxy = 'socks5://global:1080';
      NetConn.applyProxy();

      final directive =
          NetConn.resolveProxyDirective('http://per-source:3128');
      expect(directive, 'PROXY per-source:3128',
          reason: '单源代理参数应覆盖全局代理');
    });

    test('单源空串显式直连 > 全局代理（跳过代理直连）', () {
      NetConn.proxy = 'socks5://global:1080';
      NetConn.applyProxy();

      expect(NetConn.resolveProxyDirective(''), isNull,
          reason: 'proxy 为空串 = 显式直连，应压过全局代理返回 null');
    });

    test('单源为 null 时回退全局代理', () {
      NetConn.proxy = 'socks5://global:1080';
      NetConn.applyProxy();

      expect(NetConn.resolveProxyDirective(null), 'SOCKS5 global:1080',
          reason: '无单源代理时应使用全局代理');
    });
  });
}