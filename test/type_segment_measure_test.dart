import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/responsive.dart';
import 'package:xingmanxia/ui/widgets/tap_target.dart';

/// TypeSegment 选中块必须撑满整段槽位（宽 ≥44、高 = 槽高）。
///
/// 历史 bug：TapTargetMin 的 Align 松弛约束 → AnimatedContainer 只按
/// 文字定宽高 → 选中态缩成贴字小条/横条。本测试锁死尺寸防回归。
void main() {
  Future<void> pumpAt(WidgetTester tester, double width, int type) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(0, false),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: TypeSegment(type: type, onChanged: (_) {}),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  List<Size> segSizes(WidgetTester tester) {
    final segs = find.descendant(
      of: find.byType(TypeSegment),
      matching: find.byType(AnimatedContainer),
    );
    return [
      for (final e in segs.evaluate())
        (e.renderObject as RenderBox).size,
    ];
  }

  testWidgets('手机 390dp：三段均 ≥44 宽、高撑满槽（44）', (tester) async {
    await pumpAt(tester, 390, 0);
    final sizes = segSizes(tester);
    expect(sizes.length, 3);
    for (var i = 0; i < 3; i++) {
      expect(sizes[i].width, greaterThanOrEqualTo(44.0),
          reason: '段 #$i 宽 ${sizes[i].width} 未撑满 44 热区');
      expect(sizes[i].height, greaterThanOrEqualTo(44.0),
          reason: '段 #$i 高 ${sizes[i].height} 未撑满槽高 44');
      // 选中段须与同排最宽段一致（横向不缩条）。
      expect(sizes[i].width, greaterThanOrEqualTo(sizes[0].width - 0.01),
          reason: '段 #$i 比选中段窄，宽度不齐');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('平板 1000dp：三段均 ≥44 宽、高撑满槽（48）', (tester) async {
    await pumpAt(tester, 1000, 1);
    final sizes = segSizes(tester);
    expect(sizes.length, 3);
    for (var i = 0; i < 3; i++) {
      expect(sizes[i].width, greaterThanOrEqualTo(44.0),
          reason: '段 #$i 宽 ${sizes[i].width} 未撑满 44 热区');
      expect(sizes[i].height, greaterThanOrEqualTo(48.0),
          reason: '段 #$i 高 ${sizes[i].height} 未撑满槽高 48');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中块 RenderBox 覆盖 TapTargetMin 同位热区', (tester) async {
    await pumpAt(tester, 390, 0);
    // 若仍包 TapTargetMin，选中 AnimatedContainer 必须铺满其 44×44；
    // 若已改为裸 ConstrainedBox，AnimatedContainer 自身即热区。
    final tts = find.descendant(
      of: find.byType(TypeSegment),
      matching: find.byType(TapTargetMin),
    );
    final selected = find
        .descendant(
          of: find.byType(TypeSegment),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    final selBox = selected.evaluate().first.renderObject as RenderBox;
    expect(selBox.size.width, greaterThanOrEqualTo(44.0));
    expect(selBox.size.height, greaterThanOrEqualTo(44.0));
    if (tts.evaluate().isNotEmpty) {
      final ttBox =
          tts.evaluate().first.renderObject as RenderBox;
      expect(selBox.size.width, greaterThanOrEqualTo(ttBox.size.width - 0.01),
          reason: '选中块宽度未铺满 TapTargetMin 热区');
      expect(selBox.size.height, greaterThanOrEqualTo(ttBox.size.height - 0.01),
          reason: '选中块高度未铺满 TapTargetMin 热区');
    }
  });
}
