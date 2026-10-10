import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/net_conn.dart';

/// [NetConn.connectionTask] 优选 IP 直连的 socket 生命周期回归测试。
///
/// 背景：旧实现在 connectionFactory 闭包里逐个尝试候选 IP，TLS 握手失败
/// 时未释放已开的 raw socket（`opened?.destroy()` 缺失/被回退），每请求最多
/// 泄漏 ips.length 个 fd，移动端 fd 有限会累积到连接失败。修复已提交
/// （e78b5b0）。本测试用注入点（connectFn/secureFn）完全离线驱动失败分支，
/// 断言"每个失败的候选 IP socket 必须被 destroy"——若未来有人删掉
/// destroy，测试立即变红。
///
/// 注入点设计（lib/net/net_conn.dart）：
///   - connectFn/secureFn 为 @visibleForTesting 静态字段，默认即真实 dart:io
///   - connectionTask 为 @visibleForTesting 静态方法（原闭包体抽出的具名方法）
/// 生产路径不受影响（默认注入值就是真实实现）。
///
/// 测试 host 统一用 `localhost`：回退 DNS 走 hosts 文件即时解析、
/// 零真实网络，保证测试封闭且快速（不用 .invalid 域名——那会发真实
/// DNS 查询，离线环境会悬挂/超时）。
void main() {
  setUp(NetConn.resetConnectionOverrides);

  tearDown(() {
    NetConn.resetConnectionOverrides();
    NetConn.preferredHostIps.remove('localhost');
  });

  group('connectionTask 候选 IP 失败分支', () {
    test('全部候选 TLS 握手失败：每个已开 socket 都被 destroy（不泄漏）',
        () async {
      final opened = <_FakeSocket>[];

      NetConn.preferredHostIps['localhost'] = ['10.0.0.1', '10.0.0.2'];
      NetConn.connectFn = (host, port, timeout) async {
        final s = _FakeSocket();
        opened.add(s);
        return s;
      };
      NetConn.secureFn = (raw, host, onBad) async {
        throw const SocketException('TLS handshake failed', osError: null);
      };

      // 两个候选都失败 → 回退 DNS（localhost 即时解析）→ 回退 connect
      // 也失败。共开 3 个 socket，全部路径都必须销毁。
      await expectLater(
        NetConn.connectionTask(
          Uri.parse('https://localhost/path'),
          'localhost',
          null,
          null,
        ),
        throwsA(isA<SocketException>()),
      );

      expect(opened.length, 3,
          reason: '2 个候选 + 1 个回退连接，都应被尝试');
      for (final s in opened) {
        expect(s.destroyed, isTrue,
            reason: 'TLS 握手失败的 socket 必须 destroy，否则 fd 泄漏');
      }
    });

    test('候选 1 失败、候选 2 成功：只销毁失败的，成功的不销毁', () async {
      final opened = <_FakeSocket>[];
      var secureCalls = 0;

      NetConn.preferredHostIps['localhost'] = ['10.0.0.1', '10.0.0.2'];
      NetConn.connectFn = (host, port, timeout) async {
        final s = _FakeSocket();
        opened.add(s);
        return s;
      };
      NetConn.secureFn = (raw, host, onBad) async {
        secureCalls++;
        if (secureCalls == 1) {
          throw const SocketException('first IP down', osError: null);
        }
        return _FakeSecureSocket(raw);
      };

      final task = await NetConn.connectionTask(
        Uri.parse('https://localhost/path'),
        'localhost',
        null,
        null,
      );

      expect(secureCalls, 2, reason: '候选 1 失败后应尝试候选 2');
      expect(opened.length, 2, reason: '成功即返回，不应再走回退 DNS');
      expect(opened[0].destroyed, isTrue,
          reason: '失败的候选 1 socket 必须销毁');
      expect(opened[1].destroyed, isFalse,
          reason: '成功的候选 2 socket 必须保留（连接仍在使用）');

      // 让任务持有的 socket future 完成，避免悬空
      await task.socket;
    });

    test('无候选 IP（不在优选表）：走回退 DNS 直连路径', () async {
      final opened = <_FakeSocket>[];

      NetConn.connectFn = (host, port, timeout) async {
        final s = _FakeSocket();
        opened.add(s);
        return s;
      };
      NetConn.secureFn = (raw, host, onBad) async {
        throw const SocketException('still failing', osError: null);
      };

      await expectLater(
        NetConn.connectionTask(
          Uri.parse('https://localhost/path'),
          'localhost', // 本测试未注册 localhost 到优选表 → 直接回退
          null,
          null,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(opened.length, 1, reason: '无候选时仅回退连接一次');
      expect(opened.single.destroyed, isTrue,
          reason: '回退连接的 TLS 失败也必须销毁');
    });

    test('候选表为空列表：等同无候选，走回退直连', () async {
      NetConn.preferredHostIps['localhost'] = <String>[];
      NetConn.connectFn =
          (host, port, timeout) async => _FakeSocket(); // 仅回退时调用
      NetConn.secureFn =
          (raw, host, onBad) async => _FakeSecureSocket(raw); // 成功

      final task = await NetConn.connectionTask(
        Uri.parse('https://localhost/path'),
        'localhost',
        null,
        null,
      );
      expect(task, isNotNull);
      await task.socket;
    });
  });
}

/// 最小 Socket 实现：记录 destroy 调用，其余成员 noSuchMethod 兜底。
class _FakeSocket implements Socket {
  bool destroyed = false;

  @override
  void destroy() => destroyed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSecureSocket implements SecureSocket {
  final Socket raw;
  _FakeSecureSocket(this.raw);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}