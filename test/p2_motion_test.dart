import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/style_tokens.dart';
import 'package:xingmanxia/ui/widgets/motion.dart';
import 'package:xingmanxia/ui/widgets/skeleton.dart';

/// P2-01 减少动画 / P2-02 搜索页热区验收。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child, {bool reduce = false}) => MaterialApp(
        theme: AppTheme.light(0, false),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Scaffold(body: child),
        ),
      );

  group('P2-01 系统减少动画', () {
    testWidgets('FadeSlideIn 不再位移/延迟，内容首帧即可见', (tester) async {
      await tester.pumpWidget(host(
        const FadeSlideIn(
          delay: Duration(milliseconds: 500),
          child: Text('正文'),
        ),
        reduce: true,
      ));
      await tester.pump();
      expect(find.text('正文'), findsOneWidget);
      expect(find.byType(SlideTransition), findsNothing);
      expect(find.byType(FadeTransition), findsNothing);
      // 不等 500ms 延迟也必须已经显示：减少动画不能让内容更晚出现。
    });

    testWidgets('默认仍保留原进入动画（未被误关）', (tester) async {
      await tester.pumpWidget(host(const FadeSlideIn(child: Text('正文'))));
      await tester.pump();
      expect(find.byType(SlideTransition), findsOneWidget);
      expect(find.byType(FadeTransition), findsOneWidget);
    });

    testWidgets('SkeletonPulse 减少动画时停止呼吸', (tester) async {
      await tester.pumpWidget(host(
        const SkeletonPulse(child: SkeletonBox(width: 40, height: 40)),
        reduce: true,
      ));
      await tester.pump();
      // 只数 SkeletonPulse 子树：AppTheme/其它组件自己也会用 AnimatedBuilder。
      expect(
          find.descendant(
              of: find.byType(SkeletonPulse),
              matching: find.byType(AnimatedBuilder)),
          findsNothing);
    });

    testWidgets('PressableScale 减少动画时不缩放，但点击仍生效', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(host(
        PressableScale(onTap: () => tapped++, child: const Text('按钮')),
        reduce: true,
      ));
      final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.scale, 1.0);
      await tester.tap(find.text('按钮'));
      expect(tapped, 1);
    });

    testWidgets('时长 token 在减少动画时归零', (tester) async {
      late Duration entrance;
      late Duration press;
      await tester.pumpWidget(host(
        Builder(builder: (c) {
          entrance = StyleTokens.entranceDuration(c);
          press = StyleTokens.pressDuration(c);
          return const SizedBox();
        }),
        reduce: true,
      ));
      expect(entrance, Duration.zero);
      expect(press, Duration.zero);
    });
  });
}
