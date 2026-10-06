import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../style_tokens.dart';

/// 渐入上滑动画：自动播放一次，子元素依次延迟。
///
/// 时长/曲线按 [StyleTokens] 风格轴解析（未显式传参时）：极简 = 改造前原值
/// 480ms / Cubic(0.16, 1, 0.3, 1)，小米带轻微过冲，苹果用 iOS 标准 ease。
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration? duration;
  final double offset;
  final Curve? curve;
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration,
    this.offset = 20,
    this.curve,
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration ?? const Duration(milliseconds: 480),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = widget.curve ?? StyleTokens.entranceCurve(context);
    final duration = widget.duration ?? StyleTokens.entranceDuration(context);
    if (_c.duration != duration) _c.duration = duration;
    final fade = CurvedAnimation(parent: _c, curve: curve);
    final slide = Tween<Offset>(
      begin: Offset(0, widget.offset / 100),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _c, curve: curve));
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(position: slide, child: widget.child),
    );
  }
}

/// 按钮按下反馈（缩放 0.96）。
///
/// 时长/曲线按 [StyleTokens] 风格轴解析（未显式传参时）：极简 = 改造前原值
/// 120ms / easeOut；小米 = HyperOS 回弹（过冲后收敛）；苹果 = iOS spring 近似。
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// 长按回调（如最近阅读卡长按删除）；null = 不响应长按。
  final VoidCallback? onLongPress;
  final double scale;
  final Duration? duration;
  final Curve? curve;

  /// 是否可作为遥控器/键盘焦点（Android TV D-pad 导航），语义与
  /// `HoverEffect.focusable` 一致：聚焦放大 + OK/Enter 触发 onTap。
  final bool focusable;
  final FocusNode? focusNode;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
    this.duration,
    this.curve,
    this.focusable = false,
    this.focusNode,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;
  bool _focused = false;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        widget.onTap != null &&
        (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      widget.onTap!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final pressable = GestureDetector(
      onTapDown: (_) {
        if (widget.onTap == null) return;
        setState(() => _down = true);
      },
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: (_down || _focused) && widget.onTap != null
            ? widget.scale
            : 1.0,
        duration: widget.duration ?? StyleTokens.pressDuration(context),
        curve: widget.curve ?? StyleTokens.pressCurve(context),
        child: widget.child,
      ),
    );

    if (!widget.focusable) return pressable;

    // TV/键盘焦点导航：外圈 Focus 接 D-pad，聚焦时主色焦点环。
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _handleKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: pressable,
      ),
    );
  }
}
