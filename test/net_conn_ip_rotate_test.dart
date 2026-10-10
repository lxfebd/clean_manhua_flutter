import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/net_conn.dart';

/// [NetConn] 优选 IP 轮换语义回归测试。
///
/// 锁住 `rotateIpIndex` 的三条契约（均为纯下标算术，无网络）：
///   1. 未知域名 / 不在 preferredHostIps 的域名 → 返回 0 且不污染下标表
///   2. 已注册域名 → 返回"上次位置 +1"（即下一个应尝试的下标），取模成环
///   3. 连续调用形成完整环，遍历完一轮回到起点
///
/// `_ipIndex` 为私有静态（有状态），故本文件只驱动公开入口
/// [NetConn.rotateIpIndex] 并用"整轮回到起点"反证环长，不直接读内部状态。
///
/// 说明：平台侧在收到 5xx/429 后调用本方法切换候选 IP——若它恒返回同一
/// 下标（或恒返回 0），所有重试都会打在同一个已失败 IP 上，优选 IP 加速
/// 形同虚设且无法自愈。这是纯算术逻辑，无须真实网络即可完整验证。
void main() {
  // 用测试专用域名，避免与生产 preferredHostIps 里的条目（轮换状态是
  // 进程级静态）互相干扰。
  const host = 'rotate-test.invalid';

  setUp(() {
    NetConn.preferredHostIps[host] = ['10.0.0.1', '10.0.0.2', '10.0.0.3'];
  });

  tearDown(() {
    NetConn.preferredHostIps.remove(host);
  });

  group('NetConn.rotateIpIndex 优选 IP 轮换', () {
    test('不在优选表中的域名：返回 0，且不进入轮换状态', () {
      expect(NetConn.rotateIpIndex('not-in-table.invalid'), 0);
      // 再调一次仍是 0——未注册域名不得被建立轮换状态
      // （_ipIndex 私有，无法直接读；此处以"重复调用结果不变"间接反证）
      expect(NetConn.rotateIpIndex('not-in-table.invalid'), 0);
    });

    test('已注册域名：逐次 +1 轮换，覆盖全部候选后回到起点', () {
      // 语义为"返回下一个应尝试的下标"：首次调用时无历史记录（cur=0），
      // 故返回 (0+1)%3 = 1，而非 0——0 号 IP 是首次请求已试过的那次。
      expect(NetConn.rotateIpIndex(host), 1);
      expect(NetConn.rotateIpIndex(host), 2);
      expect(NetConn.rotateIpIndex(host), 0);
      // 环长 3：第 4 次回到 1（取模），否则会越界到无效下标
      expect(NetConn.rotateIpIndex(host), 1);
      expect(NetConn.rotateIpIndex(host), 2);
    });

    test('候选数为 1 时恒返回 0（单 IP 不轮换）', () {
      const single = 'rotate-single.invalid';
      NetConn.preferredHostIps[single] = ['10.0.0.9'];
      addTearDown(() => NetConn.preferredHostIps.remove(single));

      expect(NetConn.rotateIpIndex(single), 0);
      expect(NetConn.rotateIpIndex(single), 0);
    });

    test('候选表为空列表：返回 0，不做除零', () {
      const empty = 'rotate-empty.invalid';
      NetConn.preferredHostIps[empty] = <String>[];
      addTearDown(() => NetConn.preferredHostIps.remove(empty));

      expect(NetConn.rotateIpIndex(empty), 0);
    });
  });
}