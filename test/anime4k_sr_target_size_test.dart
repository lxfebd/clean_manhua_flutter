// 超分强制放大的尺寸计算回归测试。
//
// 覆盖 Anime4KManager.srTargetSize 的所有边界：
// * 640p 源 → 放大到 1280×720（x2 链激活的充分条件：OUTPUT.w > MAIN.w）
// * 720p 源 → 顶到 1920 长边
// * ≥2K 源 → 不放大（WHEN 本就满足，防 4K 纹理拖垮 GPU）
// * 无效尺寸 → null
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/utils/anime4k.dart';

void main() {
  group('Anime4KManager.srTargetSize 超分强制放大', () {
    test('640×360 源 → 1280×720（2x，等比）', () {
      final t = Anime4KManager.srTargetSize(sw: 640, sh: 360);
      expect(t, isNotNull);
      expect(t!.w, 1280);
      expect(t.h, 720);
    });

    test('1280×720 源 → 1920×1080（顶到 cap 上限）', () {
      final t = Anime4KManager.srTargetSize(sw: 1280, sh: 720);
      expect(t, isNotNull);
      expect(t!.w, 1920);
      expect(t.h, 1080);
    });

    test('1920×1080 源 → null（无需放大，x2 链本就满足）', () {
      expect(Anime4KManager.srTargetSize(sw: 1920, sh: 1080), isNull);
    });

    test('2560×1440 (2K) 源 → null（防 4K 纹理拖垮 GPU）', () {
      expect(Anime4KManager.srTargetSize(sw: 2560, sh: 1440), isNull);
    });

    test('非 16:9 源等比放大不拉伸（竖屏 360×640 → 720×1280）', () {
      final t = Anime4KManager.srTargetSize(sw: 360, sh: 640);
      expect(t, isNotNull);
      expect(t!.w, 720);
      expect(t.h, 1280);
    });

    test('无效尺寸（0/负数）→ null', () {
      expect(Anime4KManager.srTargetSize(sw: 0, sh: 360), isNull);
      expect(Anime4KManager.srTargetSize(sw: -1, sh: 360), isNull);
      expect(Anime4KManager.srTargetSize(sw: 640, sh: 0), isNull);
    });

    test('自定义 cap（如 1080）→ 720p 源顶到 1080 长边', () {
      final t = Anime4KManager.srTargetSize(sw: 960, sh: 540, cap: 1080);
      expect(t, isNotNull);
      expect(t!.w, 1080);
      expect(t.h, 608); // 540 × (1080/960) = 607.5 → round 608
    });
  });
}
