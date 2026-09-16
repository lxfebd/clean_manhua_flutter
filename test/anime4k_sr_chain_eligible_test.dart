// 超分「生效判据」的回归测试（两个纯函数）。
//
// 背景（2026-09-14）：
// 1) shader 里的门闸是 mpv 表达式
//    `//!WHEN OUTPUT.w MAIN.w / 0.999 > OUTPUT.h MAIN.h / 0.999 > *`。
//    早期版本写的是 `1.000 >`，于是「渲染输出恰好等于源尺寸」时比值为精确的
//    1.0，`1.0 > 1.0` 为假 → 整条放大链被**静默跳过**（1080p 源铺满 1080p 屏、
//    或播放窗口与源等大，都属于这种情况），用户看到的就是「开了超分毫无变化」。
//    [Anime4KManager.srChainEligible] 必须和 shader 的这条表达式逐字等价。
// 2) 真机实测还发现：`glsl-shaders` 读回非空**不代表** pass 真的执行
//    （出现过读回两个路径、`vo-passes` 里 0 个用户着色器 pass 的静默失效）。
//    所以生效判据必须走 [Anime4KManager.userShaderPassCount]（读 vo-passes）。
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/utils/anime4k.dart';

void main() {
  bool eligible(int sw, int sh, int ow, int oh) =>
      Anime4KManager.srChainEligible(srcW: sw, srcH: sh, outW: ow, outH: oh);

  group('Anime4KManager.srChainEligible（x2 链执行条件）', () {
    test('阈值本身必须 < 1.0（严格大于比较的临界陷阱）', () {
      expect(Anime4KManager.upsampleWhenThreshold, lessThan(1.0));
      expect(Anime4KManager.upsampleWhenThreshold, greaterThan(0.9));
    });

    test('输出 == 源 → 成立（本次修复的核心场景）', () {
      // 1080p 源铺满 1080p 屏：比值精确为 1.0，旧阈值 1.000 时为假。
      expect(eligible(1920, 1080, 1920, 1080), isTrue);
      // 手机竖屏旋转后 1080x1920 也是同一回事。
      expect(eligible(1080, 1920, 1080, 1920), isTrue);
      // 小窗口与 640x360 源等大。
      expect(eligible(640, 360, 640, 360), isTrue);
    });

    test('输出 > 源 → 成立（真实放大）', () {
      expect(eligible(640, 360, 1280, 720), isTrue);
      expect(eligible(1280, 720, 1920, 1080), isTrue);
      expect(eligible(1920, 1080, 3840, 2160), isTrue);
    });

    test('输出 < 源 → 不成立（正在缩小播放，只有修复链）', () {
      expect(eligible(1920, 1080, 1230, 744), isFalse);
      expect(eligible(1920, 1080, 640, 360), isFalse);
      expect(eligible(1280, 720, 320, 180), isFalse);
    });

    test('严格大于：比值恰好等于阈值也不成立', () {
      // 1000 → 999：999/1000 == 0.999，`0.999 > 0.999` 为假。
      expect(eligible(1000, 1000, 999, 999), isFalse);
      // 刚刚越过阈值则成立。
      expect(eligible(1000, 1000, 1000, 1000), isTrue);
    });

    test('宽高需同时成立（任一方向在缩小就跳过）', () {
      expect(eligible(1920, 1080, 1920, 1080), isTrue);
      expect(eligible(1920, 1080, 1920, 800), isFalse); // 高在缩
      expect(eligible(1920, 1080, 1800, 1080), isFalse); // 宽在缩
    });

    test('尺寸缺失/非法 → 不成立（三态判定由调用方处理"未知"）', () {
      expect(eligible(0, 0, 1920, 1080), isFalse);
      expect(eligible(1920, 1080, 0, 0), isFalse);
      expect(eligible(-1, 1080, 1920, 1080), isFalse);
      expect(eligible(1920, 1080, -1920, -1080), isFalse);
    });
  });

  _passCountGroup();
}

// ---------------------------------------------------------------------------
// 追加：Anime4KManager.userShaderPassCount（vo-passes 判据）
// ---------------------------------------------------------------------------
void _passCountGroup() {
  group('Anime4KManager.userShaderPassCount（超分是否真的进渲染图）', () {
    // 取自真机实测的 vo-passes 片段（v3-E：Anime4K 确实跑起来的那次）。
    const realSample = '{"fresh":['
        '{"desc":"upload frame (naive)","last":18560,"avg":118296},'
        '{"desc":"user shader: Anime4K-v4.0-Restore-CNN-(M)-Conv-4x3x3x3 (rgb)"},'
        '{"desc":"user shader: Anime4K-v4.0-Restore-CNN-(M)-Conv-3x1x1x56 (rgb)"},'
        '{"desc":"user shader: Anime4K-v3.2-Upscale-CNN-x2-(M)-Conv-4x3x3x3 (rgb)"},'
        '{"desc":"user shader: Anime4K-v3.2-Upscale-CNN-x2-(M)-Depth-to-Space (rgb)"},'
        '{"desc":"dscale=bilinear (rgb) + output to screen"}'
        ']}';

    test('数出真实的用户着色器 pass 数', () {
      expect(Anime4KManager.userShaderPassCount(realSample), 4);
    });

    test('没有任何用户着色器 pass → 0（"设上了但没生效"的典型形态）', () {
      const none = '{"fresh":[{"desc":"upload frame (naive)"},'
          '{"desc":"merging planes"},'
          '{"desc":"scale=bilinear (rgb) + output to screen"}]}';
      expect(Anime4KManager.userShaderPassCount(none), 0);
    });

    test('读不到属性（空串 / ERR）→ 0，不抛异常', () {
      expect(Anime4KManager.userShaderPassCount(''), 0);
      expect(Anime4KManager.userShaderPassCount('ERR(property not found)'), 0);
    });

    test('不绑死 Anime4K 名字：其它用户着色器同样计入', () {
      const other =
          '{"fresh":[{"desc":"user shader: FSRCNNX-8-0-4-1 (rgb)"}]}';
      expect(Anime4KManager.userShaderPassCount(other), 1);
    });
  });
}
