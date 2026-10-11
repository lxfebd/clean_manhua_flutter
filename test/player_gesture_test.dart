import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/player_utils.dart';

void main() {
  group('seekTapSide 连点侧区判定', () {
    test('左 35% 内 → 1（回退）', () {
      expect(seekTapSide(10, 100), 1);
      expect(seekTapSide(34.9, 100), 1);
    });
    test('右 35% 外 → 2（快进）', () {
      expect(seekTapSide(65.1, 100), 2);
      expect(seekTapSide(99, 100), 2);
    });
    test('中间 30% → 0（播放/暂停）', () {
      expect(seekTapSide(35, 100), 0);
      expect(seekTapSide(50, 100), 0);
      expect(seekTapSide(65, 100), 0);
    });
  });

  group('tapSeekSeconds 连点累计幅度', () {
    test('第 1 次 10s, 之后每次 +10s, 上限 60s', () {
      expect(tapSeekSeconds(1), 10);
      expect(tapSeekSeconds(2), 20);
      expect(tapSeekSeconds(3), 30);
      expect(tapSeekSeconds(4), 40);
      expect(tapSeekSeconds(5), 50);
      expect(tapSeekSeconds(6), 60);
      expect(tapSeekSeconds(10), 60); // 封顶
    });
    test('streak<=0 也收敛到 10', () {
      expect(tapSeekSeconds(0), 10);
    });
  });

  group('horizontalSeekSpan 横滑可扫总时长', () {
    test('整屏宽 = 视频总时长 1/4', () {
      expect(horizontalSeekSpan(100), 25.0);
      expect(horizontalSeekSpan(40), 10.0);
    });
    test('上限 180 秒', () {
      expect(horizontalSeekSpan(1000), 180.0);
      expect(horizontalSeekSpan(720), 180.0);
    });
    test('短片时长不封顶', () {
      expect(horizontalSeekSpan(10), 2.5);
    });
  });

  group('horizontalSeekTarget 横滑 seek 目标', () {
    test('右滑推进', () {
      // 屏宽 1000, dur 100s → span 25s; dx=100 → deltaSec = 100/1000*25*2 = 5s
      final t = horizontalSeekTarget(
          from: const Duration(seconds: 30),
          dx: 100,
          width: 1000,
          dur: const Duration(seconds: 100));
      expect(t, const Duration(seconds: 35));
    });
    test('左滑回退', () {
      final t = horizontalSeekTarget(
          from: const Duration(seconds: 30),
          dx: -100,
          width: 1000,
          dur: const Duration(seconds: 100));
      expect(t, const Duration(seconds: 25));
    });
    test('clamp 下限 0', () {
      final t = horizontalSeekTarget(
          from: const Duration(seconds: 1),
          dx: -1000,
          width: 1000,
          dur: const Duration(seconds: 100));
      expect(t, Duration.zero);
    });
    test('clamp 上限 dur', () {
      final t = horizontalSeekTarget(
          from: const Duration(seconds: 99),
          dx: 1000,
          width: 1000,
          dur: const Duration(seconds: 100));
      expect(t, const Duration(seconds: 100));
    });
    test('毫秒取整', () {
      // dx=50/1000*25*2 = 2.5s → 2500ms
      final t = horizontalSeekTarget(
          from: const Duration(seconds: 30),
          dx: 50,
          width: 1000,
          dur: const Duration(seconds: 100));
      expect(t, const Duration(seconds: 32, milliseconds: 500));
    });
  });
}