import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/player_sync_guard.dart';

void main() {
  group('wrateIsDrifted', () {
    test('正常速率 1.0 不判漂移', () {
      expect(wrateIsDrifted(1.0), isFalse);
      expect(wrateIsDrifted(1.0, speed: 1.0), isFalse);
    });

    test('略快于 1.0（1.05）在容差内不判漂移', () {
      expect(wrateIsDrifted(1.05), isFalse);
    });

    test('明显倍速 1.2 判漂移', () {
      expect(wrateIsDrifted(1.2), isTrue);
    });

    test('用户主动调速 speed>1.05 时不判漂移（即使 wrate 很大）', () {
      expect(wrateIsDrifted(2.0, speed: 2.0), isFalse);
      expect(wrateIsDrifted(1.5, speed: 1.5), isFalse);
    });

    test('暂停/缓冲中 wrate≈0 不判漂移（减速不是倍速）', () {
      expect(wrateIsDrifted(0.05, paused: true), isFalse);
      expect(wrateIsDrifted(0.05, buffering: true), isFalse);
    });

    test('自定义容差生效', () {
      expect(wrateIsDrifted(1.20, tolerance: 0.25), isFalse);
      expect(wrateIsDrifted(1.30, tolerance: 0.25), isTrue);
    });

    test('边界值 1.15 等于阈值不判漂移（严格大于）', () {
      expect(wrateIsDrifted(1.15), isFalse);
      expect(wrateIsDrifted(1.1501), isTrue);
    });
  });

  group('accumulateDrift', () {
    test('连续漂移累加到 required 后钳住', () {
      var hits = 0;
      hits = accumulateDrift(hits, true, required: 3);
      expect(hits, 1);
      hits = accumulateDrift(hits, true, required: 3);
      expect(hits, 2);
      hits = accumulateDrift(hits, true, required: 3);
      expect(hits, 3); // 钳住
      hits = accumulateDrift(hits, true, required: 3);
      expect(hits, 3);
    });

    test('中间一拍正常就清零（必须连续）', () {
      var hits = 0;
      hits = accumulateDrift(hits, true, required: 3);
      hits = accumulateDrift(hits, false, required: 3);
      expect(hits, 0);
    });

    test('从未漂移保持 0', () {
      expect(accumulateDrift(0, false, required: 3), 0);
    });
  });

  group('wrateRecovered', () {
    test('回到 0.9~1.1 区间算恢复', () {
      expect(wrateRecovered(1.0), isTrue);
      expect(wrateRecovered(0.95), isTrue);
      expect(wrateRecovered(1.08), isTrue);
    });

    test('区间外不算恢复', () {
      expect(wrateRecovered(1.2), isFalse);
      expect(wrateRecovered(0.8), isFalse);
      expect(wrateRecovered(2.0), isFalse);
    });
  });
}