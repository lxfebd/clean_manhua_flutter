import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 小米 HyperOS 超椭圆（Squircle）形状。
///
/// 小米 MIUI/HyperOS 的标志性形状：方中带圆、圆角随曲率连续过渡，
/// 视觉上比普通 `RoundedRectangleBorder` 更"柔"。用超椭圆方程
/// `(x/a)^n + (y/b)^n = 1`（n=4）对四角做参数化采样，与 RN/原生
/// `squircle` 的实现思路一致。
///
/// 仅在 [UIStyle.xiaomi] 下由风格组件使用；其余风格继续用标准圆角，
/// 本形状类只是小米一张"卡"的替代实现，不改变布局尺寸。
class SquircleBorder extends ShapeBorder {
  const SquircleBorder({
    this.side = BorderSide.none,
    this.radius = 16,
  });

  final BorderSide side;
  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect.deflate(side.width), textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _squirclePath(rect, radius);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.width == 0) return;
    canvas.drawPath(
      getOuterPath(rect, textDirection: textDirection),
      side.toPaint(),
    );
  }

  @override
  ShapeBorder scale(double t) => SquircleBorder(
        side: side.scale(t),
        radius: radius * t,
      );

  /// 生成超椭圆外轮廓路径（n=4）。
  ///
  /// 结构：上直边 → 右上角(参数扫 π/2) → 右直边 → 右下角 → 下直边 →
  /// 左下角 → 左直边 → 左上角 → 闭合。四角用统一的超椭圆参数方程
  /// `x = r·cos(t)^(2/n), y = r·sin(t)^(2/n)`（n=4 → 各取 0.5 次幂），
  /// 每角从直边端点出发扫到相邻直边端点，保证 C1 连续。
  static Path _squirclePath(Rect rect, double r) {
    const n = 4.0;
    final w = rect.width;
    final h = rect.height;
    final rw = math.min(r, w / 2);
    final rh = math.min(r, h / 2);
    final left = rect.left;
    final top = rect.top;
    final right = rect.right;
    final bottom = rect.bottom;
    // 直边坐标
    final x0 = left + rw;
    final x1 = right - rw;
    final y1 = bottom - rh;

    const steps = 20;
    // 角采样：t∈[0,1] → 角度 π/2·t，返回角内相对角心的偏移。
    // 归一化坐标 (u,v) ∈ [0,1]：u 沿 x、v 沿 y，方向由象限决定。
    // 对 n=4：u = cos^(2/n), v = sin^(2/n) → 0.5 次幂。
    Offset corner(double t, {required bool mirrorX, required bool mirrorY}) {
      final ang = t * (math.pi / 2);
      final u = math.pow(math.cos(ang), 2 / n).toDouble();
      final v = math.pow(math.sin(ang), 2 / n).toDouble();
      return Offset(
        (mirrorX ? -u : u) * rw,
        (mirrorY ? -v : v) * rh,
      );
    }

    Path path = Path()..moveTo(x0, top);
    // 上直边 → 右上角
    path.lineTo(x1, top);
    for (var i = 1; i <= steps; i++) {
      final o = corner(i / steps, mirrorX: false, mirrorY: false);
      path.lineTo(right - rw + o.dx, top + rh + o.dy);
    }
    // 右直边 → 右下角
    path.lineTo(right, y1);
    for (var i = 1; i <= steps; i++) {
      final o = corner(i / steps, mirrorX: false, mirrorY: true);
      path.lineTo(right - rw + o.dx, bottom - rh + o.dy);
    }
    // 下直边 → 左下角
    path.lineTo(x1, bottom);
    for (var i = 1; i <= steps; i++) {
      final o = corner(i / steps, mirrorX: true, mirrorY: true);
      path.lineTo(left + rw + o.dx, bottom - rh + o.dy);
    }
    // 左直边 → 左上角
    path.lineTo(left, y1);
    for (var i = 1; i <= steps; i++) {
      final o = corner(i / steps, mirrorX: true, mirrorY: false);
      path.lineTo(left + rw + o.dx, top + rh + o.dy);
    }
    path.close();
    return path;
  }
}

/// 超椭圆剪裁容器（小米风格专用）。
///
/// 用法：`ClipPath(clipper: SquircleClipper(radius: hero), child: ...)`。
/// 内部用 [SquircleBorder] 的路径做剪裁，配合渐变/图片卡片用。
class SquircleClipper extends CustomClipper<Path> {
  const SquircleClipper({this.radius = 16});
  final double radius;

  @override
  Path getClip(Size size) =>
      SquircleBorder(radius: radius).getOuterPath(Offset.zero & size);

  @override
  bool shouldReclip(SquircleClipper oldClipper) => oldClipper.radius != radius;
}
