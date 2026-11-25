import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/source_health_monitor.dart';

/// 源健康「解析探测」字段的合并语义回归。
///
/// 背景：传输探测（DNS/TCP/TLS）发现不了「服务器在、但页面结构改了导致
/// 解析不出内容」这一类静默失效，所以监控器新增 parseOk/parseError/
/// parseCheckedAt 三个字段 + 每 2 小时一次的真实列表探测。
///
/// 这里只测纯内存的合并语义（不探网、不碰 IO），
/// 用 [SourceHealthMonitor.debugRecord] / [debugApplyParse] 两个
/// @visibleForTesting 入口驱动：
/// 1. 没探过解析的源 parseOk 默认 true —— 不误报；
/// 2. 传输失败那一轮不许把已知的「解析失败」擦回 true（默认值陷阱）；
/// 3. applyParse 只改解析三字段，传输层评分/延迟/成功率不动——
///    「慢」和「读不懂」是两种失效，不让前者洗白后者。
void main() {
  final mon = SourceHealthMonitor.instance;

  group('源健康 parseOk 合成', () {
    test('未探过解析的源：parseOk 默认 true，不误报', () {
      mon.debugRecord('probe-default', '默认源',
          const HostProbeResult('h', true, 120, null));
      final h = mon.healthOf('probe-default')!;
      expect(h.parseOk, true);
      expect(h.parseError, isNull);
      expect(h.parseCheckedAt, 0);
    });

    test('传输失败轮不得擦掉已知的解析失败（默认值陷阱）', () {
      // 第一次：传输通 + 解析失败
      mon.debugRecord('probe-keep', '源A',
          const HostProbeResult('h', true, 150, null));
      mon.debugApplyParse('probe-keep', ok: false, error: '榜单解析为空');
      expect(mon.healthOf('probe-keep')!.parseOk, false);

      // 关键回归点：下一轮传输探测失败了（走到 _record 的分支），
      // SourceHealth 里 parseOk 若写成 `this.parseOk = true` 这种默认值，
      // 这里就会被重新洗成 true，UI 上的红点/解析失败提示会闪掉。
      mon.debugRecord('probe-keep', '源A',
          const HostProbeResult('h', false, -1, 'timeout'));
      final h = mon.healthOf('probe-keep')!;
      expect(h.parseOk, false, reason: '传输失败不该擦掉解析失败');
      expect(h.parseError, '榜单解析为空');
    });

    test('applyParse 只改解析三字段，传输层评分原样保留', () {
      mon.debugRecord('probe-merge', '源B',
          const HostProbeResult('h', true, 300, null));
      final before = mon.healthOf('probe-merge')!;
      mon.debugApplyParse('probe-merge', ok: false, error: '分类解析为空');
      final after = mon.healthOf('probe-merge')!;

      // 传输层四个字段必须逐字节不变
      expect(after.score, before.score);
      expect(after.reachable, before.reachable);
      expect(after.latencyMs, before.latencyMs);
      expect(after.successRate, before.successRate);
      expect(after.error, before.error);
      expect(after.checkedAt, before.checkedAt);

      // 解析字段换成新结论
      expect(after.parseOk, false);
      expect(after.parseError, '分类解析为空');
      expect(after.parseCheckedAt, greaterThan(0));
    });

    test('解析恢复后 parseOk 回到 true 且清空错误', () {
      mon.debugRecord('probe-recover', '源C',
          const HostProbeResult('h', true, 200, null));
      mon.debugApplyParse('probe-recover', ok: false, error: 'Error');
      mon.debugApplyParse('probe-recover', ok: true);
      final h = mon.healthOf('probe-recover')!;
      expect(h.parseOk, true);
      expect(h.parseError, isNull);
      expect(h.parseCheckedAt, greaterThan(0));
    });
  });
}