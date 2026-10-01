import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/main_shell.dart';

/// 触控热区门禁（8-31 重设计划·阶段 1 收口）。
///
/// 原理：真实渲染 MainShell（首页/书架/工具/我的四 Tab，手机/平板两宽度），
/// 用应用真实主题（AppTheme，M3 按钮 40dp 会由此兜底为 44），
/// 遍历渲染树找出所有"可点击"控件（GestureDetector(onTap)/IconButton/
/// PressableScale/HoverEffect/InkWell 等），量其 RenderBox 的
/// shortestSide，统计 <44dp 的数量。基线只减不增（棘轮），
/// 修复热区后下调基线，直至 0。
void main() {
  // 判定一个 Element 是否"可点击控件"：命中可点语义即计入。
  bool isTappable(Element e) {
    final w = e.widget;
    if (w is GestureDetector && w.onTap != null) return true;
    if (w is InkWell && w.onTap != null) return true;
    if (w is IconButton) return true;
    // PressableScale / HoverEffect：类型名判断（避免引入 motion.dart 依赖
    // 在测试里走真实语义；其本质是 GestureDetector 子类）。
    final typeName = w.runtimeType.toString();
    if (typeName.contains('PressableScale') ||
        typeName.contains('HoverEffect')) {
      return true;
    }
    return false;
  }

  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 用应用真实主题（M3 按钮 minimumSize 44 兜底在这里生效）。
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
      theme: AppTheme.light(0, false),
      home: const MainShell(),
    )));
    await tester.pump(const Duration(milliseconds: 100));
  }

  // 收集某个页面里短边 <44 的可点控件（按类型+尺寸去重，避免网格重复计数）。
  List<String> collectTinyTaps(WidgetTester tester) {
    final tiny = <String>[];
    final seen = <String>{};
    for (final e in tester.allElements) {
      final w = e.widget;
      if (!isTappable(e)) continue;
      final box = e.renderObject;
      if (box is! RenderBox) continue;
      if (!box.hasSize) continue;
      final s = box.size.shortestSide;
      if (s >= 44) continue;
      final type = w.runtimeType.toString();
      final key = '$type@${s.toStringAsFixed(1)}';
      if (seen.contains(key)) continue;
      seen.add(key);
      tiny.add('$type(${s.toStringAsFixed(1)}dp)');
    }
    return tiny;
  }

  group('触控热区棘轮（可点控件短边 <44dp 计数只减不增）', () {
    testWidgets('手机 390dp：四 Tab 欠账清单（基线探测，先看当前值）',
        (tester) async {
      await pumpAt(tester, 390);
      final home = collectTinyTaps(tester);
      await tester.tap(find.text('书架').first);
      await tester.pump(const Duration(milliseconds: 100));
      final shelf = collectTinyTaps(tester);
      await tester.tap(find.text('工具').first);
      await tester.pump(const Duration(milliseconds: 100));
      final tools = collectTinyTaps(tester);
      await tester.tap(find.text('我的').first);
      await tester.pump(const Duration(milliseconds: 100));
      final profile = collectTinyTaps(tester);
      // ignore: avoid_print
      print('PHONE tiny: home=$home shelf=$shelf tools=$tools profile=$profile');
      expect(home.length, lessThanOrEqualTo(0),
          reason: '首页手机 390dp 仍有 ${home.length} 处欠账热区：$home');
      expect(shelf.length, lessThanOrEqualTo(0),
          reason: '书架手机 390dp 仍有 ${shelf.length} 处欠账热区：$shelf');
      expect(tools.length, lessThanOrEqualTo(0),
          reason: '工具手机 390dp 仍有 ${tools.length} 处欠账热区：$tools');
      expect(profile.length, lessThanOrEqualTo(0),
          reason: '我的手机 390dp 仍有 ${profile.length} 处欠账热区：$profile');
    });

    testWidgets('平板 1000dp：四 Tab 欠账清单', (tester) async {
      await pumpAt(tester, 1000);
      final home = collectTinyTaps(tester);
      await tester.tap(find.text('书架').first);
      await tester.pump(const Duration(milliseconds: 100));
      final shelf = collectTinyTaps(tester);
      await tester.tap(find.text('工具').first);
      await tester.pump(const Duration(milliseconds: 100));
      final tools = collectTinyTaps(tester);
      await tester.tap(find.text('我的').first);
      await tester.pump(const Duration(milliseconds: 100));
      final profile = collectTinyTaps(tester);
      // ignore: avoid_print
      print('TABLET tiny: home=$home shelf=$shelf tools=$tools profile=$profile');
      expect(home.length, lessThanOrEqualTo(0),
          reason: '首页平板 1000dp 仍有 ${home.length} 处欠账热区：$home');
      expect(shelf.length, lessThanOrEqualTo(0),
          reason: '书架平板 1000dp 仍有 ${shelf.length} 处欠账热区：$shelf');
      expect(tools.length, lessThanOrEqualTo(0),
          reason: '工具平板 1000dp 仍有 ${tools.length} 处欠账热区：$tools');
      expect(profile.length, lessThanOrEqualTo(0),
          reason: '我的平板 1000dp 仍有 ${profile.length} 处欠账热区：$profile');
    });
  });
}
