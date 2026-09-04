import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/tokens.dart';

/// 设计 token 门禁（8-31 重设计划·阶段 1）。
///
/// 两类闸门：
/// 1. **可达性**：[T] 的各文字档在两套主题底板上必须达 WCAG AA；
/// 2. **棘轮**：全 lib 的 fontSize / circular / alpha 字面量种类数
///    不得超过当前基线（只减不增），阶段 2 逐页迁移后应下调基线。
void main() {
  // ── WCAG 相对亮度 / 对比度 ────────────────────────────────────────────
  double lum(Color c) {
    // Color.r/g/b 本身即 0..1 double，直接进 sRGB 线性化。
    double chan(double s) =>
        s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;

    return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b);
  }

  double contrast(Color fg, Color bg) {
    // 半透明前景按合成到不透明底板后计算。
    // 注意 Color.r/g/b 是 0..1 double，喂 fromARGB 前须 ×255。
    final a = fg.a;
    final blended = Color.fromARGB(
      255,
      ((fg.r * a + bg.r * (1 - a)) * 255).round(),
      ((fg.g * a + bg.g * (1 - a)) * 255).round(),
      ((fg.b * a + bg.b * (1 - a)) * 255).round(),
    );
    final l1 = lum(blended);
    final l2 = lum(bg);
    final hi = l1 > l2 ? l1 : l2;
    final lo = l1 > l2 ? l2 : l1;
    return (hi + 0.05) / (lo + 0.05);
  }

  const lightText = Color(0xFF18181B); // 亮色主题文字基色（墨）
  const lightBg = Color(0xFFFAFAFA); // 亮色主题底板
  const darkText = Color(0xFFF4F4F5); // 暗色主题文字基色
  const darkBg = Color(0xFF0C0C0E); // 暗色主题底板

  group('T 透明度阶 WCAG 门禁', () {
    const bodyTiers = [TextTier.high, TextTier.mid, TextTier.low];
    for (final tier in bodyTiers) {
      test('$tier 亮色主题对比度 ≥ 4.5（AA 正文）', () {
        final c = contrast(
            T.color(lightText, tier, brightness: Brightness.light), lightBg);
        expect(c, greaterThanOrEqualTo(4.5),
            reason: '${tier.name} 亮色 alpha='
                '${T.alphaFor(tier, Brightness.light)} 实测对比度 $c');
      });
      test('$tier 暗色主题对比度 ≥ 4.5（AA 正文）', () {
        final c = contrast(
            T.color(darkText, tier, brightness: Brightness.dark), darkBg);
        expect(c, greaterThanOrEqualTo(4.5),
            reason: '${tier.name} 暗色 alpha='
                '${T.alphaFor(tier, Brightness.dark)} 实测对比度 $c');
      });
    }
    test('档位单调：high > mid > low > disabled', () {
      for (final b in Brightness.values) {
        expect(T.alphaFor(TextTier.high, b),
            greaterThan(T.alphaFor(TextTier.mid, b)));
        expect(T.alphaFor(TextTier.mid, b),
            greaterThan(T.alphaFor(TextTier.low, b)));
        expect(T.alphaFor(TextTier.low, b),
            greaterThan(T.alphaFor(TextTier.disabled, b)));
      }
    });
  });

  group('S/R/TypeScale 档位', () {
    test('间距 6 档、圆角 5 档、字号 6 档且递增', () {
      expect(const [S.x4, S.x8, S.x12, S.x16, S.x24, S.x32],
          orderedEquals(const [4, 8, 12, 16, 24, 32]));
      expect(R.pill, 999);
      const sizes = [
        TypeScale.micro,
        TypeScale.meta,
        TypeScale.body,
        TypeScale.section,
        TypeScale.title,
        TypeScale.display,
      ];
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], greaterThan(sizes[i - 1]));
      }
    });
  });

  group('字面量棘轮（只减不增）', () {
    /// 扫全 lib（tokens.dart 是 token 定义本体，豁免）。
    List<String> distinctLiterals(
      String pattern, {
      List<String> exclude = const [],
    }) {
      final re = RegExp(pattern);
      final found = <String>{};
      for (final f
          in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final norm = f.path.replaceAll(r'\', '/');
        if (exclude.any(norm.endsWith)) continue;
        for (final m in re.allMatches(f.readAsStringSync())) {
          found.add(m.group(1)!);
        }
      }
      return found.toList()..sort();
    }

    const excluded = ['ui/tokens.dart'];

    test('fontSize 字面量种类数 ≤ 24（基线 2026-09-03 工具箱页迁移后）', () {
      final v = distinctLiterals(r'fontSize:\s*([\d.]+)', exclude: excluded);
      expect(v.length, lessThanOrEqualTo(24),
          reason: '发现 ${v.length} 种 fontSize 字面量：$v\n'
              '新代码请用 Theme.of(context).textTheme（见 TypeScale）；'
              '迁移后请下调本基线数字。');
    });

    test('BorderRadius.circular 字面量种类数 ≤ 22（基线 2026-09-04 阶段2 迁移后）', () {
      final v = distinctLiterals(r'BorderRadius\.circular\(\s*([\d.]+)',
          exclude: excluded);
      expect(v.length, lessThanOrEqualTo(22),
          reason: '发现 ${v.length} 种 circular() 半径：$v，'
              '新代码请用 R.control/card/hero/sheet/pill；迁移后下调基线。');
    });

    test('alpha: 字面量种类数 ≤ 40（基线 2026-09-04 阶段2 迁移后）', () {
      final v = distinctLiterals(r'alpha:\s*([\d.]+)', exclude: excluded);
      expect(v.length, lessThanOrEqualTo(40),
          reason: '发现 ${v.length} 种 alpha 字面量：$v，'
              '新代码请用 T.color(base, TextTier.x, brightness)；迁移后下调基线。');
    });
  });

  group('TypeScale 手机/平板分档（阶段2 修复：手机端不再被桌面档连带放大）', () {
    // 手机档（<600dp 逻辑宽）保留设计稿原字号，平板/桌面档用 22/17/15/14/12/11。
    // 直接断言纯函数 TypeScale.textTheme 的槽位字号（isTablet 由 AppTheme 透传）。
    double slotFont(String slot, {required bool isTablet}) {
      final t = TypeScale.textTheme(lightText, isTablet: isTablet);
      return switch (slot) {
        'displaySmall' => t.displaySmall!.fontSize!,
        'titleLarge' => t.titleLarge!.fontSize!,
        'titleMedium' => t.titleMedium!.fontSize!,
        'bodyMedium' => t.bodyMedium!.fontSize!,
        'bodySmall' => t.bodySmall!.fontSize!,
        'labelSmall' => t.labelSmall!.fontSize!,
        _ => -1,
      };
    }

    test('手机档（<600dp）：display=19 / title=17 / micro=9，保留设计稿原字号', () {
      expect(slotFont('displaySmall', isTablet: false), 19); // 三格大数字
      expect(slotFont('titleLarge', isTablet: false), 17); // 16.5 取整
      expect(slotFont('labelSmall', isTablet: false), 9); // 徽章 8/8.5/9 收敛
    });

    test('平板/桌面档（≥600dp）：display=22 / title=17 / micro=11，走桌面档', () {
      expect(slotFont('displaySmall', isTablet: true), 22);
      expect(slotFont('titleLarge', isTablet: true), 17);
      expect(slotFont('labelSmall', isTablet: true), 11);
    });

    test('手机档三格数字档位完整：section=14 / body=14 / meta=12', () {
      expect(slotFont('titleMedium', isTablet: false), 14); // 13.5 取整
      expect(slotFont('bodyMedium', isTablet: false), 14);
      expect(slotFont('bodySmall', isTablet: false), 12); // 11.5 取整
    });
  });
}
