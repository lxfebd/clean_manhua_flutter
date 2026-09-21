import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/native_player_page.dart';

/// 播放主体「稳定树位」回归测试（全屏卡死 bug，2026-09-21）。
///
/// 历史根因：全屏切换时 body 的父链组件类型改变（Stack vs Column/Row），
/// Video/Texture 被销毁重建，media_kit Windows 渲染在纹理重挂载后断帧
/// → 画面定格只剩声音。本测试锁死两件事：
/// 1. 全屏/窗口切换绝不重建舞台子树（State 实例前后一致）；
/// 2. 三种模式的舞台/面板矩形与旧布局（SafeArea+AspectRatio 16:9）等价。
class _StageProbe extends StatefulWidget {
  const _StageProbe();

  @override
  State<_StageProbe> createState() => _StageProbeState();
}

class _StageProbeState extends State<_StageProbe> {
  static int created = 0;

  @override
  void initState() {
    super.initState();
    created++;
  }

  @override
  Widget build(BuildContext context) =>
      Container(key: const ValueKey('stage'), color: Colors.green);
}

Widget _wrap({
  required bool fullscreen,
  required bool isTablet,
  Size view = const Size(800, 600),
  EdgeInsets padding = EdgeInsets.zero,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: view, padding: padding),
      child: Scaffold(
        body: buildPlayerBody(
          fullscreen: fullscreen,
          isTablet: isTablet,
          panelWidth: 320,
          padding: padding,
          stage: const _StageProbe(),
          panel: const SizedBox(key: ValueKey('panel'), height: 10),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => _StageProbeState.created = 0);

  testWidgets('窗口↔全屏来回切换不重建舞台子树', (tester) async {
    await tester.pumpWidget(_wrap(fullscreen: false, isTablet: false));
    expect(_StageProbeState.created, 1);

    Future<void> setFs(bool fs) async {
      await tester.pumpWidget(_wrap(fullscreen: fs, isTablet: false));
      await tester.pump();
    }

    await setFs(true);
    expect(_StageProbeState.created, 1, reason: '进全屏重建了舞台 → 纹理断帧卡死回归');

    await setFs(false);
    expect(_StageProbeState.created, 1, reason: '退全屏重建了舞台');

    // 平板布局同样不得重建
    await tester.pumpWidget(_wrap(fullscreen: false, isTablet: true));
    await tester.pump();
    expect(_StageProbeState.created, 1);
  });

  testWidgets('手机竖屏：舞台 16:9 置顶，面板吃掉剩余高度', (tester) async {
    await tester.pumpWidget(_wrap(fullscreen: false, isTablet: false));
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('stage'))),
        const Rect.fromLTWH(0, 0, 800, 450));
    expect(tester.getRect(find.byKey(const ValueKey('panel'))),
        const Rect.fromLTWH(0, 450, 800, 150));
  });

  testWidgets('手机竖屏带安全区：与旧 SafeArea 布局等价', (tester) async {
    const pad = EdgeInsets.fromLTRB(10, 30, 20, 16);
    await tester.pumpWidget(
        _wrap(fullscreen: false, isTablet: false, padding: pad));
    await tester.pump();
    // 旧布局：SafeArea(bottom:false) 包 Column[AspectRatio(16:9), Expanded]
    final sw = 800 - pad.left - pad.right; // 770
    final sh = sw * 9 / 16;
    expect(tester.getRect(find.byKey(const ValueKey('stage'))),
        Rect.fromLTWH(pad.left, pad.top, sw, sh));
    expect(tester.getRect(find.byKey(const ValueKey('panel'))),
        Rect.fromLTWH(pad.left, pad.top + sh, sw, 600 - pad.top - sh));
  });

  testWidgets('平板横排：舞台在左区 16:9 居中，面板贴右全高', (tester) async {
    await tester.pumpWidget(_wrap(fullscreen: false, isTablet: true));
    await tester.pump();
    // 左区 480×600 → 16:9 舞台 480×270 垂直居中
    expect(tester.getRect(find.byKey(const ValueKey('stage'))),
        const Rect.fromLTWH(0, 165, 480, 270));
    expect(tester.getRect(find.byKey(const ValueKey('panel'))),
        const Rect.fromLTWH(480, 0, 320, 600));
  });

  testWidgets('全屏：舞台铺满整个 body，面板移除', (tester) async {
    await tester.pumpWidget(_wrap(fullscreen: true, isTablet: false));
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('stage'))),
        const Rect.fromLTWH(0, 0, 800, 600));
    expect(find.byKey(const ValueKey('panel')), findsNothing);
  });
}
