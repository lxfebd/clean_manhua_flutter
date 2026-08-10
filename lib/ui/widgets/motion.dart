import 'package:flutter/material.dart';

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

/// 列表错峰渐入：把 children 包成多个 FadeSlideIn，每个延迟 60ms。
class StaggeredList extends StatelessWidget {
  final List<Widget> children;
  final Duration baseDelay;
  final Duration stagger;
  const StaggeredList({
    super.key,
    required this.children,
    this.baseDelay = Duration.zero,
    this.stagger = const Duration(milliseconds: 60),
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++)
          FadeSlideIn(
            delay: baseDelay + stagger * i,
            child: children[i],
          ),
      ],
    );
  }
}

/// 按钮按下回弹效果（缩放 0.96）。
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final Duration duration;
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.96,
    this.duration = const Duration(milliseconds: 120),
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        if (widget.onTap == null) return;
        setState(() => _down = true);
      },
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// 卡片悬停浮起效果（鼠标悬停 / 触屏按下时上浮 4px）。
class HoverLiftCard extends StatefulWidget {
  final Widget child;
  final double liftOffset;
  final List<BoxShadow> shadows;
  final VoidCallback? onTap;
  const HoverLiftCard({
    super.key,
    required this.child,
    this.liftOffset = 6,
    this.shadows = const [],
    this.onTap,
  });

  @override
  State<HoverLiftCard> createState() => _HoverLiftCardState();
}

class _HoverLiftCardState extends State<HoverLiftCard> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()
            ..translate(0.0, _hovered ? -widget.liftOffset : 0.0),
          decoration: BoxDecoration(
            boxShadow: _hovered ? widget.shadows : const [],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 呼吸光晕 — 用于热门徽章、直播提示等需要"活着"的元素。
class BreathingDot extends StatefulWidget {
  final Color color;
  final double size;
  const BreathingDot({super.key, required this.color, this.size = 8});
  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.4 + 0.5 * t),
                blurRadius: 6 + 10 * t,
                spreadRadius: 1 + 3 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 渐变流光 — 用于按钮/标签的微高光。
class ShimmerOverlay extends StatefulWidget {
  final Color color;
  final BorderRadius? borderRadius;
  final Widget? child;
  const ShimmerOverlay({
    super.key,
    required this.color,
    this.borderRadius,
    this.child,
  });

  @override
  State<ShimmerOverlay> createState() => _ShimmerOverlayState();
}

class _ShimmerOverlayState extends State<ShimmerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius ?? BorderRadius.zero,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) {
          return ShaderMask(
            shaderCallback: (rect) {
              return LinearGradient(
                begin: Alignment(-1.0 + 2.0 * _c.value, -0.3),
                end: Alignment(0.0 + 2.0 * _c.value, 0.3),
                colors: [
                  widget.color.withValues(alpha: 0),
                  widget.color.withValues(alpha: 0.35),
                  widget.color.withValues(alpha: 0),
                ],
                stops: const [0.35, 0.5, 0.65],
              ).createShader(rect);
            },
            child: widget.child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
