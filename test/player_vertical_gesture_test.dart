import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/player_utils.dart';

void main() {
  group('verticalGestureDelta 竖滑归一化位移', () {
    test('上滑（负 primaryDelta）→ 正值增量', () {
      // refH = 屏幕高 * 0.7 = 700*0.7 = 490; dx=-70 → delta = 70/490 ≈ 0.1429
      expect(verticalGestureDelta(-70, 700), closeTo(0.1429, 1e-3));
    });
    test('下滑（正 primaryDelta）→ 负值增量', () {
      expect(verticalGestureDelta(70, 700), closeTo(-0.1429, 1e-3));
    });
    test('refH 随屏幕高度缩放', () {
      // refH = 350*0.7 = 245; dx=-35 → 35/245 ≈ 0.1429
      expect(verticalGestureDelta(-35, 350), closeTo(0.1429, 1e-3));
    });
    test('零位移 → 0', () {
      expect(verticalGestureDelta(0, 700), 0.0);
    });
  });

  group('verticalGestureValue 竖滑目标值', () {
    test('亮度：clamp [lo, 1.0]', () {
      // start + delta: 0.5 + 0.2 = 0.7
      expect(verticalGestureValue(0.5, 0.2, 0.12), closeTo(0.7, 1e-9));
      expect(verticalGestureValue(-0.5, 0.2, 0.12), 0.12); // 下限 lo
      expect(verticalGestureValue(1.5, 0.2, 0.12), 1.0); // 上限 1
    });
    test('音量：clamp [0, 1.0]', () {
      expect(verticalGestureValue(0.5, 0.0, 0.0), closeTo(0.5, 1e-9));
      expect(verticalGestureValue(-0.5, 0.0, 0.0), 0.0); // 下限 0
      expect(verticalGestureValue(1.5, 0.0, 0.0), 1.0); // 上限 1
    });
    test('亮度 lo 下限生效', () {
      expect(verticalGestureValue(-0.1, 0.12, 0.12), 0.12);
    });
  });
}