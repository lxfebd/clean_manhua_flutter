import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 渐入上滑动画：自动播放一次，子元素依次延迟。
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final double offset;
  final Curve curve;
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 480),
    this.offset = 20,
    this.curve = const Cubic(0.16, 1, 0.3, 1),
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: widget.curve);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: Offset(0, widget.offset / 100),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: widget.curve));

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
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// 按钮按下回弹效果（缩放 0.96）。
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final Duration duration;

  /// 是否可作为遥控器/键盘焦点（Android TV D-pad 导航），语义与
  /// `HoverEffect.focusable` 一致：聚焦放大 + OK/Enter 触发 onTap。
  final bool focusable;
  final FocusNode? focusNode;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.96,
    this.duration = const Duration(milliseconds: 120),
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
      child: AnimatedScale(
        scale: (_down || _focused) && widget.onTap != null
            ? widget.scale
            : 1.0,
        duration: widget.duration,
        curve: Curves.easeOut,
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
