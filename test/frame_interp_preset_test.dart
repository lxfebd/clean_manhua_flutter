// 插帧（mpv interpolation）档位/属性的回归测试（纯静态，零 native）。
//
// 背景（2026-09-19）：
// 1) 倍速根因已定位为 display-resample 读 `estimated-display-fps` 垃圾值
//    （本机实测 4211~8922Hz），**不是** mpv interpolation 本身——探针四态
//    速率全 1.000x。因此插帧重接回播放器，但只允许在「显示时钟可靠且
//    有音轨」时以 display-resample-desync 生效（探测守护在 _applySync）。
// 2) propsFor 是 _applySync 唯一属性来源：off 必须显式还原默认值（幂等，
//    可反复调用），错误档位必须兜底 off——持久化里的旧值/脏值不能
//    把用户卡在未知档位。
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/utils/frame_interp.dart';

void main() {
  group('FrameInterpManager.levels / presetById（档位表）', () {
    test('三档：off / smooth / max，顺序即 UI 顺序', () {
      expect(FrameInterpManager.levels.map((e) => e.id).toList(),
          ['off', 'smooth', 'max']);
    });

    test('enabled 语义：off 关闭，其余开启', () {
      expect(FrameInterpManager.presetById('off').enabled, isFalse);
      expect(FrameInterpManager.presetById('smooth').enabled, isTrue);
      expect(FrameInterpManager.presetById('max').enabled, isTrue);
    });

    test('非法 id 兜底 off（脏持久化值不会卡死）', () {
      expect(FrameInterpManager.presetById('garbage').id, 'off');
      expect(FrameInterpManager.presetById('').id, 'off');
    });
  });

  group('FrameInterpManager.propsFor（mpv 属性集）', () {
    test('smooth：interpolation=yes + 研究定案阈值 0.85', () {
      final p = FrameInterpManager.propsFor('smooth');
      expect(p['interpolation'], 'yes');
      expect(p['interpolation-threshold'], '0.85');
    });

    test('max：阈值放宽到 0.99（低帧率源全补）', () {
      final p = FrameInterpManager.propsFor('max');
      expect(p['interpolation'], 'yes');
      expect(p['interpolation-threshold'], '0.99');
    });

    test('off：显式还原默认值（幂等，可反复调用）', () {
      final p = FrameInterpManager.propsFor('off');
      expect(p['interpolation'], 'no');
      expect(p['interpolation-threshold'], '0.85');
    });

    test('非法 id → off 属性集', () {
      final p = FrameInterpManager.propsFor('nope');
      expect(p['interpolation'], 'no');
    });
  });

  group('FrameInterpManager.fpsEligible（值不值得开）', () {
    test('24fps 源 @ 60Hz 屏 → 建议开（threshold 同源判据）', () {
      expect(FrameInterpManager.fpsEligible(videoFps: 24, dispFps: 60), isTrue);
      expect(FrameInterpManager.fpsEligible(videoFps: 23.976, dispFps: 60), isTrue);
    });

    test('60fps 源 @ 60Hz 屏 → 不开（ratio=1.0，threshold 本就跳过）', () {
      expect(FrameInterpManager.fpsEligible(videoFps: 60, dispFps: 60), isFalse);
    });

    test('阈值同源：45fps@60Hz 比 1.333，被 0.85 threshold 跳过 → 不开', () {
      // 60/1.85 ≈ 32.43：45 ≥ 32.43 → 不开（开了也不生效，别误导用户）。
      expect(FrameInterpManager.fpsEligible(videoFps: 45, dispFps: 60), isFalse);
    });

    test('0 / 负数 / 缺失 → 不开（不误伤、不除零）', () {
      expect(FrameInterpManager.fpsEligible(videoFps: 0, dispFps: 60), isFalse);
      expect(FrameInterpManager.fpsEligible(videoFps: 24, dispFps: 0), isFalse);
      expect(FrameInterpManager.fpsEligible(videoFps: -1, dispFps: 60), isFalse);
      expect(FrameInterpManager.fpsEligible(videoFps: 24, dispFps: -60), isFalse);
    });
  });

  group('FrameInterpManager.speedDrifted（倍速守卫）', () {
    test('speed=1.0 / 1.000001 → 不判变速（防数值抖动）', () {
      expect(FrameInterpManager.speedDrifted('1.0'), isFalse);
      expect(FrameInterpManager.speedDrifted('1.000001'), isFalse);
      expect(FrameInterpManager.speedDrifted('0.999999'), isFalse);
    });

    test('真实倍速（2.5x / 0.5x）→ 判变速', () {
      expect(FrameInterpManager.speedDrifted('2.5'), isTrue);
      expect(FrameInterpManager.speedDrifted('0.5'), isTrue);
      expect(FrameInterpManager.speedDrifted('1.1'), isTrue);
    });

    test('非法 / 缺失 → false（不误伤）', () {
      expect(FrameInterpManager.speedDrifted(null), isFalse);
      expect(FrameInterpManager.speedDrifted(''), isFalse);
      expect(FrameInterpManager.speedDrifted('abc'), isFalse);
      expect(FrameInterpManager.speedDrifted('ERR(property)'), isFalse);
    });

    test('自定义阈值生效', () {
      expect(FrameInterpManager.speedDrifted('1.05'), isTrue);
      expect(FrameInterpManager.speedDrifted('1.05', threshold: 0.1), isFalse);
    });
  });
}
