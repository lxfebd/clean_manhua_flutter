import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/style_scope.dart';
import 'package:xingmanxia/ui/style_tokens.dart';
import 'package:xingmanxia/ui/tokens.dart';

/// UI 风格轴门禁（2026-09-30 三风格改造 S4）。
///
/// 三类闸门：
/// 1. **解析**：[UIStyle] 的持久化解析 / 平台默认映射；
/// 2. **Scope**：[StyleScope] 挂载后 `context.uiStyle` 读到正确风格、
///    未挂载回退极简；
/// 3. **Token 三风格档位**：[StyleTokens] 与 [R.of] 在极简下与静态档位
///    逐字节一致（回归面为零），小米/苹果有独立档位。
void main() {
  group('UIStyle 解析', () {
    test('id/name 一致，label 可读', () {
      for (final s in UIStyle.values) {
        expect(s.id, s.name);
        expect(s.label, isNotEmpty);
      }
    });

    test('fromId 正常解析 + 非法回退极简', () {
      expect(UIStyle.fromId('minimalist'), UIStyle.minimalist);
      expect(UIStyle.fromId('xiaomi'), UIStyle.xiaomi);
      expect(UIStyle.fromId('apple'), UIStyle.apple);
      expect(UIStyle.fromId(null), UIStyle.minimalist);
      expect(UIStyle.fromId(''), UIStyle.minimalist);
      expect(UIStyle.fromId('banana'), UIStyle.minimalist);
    });

    test('平台默认映射：Android→小米 / iOS→苹果 / 桌面与 Web→极简', () {
      expect(UIStyle.forPlatform(TargetPlatform.android), UIStyle.xiaomi);
      expect(UIStyle.forPlatform(TargetPlatform.iOS), UIStyle.apple);
      for (final p in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(UIStyle.forPlatform(p), UIStyle.minimalist,
            reason: '$p 应回退极简（桌面回归面最小）');
      }
    });
  });

  group('StyleScope 挂载', () {
    testWidgets('未挂载时 context.uiStyle 回退极简', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: _StyleProbe())),
      );
      expect(_readStyle(tester), UIStyle.minimalist);
    });

    testWidgets('StyleScope.demo 固定风格可读', (tester) async {
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.xiaomi,
          child: const MaterialApp(home: Scaffold(body: _StyleProbe())),
        ),
      );
      expect(_readStyle(tester), UIStyle.xiaomi);
    });

    testWidgets('三风格依次挂载均可读', (tester) async {
      for (final s in UIStyle.values) {
        await tester.pumpWidget(
          StyleScope(
            style: s,
            child: const MaterialApp(home: Scaffold(body: _StyleProbe())),
          ),
        );
        expect(_readStyle(tester), s, reason: '${s.name} 挂载后应可读');
      }
    });
  });

  group('StyleTokens 三风格档位', () {
    // 极简分支必须与静态档位逐字节一致（回归面为零）。
    testWidgets('极简：control/card/sheet 与 R 静态档位一致', (tester) async {
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.minimalist,
          child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
        ),
      );
      final context = tester.element(find.byType(_TokenProbe));
      expect(StyleTokens.controlRadius(context), R.control);
      expect(StyleTokens.cardRadius(context), R.card);
      expect(StyleTokens.sheetRadius(context), R.sheet);
    });

    testWidgets('极简：cardShadow/cardGradient 无、cardBorder 为 1px 描边', (tester) async {
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.minimalist,
          child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
        ),
      );
      final context = tester.element(find.byType(_TokenProbe));
      expect(StyleTokens.cardShadow(context), isNull);
      expect(StyleTokens.cardGradient(context), isNull);
      final border = StyleTokens.cardBorder(context);
      expect(border, isNotNull);
      expect(border!.width, 1);
    });

    testWidgets('小米：大圆角 + 彩色阴影 + 渐变卡', (tester) async {
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.xiaomi,
          child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
        ),
      );
      final context = tester.element(find.byType(_TokenProbe));
      expect(StyleTokens.controlRadius(context), R.controlXiaomi);
      expect(StyleTokens.cardRadius(context), R.cardXiaomi);
      expect(StyleTokens.sheetRadius(context), R.sheetXiaomi);
      expect(StyleTokens.cardBorder(context), isNull); // 小米无描边
      expect(StyleTokens.cardShadow(context), isNotNull); // 彩色浮起
      expect(StyleTokens.cardGradient(context), isNotNull); // 品牌渐变
    });

    testWidgets('苹果：系统档圆角 + 细分隔线', (tester) async {
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.apple,
          child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
        ),
      );
      final context = tester.element(find.byType(_TokenProbe));
      expect(StyleTokens.controlRadius(context), R.controlApple);
      expect(StyleTokens.cardRadius(context), R.cardApple);
      expect(StyleTokens.sheetRadius(context), R.sheetApple);
      final border = StyleTokens.cardBorder(context);
      expect(border, isNotNull);
      expect(border!.width, lessThan(1)); // 细分隔线 < 1px
      expect(StyleTokens.cardShadow(context), isNull);
      expect(StyleTokens.cardGradient(context), isNull);
    });

    testWidgets('R.of 按风格解析四槽位（minimalist 与静态档位一致）', (tester) async {
      // R.of 只读 style 参数，用固定 BuildContext 即可。
      final ctx = _FakeContext();
      for (final (style, expectMap) in [
        (
          UIStyle.minimalist,
          {
            R.control: R.control,
            R.card: R.card,
            R.hero: R.hero,
            R.sheet: R.sheet,
          }
        ),
        (
          UIStyle.xiaomi,
          {
            R.control: R.controlXiaomi,
            R.card: R.cardXiaomi,
            R.hero: R.heroXiaomi,
            R.sheet: R.sheetXiaomi,
          }
        ),
        (
          UIStyle.apple,
          {
            R.control: R.controlApple,
            R.card: R.cardApple,
            R.hero: R.heroApple,
            R.sheet: R.sheetApple,
          }
        ),
      ]) {
        for (final entry in expectMap.entries) {
          expect(
            R.of(ctx, entry.key, style: style),
            entry.value,
            reason: '${style.name} 槽位 ${entry.key} 应为 ${entry.value}',
          );
        }
      }
    });
  });
}

/// 读当前风格的探针。
class _StyleProbe extends StatelessWidget {
  const _StyleProbe();
  @override
  Widget build(BuildContext context) {
    return Text(context.uiStyle.id);
  }
}

UIStyle _readStyle(WidgetTester tester) {
  final text = tester.widget<Text>(find.byType(Text)).data!;
  return UIStyle.fromId(text);
}

/// 读 StyleTokens 的探针（仅承载 context）。
class _TokenProbe extends StatelessWidget {
  const _TokenProbe();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// R.of 纯函数测试用假 BuildContext（R.of 只读 style 参数，不触真实树）。
class _FakeContext implements BuildContext {
  const _FakeContext();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
