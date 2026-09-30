import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/style_scope.dart';
import 'package:xingmanxia/ui/style_tokens.dart';
import 'package:xingmanxia/ui/tokens.dart';
import 'package:xingmanxia/ui/widgets/frosted_glass.dart';
import 'package:xingmanxia/ui/widgets/motion.dart';
import 'package:xingmanxia/ui/widgets/row_separator.dart';

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

    testWidgets('动效轴：极简逐字节锁原值，小米回弹过冲、苹果平滑无过冲',
        (tester) async {
      // 极简 = 改造前原值（PressableScale 120ms/easeOut，FadeSlideIn 480ms/Cubic(0.16,1,0.3,1)）。
      const baselinePress = Curves.easeOut;
      const baselineEntrance = Cubic(0.16, 1, 0.3, 1);

      for (final s in UIStyle.values) {
        await tester.pumpWidget(
          StyleScope.demo(
            style: s,
            child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
          ),
        );
        final context = tester.element(find.byType(_TokenProbe));
        if (s == UIStyle.minimalist) {
          expect(StyleTokens.pressCurve(context), baselinePress);
          expect(StyleTokens.pressDuration(context),
              const Duration(milliseconds: 120));
          expect(StyleTokens.entranceCurve(context), baselineEntrance);
          expect(StyleTokens.entranceDuration(context),
              const Duration(milliseconds: 480));
        } else {
          expect(StyleTokens.pressCurve(context), isNot(baselinePress),
              reason: '${s.name} 按下曲线必须与极简不同（否则风格无意义）');
          expect(StyleTokens.entranceCurve(context), isNot(baselineEntrance));
        }
      }

      // 小米 = HyperOS 回弹：曲线在收尾前越过 1（过冲后收敛）。
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.xiaomi,
          child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
        ),
      );
      final xiaomi = tester.element(find.byType(_TokenProbe));
      // 回弹的定义：曲线在收尾前越过 1 再收敛。这里用采样值断言，
      // 因为 Cubic 的控制点字段是私有的，无法直接读。
      expect(StyleTokens.pressCurve(xiaomi), Curves.easeOutBack,
          reason: '小米按下曲线应为回弹曲线');
      expect(StyleTokens.entranceCurve(xiaomi), Curves.easeOutBack);
      expect(StyleTokens.entranceCurve(xiaomi).transform(0.6),
          greaterThan(1.0), reason: '小米入场应过冲（回弹）');

      // 苹果 = iOS 平滑：全程不越过 1（无回弹）。
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.apple,
          child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
        ),
      );
      final apple = tester.element(find.byType(_TokenProbe));
      for (var i = 1; i <= 10; i++) {
        final t = i / 10;
        expect(StyleTokens.pressCurve(apple).transform(t), lessThanOrEqualTo(1.0),
            reason: '苹果曲线在 t=$t 越界（不应回弹）');
        expect(StyleTokens.entranceCurve(apple).transform(t),
            lessThanOrEqualTo(1.0));
      }
    });

    testWidgets('PressableScale 真的按风格解析曲线（不是只定义 token）',
        (tester) async {
      for (final (style, wantCurve, wantMs) in [
        (UIStyle.minimalist, Curves.easeOut, 120),
        (UIStyle.xiaomi, Curves.easeOutBack, 180),
        (UIStyle.apple, const Cubic(0.32, 0.72, 0, 1), 200),
      ]) {
        await tester.pumpWidget(
          StyleScope.demo(
            style: style,
            child: MaterialApp(
              home: Scaffold(
                body: PressableScale(child: const Text('t'), onTap: () {}),
              ),
            ),
          ),
        );
        final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
        expect(scale.curve, wantCurve, reason: '${style.name} 按下曲线');
        expect(scale.duration, Duration(milliseconds: wantMs),
            reason: '${style.name} 按下时长');
      }
    });

    testWidgets('显式传参仍优先于风格轴（不被覆盖）', (tester) async {
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.xiaomi,
          child: MaterialApp(
            home: Scaffold(
              body: PressableScale(
                child: const Text('t'),
                onTap: () {},
                curve: Curves.linear,
                duration: const Duration(milliseconds: 90),
              ),
            ),
          ),
        ),
      );
      final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.curve, Curves.linear);
      expect(scale.duration, const Duration(milliseconds: 90));
    });

    testWidgets('RowSeparator：极简锁调用点原值（各页不同），苹果 inset，小米通栏',
        (tester) async {
      // 同一组件、同一调用点参数，三种风格下分别得到：极简=原值、苹果=inset、小米=通栏。
      for (final (style, wantLeft, wantAlpha) in [
        (UIStyle.minimalist, 64.0, 0.08), // 调用点原值：SettingsRow 的 inset 64 + hairline
        (UIStyle.apple, 46.0, 0.08),
        (UIStyle.xiaomi, 0.0, 0.08),
      ]) {
        await tester.pumpWidget(
          StyleScope.demo(
            style: style,
            child: MaterialApp(
              home: RowSeparator(tier: TextTier.hairline, indent: 64),
            ),
          ),
        );
        // 直接读 build 返回值：MaterialApp 内部也有 Container/Padding，
        // find.byType 会先命中它，所以不能靠 finder 区分。
        final el = tester.element(find.byType(RowSeparator));
        final built = (el.widget as RowSeparator).build(el);
        final dec = (built is Padding ? (built as Padding).child
            : built) as Container;
        final box = dec.decoration as BoxDecoration;
        expect(box.color!.a, closeTo(wantAlpha, 1e-9),
            reason: '${style.name} 分隔线档位');
        final left = built is Padding
            ? (built as Padding).padding as EdgeInsets
            : EdgeInsets.zero;
        expect(left.left, wantLeft, reason: '${style.name} 分隔线缩进');
      }

      // 另一调用点原值（设置页：通栏 + T.fill 0.06）——极简必须仍是 0/0.06，
      // 不能被组件统一成 SettingsRow 的 64/0.08。
      await tester.pumpWidget(
        StyleScope.demo(
          style: UIStyle.minimalist,
          child: MaterialApp(home: RowSeparator(tier: TextTier.fill, indent: 0)),
        ),
      );
      final el = tester.element(find.byType(RowSeparator));
      final built = (el.widget as RowSeparator).build(el);
      expect(built, isA<Container>(), reason: '极简通栏 → 不包 Padding');
      final box = (built as Container).decoration as BoxDecoration;
      expect(box.color!.a, closeTo(0.06, 1e-9));
    });

    testWidgets('分组卡底色：极简 = 原值 surface，苹果 = iOS 二级分组背景',
        (tester) async {
      for (final s in UIStyle.values) {
        await tester.pumpWidget(
          StyleScope.demo(
            style: s,
            child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
          ),
        );
        final context = tester.element(find.byType(_TokenProbe));
        final scheme = Theme.of(context).colorScheme;
        expect(StyleTokens.groupCardBackground(context),
            s == UIStyle.apple ? scheme.surfaceContainer : scheme.surface,
            reason: '${s.name} 分组卡底色');
      }
    });

    testWidgets('hero 槽位：极简锁各调用点原值，小米 28 / 苹果 16', (tester) async {
      // 大卡/头图的极简原值各页不同（详情页头图 14、首页轮播 12、我的页主卡 16），
      // 所以原值由调用点传入，不能由组件统一。
      for (final s in UIStyle.values) {
        await tester.pumpWidget(
          StyleScope.demo(
            style: s,
            child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
          ),
        );
        final context = tester.element(find.byType(_TokenProbe));
        for (final original in [14.0, 12.0, R.hero]) {
          expect(
            StyleTokens.heroRadius(context, original),
            s == UIStyle.minimalist
                ? original
                : (s == UIStyle.xiaomi ? R.heroXiaomi : R.heroApple),
            reason: '${s.name} hero 槽位（原值 $original）',
          );
        }
      }
    });

    testWidgets('列表行图标底块：极简锁 34/18，苹果 iOS 29pt，小米 HyperOS 40dp',
        (tester) async {
      for (final s in UIStyle.values) {
        await tester.pumpWidget(
          StyleScope.demo(
            style: s,
            child: const MaterialApp(home: Scaffold(body: _TokenProbe())),
          ),
        );
        final context = tester.element(find.byType(_TokenProbe));
        expect(
            StyleTokens.iconTileSize(context, 34),
            s == UIStyle.minimalist ? 34 : (s == UIStyle.apple ? 29 : 40),
            reason: '${s.name} 图标底块');
        expect(
            StyleTokens.iconGlyphSize(context, 18),
            s == UIStyle.minimalist ? 18 : (s == UIStyle.apple ? 17 : 20),
            reason: '${s.name} 图标字形');
      }
    });

    test('字号阶梯：极简逐字节锁既有档位，苹果走 iOS Dynamic Type，小米走 HyperOS', () {
      const ink = Color(0xFF101010);

      // 极简 = 改造前逐字节原值（字号 + 字重 + 行高）。
      final minimal = TypeScale.textTheme(ink);
      expect(minimal.bodyMedium!.fontSize, 14);
      expect(minimal.bodySmall!.fontSize, 12);
      expect(minimal.labelSmall!.fontSize, 11);
      expect(minimal.displaySmall!.fontWeight, FontWeight.w700);
      expect(minimal.labelSmall!.fontWeight, FontWeight.w500);
      expect(minimal.bodyMedium!.height, 1.45);

      // 苹果 = iOS 阶梯：正文比极简大一号，标题 semibold（iOS 不用 w700），行高更紧。
      final apple = TypeScale.textTheme(ink, style: UIStyle.apple);
      expect(apple.bodyMedium!.fontSize, TypeScale.bodyApple);
      expect(apple.bodySmall!.fontSize, TypeScale.metaApple);
      expect(apple.labelSmall!.fontSize, TypeScale.microApple);
      expect(apple.displaySmall!.fontWeight, FontWeight.w600);
      expect(apple.labelSmall!.fontWeight, FontWeight.w400);
      expect(apple.bodyMedium!.height, 1.35);

      // 小米 = HyperOS 阶梯：大标题/卡片标题偏粗。
      final xiaomi = TypeScale.textTheme(ink, style: UIStyle.xiaomi);
      expect(xiaomi.displaySmall!.fontSize, TypeScale.displayXiaomi);
      expect(xiaomi.titleLarge!.fontSize, TypeScale.titleXiaomi);
      expect(xiaomi.titleLarge!.fontWeight, FontWeight.w700);

      // 手机档不被桌面档连带放大（既有门禁语义在三风格下都成立）。
      expect(
          TypeScale.textTheme(ink, isTablet: false, style: UIStyle.xiaomi)
              .displaySmall!
              .fontSize,
          TypeScale.displayXiaomiPhone);
      expect(TypeScale.textTheme(ink, isTablet: false).displaySmall!.fontSize, 19);
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

    testWidgets('毛玻璃头：只有苹果启动滤镜，其余风格用调用点原色', (tester) async {
      // 头部各调用点的原色不同（首页收起头 = scaffoldBackgroundColor，小说页
      // SliverAppBar = scheme.surface），所以 fallbackColor 必须由调用点传入。
      const original = Color(0xFF101010);
      for (final (style, glass) in [
        (UIStyle.apple, true),
        (UIStyle.xiaomi, false),
        (UIStyle.minimalist, false),
      ]) {
        await tester.pumpWidget(
          StyleScope.demo(
            style: style,
            child: MaterialApp(
              home: FrostedGlass(
                fallbackColor: original,
                child: const SizedBox(height: 44, width: 44),
              ),
            ),
          ),
        );
        final glassScope = find.byType(FrostedGlass);
        final hasFilter = find
            .descendant(of: glassScope, matching: find.byType(BackdropFilter))
            .evaluate()
            .isNotEmpty;
        expect(hasFilter, glass, reason: '${style.name} 滤镜开关');
        final dec = tester
            .widget<DecoratedBox>(
                find.descendant(of: glassScope, matching: find.byType(DecoratedBox)))
            .decoration as BoxDecoration;
        if (glass) {
          expect(dec.color!.a, closeTo(0.78, 1e-9), reason: '苹果亮色档 0.78');
        } else {
          expect(dec.color, original, reason: '${style.name} 用调用点原色');
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
