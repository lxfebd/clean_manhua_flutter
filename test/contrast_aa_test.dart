import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/theme.dart';

/// P1-16 对比度回归：三处「写死白色/低 alpha」的语义色修正 + 计算级断言。
///
/// 背景（2026-11-22 审查）：深色主题的 primary 是浅色一档，源卡图标却写死
/// `Colors.white`，实测对比度只有 **1.10:1**；底栏未选中项 alpha 0.40（亮）/0.45
/// （暗）在亮色底上 2.53:1；输入提示 alpha 0.38 只有 2.36:1——都低于 WCAG AA。
/// 现分别改为 `scheme.onPrimary` 与经明暗验证的 `TextTier.low` 档。
void main() {
  double lum(Color c) {
    double chan(double s) =>
        s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
    return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0724 * chan(c.b);
  }

  double contrast(Color fg, Color bg) {
    final a = fg.a;
    final blended = Color.fromARGB(
        255,
        ((fg.r * a + bg.r * (1 - a)) * 255).round(),
        ((fg.g * a + bg.g * (1 - a)) * 255).round(),
        ((fg.b * a + bg.b * (1 - a)) * 255).round());
    final l1 = lum(blended);
    final l2 = lum(bg);
    final hi = math.max(l1, l2);
    final lo = math.min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
  }

  group('计算级断言（真实主题取色）', () {
    for (final entry in {
      '亮色': AppTheme.light(),
      '暗色': AppTheme.dark(),
    }.entries) {
      test('${entry.key}：输入提示文字对比度 ≥ 4.5:1', () {
        final t = entry.value;
        final hint = t.inputDecorationTheme.hintStyle?.color;
        final fill = t.inputDecorationTheme.fillColor;
        expect(hint, isNotNull, reason: 'hintStyle 必须定义');
        expect(fill, isNotNull, reason: 'fillColor 必须定义');
        final c = contrast(hint!, fill!);
        expect(c, greaterThanOrEqualTo(4.5),
            reason: 'hint=$hint on fill=$fill → ${c.toStringAsFixed(2)}:1');
      });

      test('${entry.key}：源卡图标前景（onPrimary）≥ 3:1', () {
        final scheme = entry.value.colorScheme;
        final c = contrast(scheme.onPrimary, scheme.primary);
        expect(c, greaterThanOrEqualTo(3.0),
            reason:
                'onPrimary=${scheme.onPrimary} on primary=${scheme.primary} '
                '→ ${c.toStringAsFixed(2)}:1');
      });
    }
  });

  group('源码棘轮（防止再退化）', () {
    String read(String p) => File(p).readAsStringSync();

    test('源卡图标不再写死 Colors.white', () {
      final text = read('lib/ui/source_manage_widgets.dart');
      expect(text.contains('scheme.onPrimary'), isTrue,
          reason: 'primary 上的前景色必须用 onPrimary 语义槽');
      // 该文件里不应再出现「图标色 = 写死白色」的写法。
      expect(RegExp(r'color:\s*Colors\.white').hasMatch(text), isFalse,
          reason: '深色主题 primary 是浅色，白图标对比度仅 1.10:1');
    });

    test('底栏未选中色不再用裸 alpha 0.40/0.45', () {
      final text = read('lib/ui/main_shell_widgets.dart');
      expect(text.contains('alpha: isDark ? 0.45 : 0.4'), isFalse,
          reason: '已改用 TextTier.low');
      expect(text.contains('TextTier.low'), isTrue);
    });

    test('提示文字不再用裸 alpha 0.38', () {
      final text = read('lib/theme.dart');
      expect(text.contains('hintStyle: TextStyle(color: text.withValues(alpha: 0.38))'),
          isFalse,
          reason: '已改用 TextTier.low');
    });
  });
}
