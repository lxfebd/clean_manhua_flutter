import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/responsive.dart';

/// P2-04：共享组件必须吃 TextTheme 语义槽，不能自造 fontSize。
void main() {
  ThemeData theme() => ThemeData(
        useMaterial3: true,
        textTheme: const TextTheme(
          labelMedium: TextStyle(fontSize: 11),
          labelLarge: TextStyle(fontSize: 17),
          titleSmall: TextStyle(fontSize: 13),
          titleMedium: TextStyle(fontSize: 19),
        ),
      );

  Future<void> pumpAt(WidgetTester tester, Widget child, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: theme(),
      home: Scaffold(body: Center(child: child)),
    ));
  }

  testWidgets('TypeSegment 小屏用 labelMedium，中屏用 labelLarge', (tester) async {
    await pumpAt(tester, const TypeSegment(type: 0), 390);
    expect(tester.widget<Text>(find.text('漫画')).style?.fontSize, 11);

    await pumpAt(tester, const TypeSegment(type: 0), 800);
    expect(tester.widget<Text>(find.text('漫画')).style?.fontSize, 17);
  });

  testWidgets('SectionHeader 小屏用 titleSmall，中屏用 titleMedium', (tester) async {
    await pumpAt(
        tester, const SectionHeader(icon: Icons.book, title: '书架'), 390);
    expect(tester.widget<Text>(find.text('书架')).style?.fontSize, 13);

    await pumpAt(
        tester, const SectionHeader(icon: Icons.book, title: '书架'), 800);
    expect(tester.widget<Text>(find.text('书架')).style?.fontSize, 19);
  });
}
