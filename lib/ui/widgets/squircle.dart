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
  /// 四角各是角方块内一段 1/4 超椭圆，满足 `|dx/rw|^(n/2)+|dy/rh|^(n/2)=1`
  /// （n=4 → 坐标取 sin/cos 的 0.5 次幂）。每段弧的起终点必须**严格落在
  /// 相邻直边端点上**（直边端点 → 弧 → 下一直边端点）；任何符号或象限
  /// 错误都会让 lineTo 在角上拉出斜弦，把内容斜切掉。
  static Path _squirclePath(Rect rect, double r) {
    const n = 4.0;
    final rw = math.min(r, rect.width / 2);
    final rh = math.min(r, rect.height / 2);
    // 直边端点：上/下边在 x0..x1 之间，左/右边在 y0..y1 之间。
    final x0 = rect.left + rw;
    final x1 = rect.right - rw;
    final y0 = rect.top + rh;
    final y1 = rect.bottom - rh;

    // 单位超椭圆第一象限坐标：t=0 → (0,1)，t=π/2 → (1,0)。
    double s(double t) => math.pow(math.sin(t), 2 / n).toDouble();
    double c(double t) => math.pow(math.cos(t), 2 / n).toDouble();

    const steps = 20;
    const halfPi = math.pi / 2;
    final path = Path()..moveTo(x0, rect.top);
    // 上直边 → 右上角：(x1, top) → (right, y0)
    path.lineTo(x1, rect.top);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps * halfPi;
      path.lineTo(x1 + rw * s(t), y0 - rh * c(t));
    }
    // 右直边 → 右下角：(right, y1) → (x1, bottom)
    path.lineTo(rect.right, y1);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps * halfPi;
      path.lineTo(x1 + rw * c(t), y1 + rh * s(t));
    }
    // 下直边 → 左下角：(x0, bottom) → (left, y1)
    path.lineTo(x0, rect.bottom);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps * halfPi;
      path.lineTo(x0 - rw * s(t), y1 + rh * c(t));
    }
    // 左直边 → 左上角：(left, y0) → (x0, top)
    path.lineTo(rect.left, y0);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps * halfPi;
      path.lineTo(x0 - rw * c(t), y0 - rh * s(t));
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
