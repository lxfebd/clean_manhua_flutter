import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/widgets/squircle.dart';

void main() {
  // 100x100、r=20：直边端点 x0=20, x1=80, y0=20, y1=80。
  // 正确路径的右上角弧经过 t=π/4 处 (80+20·0.8409, 20-20·0.8409)≈(96.8, 3.2)。
  // 若弧的起终点/符号错（旧实现从 (80,0) 斜插到 (100,25.6)），(95,5) 会被
  // 斜弦切到轮廓外 —— 这正是用户实测"封面被斜线切飞"的判据。
  group('SquircleBorder 路径几何', () {
    final rect = Rect.fromLTWH(0, 0, 100, 100);
    final path = SquircleBorder(radius: 20).getOuterPath(rect);

    test('轮廓恰好覆盖整个矩形（四角弧端点落在直边端点上）', () {
      expect(path.getBounds(), rect);
    });

    test('角部弧内侧点被包含（斜弦 bug 会把它切到轮廓外）', () {
      for (final p in [
        const Offset(95, 5), // 右上角弧内侧
        const Offset(95, 95), // 右下角弧内侧
        const Offset(5, 95), // 左下角弧内侧
        const Offset(5, 5), // 左上角弧内侧
      ]) {
        expect(path.contains(p), isTrue, reason: '角部点 $p 应在轮廓内');
      }
    });

    test('矩形四角顶点在轮廓外（形状是方中带圆，不是直角）', () {
      for (final p in [
        const Offset(99, 1),
        const Offset(99, 99),
        const Offset(1, 99),
        const Offset(1, 1),
      ]) {
        expect(path.contains(p), isFalse, reason: '角顶点 $p 应在轮廓外');
      }
    });

    test('直边中点被包含', () {
      expect(path.contains(const Offset(50, 1)), isTrue);
      expect(path.contains(const Offset(99, 50)), isTrue);
    });

    test('半径超过半边长时被夹取，轮廓仍等于矩形', () {
      final clamped = SquircleBorder(radius: 60).getOuterPath(rect);
      expect(clamped.getBounds(), rect);
      expect(clamped.contains(const Offset(50, 50)), isTrue);
    });

    test('非正方形：窄边决定该方向曲率', () {
      final narrow = Rect.fromLTWH(0, 0, 40, 100);
      final p = SquircleBorder(radius: 30).getOuterPath(narrow);
      expect(p.getBounds(), narrow);
      // rw 被夹到 20 → 左侧弧内侧点
      expect(p.contains(const Offset(3, 50)), isTrue);
      expect(p.contains(const Offset(37, 50)), isTrue);
    });
  });

  group('SquircleClipper', () {
    test('剪裁路径覆盖整个尺寸', () {
      final clipper = const SquircleClipper(radius: 16);
      expect(clipper.getClip(const Size(120, 80)).getBounds(),
          Rect.fromLTWH(0, 0, 120, 80));
    });

    test('仅半径变化触发重剪裁', () {
      const a = SquircleClipper(radius: 16);
      const b = SquircleClipper(radius: 16);
      const c = SquircleClipper(radius: 20);
      expect(a.shouldReclip(b), isFalse);
      expect(a.shouldReclip(c), isTrue);
    });
  });
}
