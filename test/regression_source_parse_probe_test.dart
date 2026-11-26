import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/source_health_monitor.dart';

/// 源健康「解析探测」字段的合并语义回归。
///
/// 传输探测（DNS/TCP+TLS）发现不了「服务器在、但页面结构改了导致解析不出
/// 内容」这一类静默失效，所以监控器新增 parseOk / parseError /
/// parseCheckedAt，并对传输可达的源每 2 小时发一次真实列表请求。
///
/// 结论分三态（ParseOutcome）：
///   ok          -> 解析出 >=1 条
///   drift       -> 取到了、也解析成功，但 0 条 = 契约变更（唯一可证明的失败）
///   unreachable -> 403/超时/非 JSON（反爬 HTML 挑战页同样让 jsonDecode 抛
///                  FormatException，证据不足，不报故障）
/// parseOk 只在 drift 为 false；unreachable 交给传输层评分，不落红。
///
/// 只测纯内存合并语义（不探网、不碰 IO），经 debugRecord / debugApplyParse
/// 两个 @visibleForTesting 入口驱动。
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
      mon.debugRecord('probe-keep', '源A',
          const HostProbeResult('h', true, 150, null));
      mon.debugApplyParse('probe-keep',
          outcome: ParseOutcome.drift, error: '榜单解析为空');
      expect(mon.healthOf('probe-keep')!.parseOk, false);

      // 下一轮传输探测失败（走到 _record 分支）：parseOk 若写成
      // `this.parseOk = true` 这种默认值，这里就会被洗回 true，
      // UI 上的解析失败提示会闪掉。
      mon.debugRecord('probe-keep', '源A',
          const HostProbeResult('h', false, -1, 'timeout'));
      final h = mon.healthOf('probe-keep')!;
      expect(h.parseOk, false, reason: '传输失败不该擦掉解析失败');
      expect(h.parseError, '榜单解析为空');
    });

    test('applyParse 只改解析字段，传输层评分原样保留', () {
      mon.debugRecord('probe-merge', '源B',
          const HostProbeResult('h', true, 300, null));
      final before = mon.healthOf('probe-merge')!;
      mon.debugApplyParse('probe-merge',
          outcome: ParseOutcome.drift, error: '分类解析为空');
      final after = mon.healthOf('probe-merge')!;

      expect(after.score, before.score);
      expect(after.reachable, before.reachable);
      expect(after.latencyMs, before.latencyMs);
      expect(after.successRate, before.successRate);
      expect(after.error, before.error);
      expect(after.checkedAt, before.checkedAt);

      expect(after.parseOk, false);
      expect(after.parseError, '分类解析为空');
      expect(after.parseCheckedAt, greaterThan(0));
    });

    test('unreachable 不触发 parseOk=false——不拿环境噪声报故障', () {
      // CI runner 上 MangaDex/AGE/风车 全落在这一类（403 / HTML 挑战页），
      // 若也落红，源管理页会天天亮红灯。
      mon.debugRecord('probe-unreach', '源C',
          const HostProbeResult('h', true, 200, null));
      mon.debugApplyParse('probe-unreach',
          outcome: ParseOutcome.unreachable, error: 'HTTP 403');
      final h = mon.healthOf('probe-unreach')!;
      expect(h.parseOk, true, reason: 'unreachable 不构成契约变更证据');
      expect(h.parseCheckedAt, greaterThan(0));
    });

    test('解析恢复后 parseOk 回到 true 且清空错误', () {
      mon.debugRecord('probe-recover', '源D',
          const HostProbeResult('h', true, 200, null));
      mon.debugApplyParse('probe-recover',
          outcome: ParseOutcome.drift, error: 'Error');
      mon.debugApplyParse('probe-recover', outcome: ParseOutcome.ok);
      final h = mon.healthOf('probe-recover')!;
      expect(h.parseOk, true);
      expect(h.parseError, isNull);
      expect(h.parseCheckedAt, greaterThan(0));
    });
  });
}
