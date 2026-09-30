import 'dart:ui';

import 'package:flutter/material.dart';

import '../style_scope.dart';
import '../style_tokens.dart';

/// 苹果风格毛玻璃容器（frosted glass / vibrancy 近似）。
///
/// 用途：iOS 风格头部、浮层、底部悬浮栏的背景层。实现用 [BackdropFilter]
/// 把背后的内容高斯模糊 + 叠加半透明表面色，视觉接近 iOS 系统毛玻璃。
///
/// 性能约束（重要）：
/// - **只允许用于头部/浮层/悬浮条**（不随内容滚动的层），滚动列表项和
///   大列表内容禁用 —— BackdropFilter 会把命中区域的整层模糊，滚动时会
///   逐帧重算，低端机掉帧。
/// - [UIStyle.apple] 之外自动回退为纯表面色（半透明档），不启动滤镜。
/// - 移动端 iOS 上模糊半径 28 足够；Web/桌面保留并提供 [blurRadius] 参数。
class FrostedGlass extends StatelessWidget {
  const FrostedGlass({
    super.key,
    required this.child,
    this.borderRadius = 0,
    this.blurRadius = 28,
    this.alpha,
    this.border,
    this.fallbackColor,
    this.saturation = 1.0,
  });

  final Widget child;

  /// 背景圆角（贴合上层组件的圆角）。
  final double borderRadius;

  /// 高斯模糊半径。Web/CSS backdrop-filter 语义近似，值越大越糊。
  final double blurRadius;

  /// 表面色透明度覆盖；null = 用 [StyleTokens.frostedBackground] 默认档。
  final double? alpha;

  /// 边框（可传 hairline 细分隔线）。
  final Border? border;

  /// 非苹果风格用的纯色底。传该调用点改造前的原值（极简锁原值原则：
  /// 头部各处原本用的颜色并不相同 —— 首页头用 scaffoldBackgroundColor、
  /// 小说页 SliverAppBar 用 scheme.surface），不能由组件统一。
  final Color? fallbackColor;

  /// 饱和度增强（iOS vibrancy 近似，1.0 = 不增强）。
  final double saturation;

  @override
  Widget build(BuildContext context) {
    final style = context.uiStyle;
    if (style != UIStyle.apple) {
      // 非苹果风格：直接纯色底（不启动滤镜，性能零开销）。
      return DecoratedBox(
        decoration: BoxDecoration(
          color: fallbackColor ?? StyleTokens.frostedBackground(context),
          borderRadius: BorderRadius.circular(borderRadius),
          border: border,
        ),
        child: child,
      );
    }
    final bg = StyleTokens.frostedBackground(context);
    final color = alpha == null ? bg : bg.withValues(alpha: alpha);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: blurRadius,
          sigmaY: blurRadius,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(borderRadius),
            border: border,
          ),
          child: child,
        ),
      ),
    );
  }
}