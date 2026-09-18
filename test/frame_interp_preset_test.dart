import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/utils/frame_interp.dart';

void main() {
  group('FrameInterpManager.propsFor 档位 → mpv 属性', () {
    test('smooth：interpolation=yes + threshold 0.85 + tscale oversample', () {
      final p = FrameInterpManager.propsFor('smooth');
      expect(p['interpolation'], 'yes');
      expect(p['interpolation-threshold'], '0.85');
      expect(p['tscale'], 'oversample');
    });

    test('max：更低阈值 0.99（更激进）', () {
      final p = FrameInterpManager.propsFor('max');
      expect(p['interpolation'], 'yes');
      expect(p['interpolation-threshold'], '0.99');
      expect(p['tscale'], 'oversample');
    });

    test('off：显式还原 interpolation=no，且不残留 threshold/tscale', () {
      final p = FrameInterpManager.propsFor('off');
      expect(p, {'interpolation': 'no'});
    });

    test('非法 id 兜底 off（不抛出、不返回空）', () {
      final p = FrameInterpManager.propsFor('bogus');
      expect(p, {'interpolation': 'no'});
    });
  });

  group('FrameInterpManager.presetById', () {
    test('合法值返回对应档位', () {
      expect(FrameInterpManager.presetById('smooth').id, 'smooth');
      expect(FrameInterpManager.presetById('off').enabled, isFalse);
      expect(FrameInterpManager.presetById('max').enabled, isTrue);
    });

    test('非法值兜底 off', () {
      expect(FrameInterpManager.presetById('nope').id, 'off');
    });

    test('enabled 语义：off=false，其余 true', () {
      expect(FrameInterpManager.levels.where((e) => e.enabled).length, 2);
    });
  });

  group('FrameInterpManager.adviceFor 开帧收益判据', () {
    test('24fps @ 60Hz（ratio 0.4）→ 推荐', () {
      expect(
        FrameInterpManager.adviceFor(videoFps: 24, dispFps: 60),
        InterpAdvice.recommend,
      );
    });

    test('48fps @ 60Hz（ratio 0.8）→ 中性', () {
      expect(
        FrameInterpManager.adviceFor(videoFps: 48, dispFps: 60),
        InterpAdvice.neutral,
      );
    });

    test('60fps @ 60Hz（ratio 1.0）→ 无收益', () {
      expect(
        FrameInterpManager.adviceFor(videoFps: 60, dispFps: 60),
        InterpAdvice.noBenefit,
      );
    });

    test('120fps 源 → 无收益', () {
      expect(
        FrameInterpManager.adviceFor(videoFps: 120, dispFps: 60),
        InterpAdvice.noBenefit,
      );
    });

    test('非法输入（0/负数）防除零 → 中性', () {
      expect(
        FrameInterpManager.adviceFor(videoFps: 0, dispFps: 60),
        InterpAdvice.neutral,
      );
      expect(
        FrameInterpManager.adviceFor(videoFps: 24, dispFps: 0),
        InterpAdvice.neutral,
      );
      expect(
        FrameInterpManager.adviceFor(videoFps: -1, dispFps: 60),
        InterpAdvice.neutral,
      );
    });
  });
}
