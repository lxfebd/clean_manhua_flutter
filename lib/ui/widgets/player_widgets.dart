import 'package:flutter/material.dart';

/// ── 播放器通用配色 ──────────────────────────────────────────
class PlayerColors {
  PlayerColors._();
  static const accent = Color(0xFFFF6699); // 粉色主控件（B 站风）
  static const sr = Color(0xFF4DD0E1); // 超分标识青色
  static const track = Color(0x3DFFFFFF);
  static const buffer = Color(0x66FFFFFF);
  static const panelBg = Color(0xF01A1A1F);
}

String fmtDuration(Duration d) {
  final n = d.isNegative ? Duration.zero : d;
  final h = n.inHours;
  final m = n.inMinutes % 60;
  final s = n.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 进度条左右内缩量，保证首尾圆点完整可见、点击坐标与圆点位置一致。
const double kBarInset = 9.0;

/// ── 自定义进度条 ────────────────────────────────────────────
/// 细轨 + 缓冲进度 + 拖拽时轨道加粗、圆点放大，触摸热区比视觉高很多。
class PlayerProgressBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final ValueChanged<Duration> onSeek;

  /// 拖动过程中持续回调，用于顶部预览 HUD。
  final ValueChanged<Duration>? onDragUpdate;
  final ValueChanged<bool>? onDragStateChanged;

  const PlayerProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
    this.onDragUpdate,
    this.onDragStateChanged,
  });

  @override
  State<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends State<PlayerProgressBar> {
  bool _dragging = false;
  double _dragValue = 0;

  double get _ratio {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    if (_dragging) return _dragValue.clamp(0.0, 1.0);
    return (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  double get _bufferRatio {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (widget.buffered.inMilliseconds / total).clamp(0.0, 1.0);
  }

  void _updateFromDx(double dx, double width) {
    final trackW = width - kBarInset * 2;
    if (trackW <= 0) return;
    setState(() => _dragValue = ((dx - kBarInset) / trackW).clamp(0.0, 1.0));
    final target = widget.duration * _dragValue;
    widget.onDragUpdate?.call(target);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          _updateFromDx(d.localPosition.dx, width);
          widget.onSeek(widget.duration * _dragValue);
        },
        onHorizontalDragStart: (d) {
          setState(() => _dragging = true);
          widget.onDragStateChanged?.call(true);
          _updateFromDx(d.localPosition.dx, width);
        },
        onHorizontalDragUpdate: (d) => _updateFromDx(d.localPosition.dx, width),
        onHorizontalDragEnd: (_) {
          widget.onSeek(widget.duration * _dragValue);
          setState(() => _dragging = false);
          widget.onDragStateChanged?.call(false);
        },
        child: SizedBox(
          height: 26,
          child: CustomPaint(
            painter: _ProgressPainter(
              progress: _ratio,
              buffer: _bufferRatio,
              dragging: _dragging,
            ),
            size: Size(width, 26),
          ),
        ),
      );
    });
  }
}

class _ProgressPainter extends CustomPainter {
  final double progress;
  final double buffer;
  final bool dragging;
  _ProgressPainter({
    required this.progress,
    required this.buffer,
    required this.dragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 左右各留出 kBarInset，否则进度为 0 或 1 时圆点会被画布边缘切掉一半
    final trackW = size.width - kBarInset * 2;
    if (trackW <= 0) return;

    final h = dragging ? 5.0 : 3.0;
    final cy = size.height / 2;
    final r = Radius.circular(h);
    final paint = Paint()..isAntiAlias = true;

    void bar(double frac, Color c) {
      paint.color = c;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              kBarInset, cy - h / 2, trackW * frac.clamp(0.0, 1.0), h),
          r,
        ),
        paint,
      );
    }

    bar(1, PlayerColors.track);
    bar(buffer, PlayerColors.buffer);
    bar(progress, PlayerColors.accent);

    final cx = kBarInset + trackW * progress.clamp(0.0, 1.0);
    final dotR = dragging ? 8.0 : 5.5;
    canvas.drawCircle(
        Offset(cx, cy), dotR + 1.5, Paint()..color = const Color(0x33000000));
    canvas.drawCircle(Offset(cx, cy), dotR, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.progress != progress ||
      old.buffer != buffer ||
      old.dragging != dragging;
}

/// ── 侧边竖条 HUD（亮度 / 音量）──────────────────────────────
/// 贴着左/右边缘的细长胶囊，不遮挡画面主体。
class SideLevelHud extends StatelessWidget {
  final IconData icon;
  final double value; // 0~1
  final bool left;
  final Color tint;
  const SideLevelHud({
    super.key,
    required this.icon,
    required this.value,
    required this.left,
    this.tint = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return IgnorePointer(
      child: Align(
        alignment: left ? const Alignment(-0.92, -0.05) : const Alignment(0.92, -0.05),
        child: Container(
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xD9000000),
            borderRadius: BorderRadius.circular(23),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: tint, size: 20),
            const SizedBox(height: 10),
            // 竖向轨道：底部为 0，向上填充
            SizedBox(
              width: 5,
              height: 104,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(children: [
                  Container(color: PlayerColors.track),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: v <= 0 ? 0.001 : v,
                      widthFactor: 1,
                      child: Container(color: tint),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 34,
              child: Text(
                '${(v * 100).round()}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 横滑快进时的时间预览。
class SeekPreviewHud extends StatelessWidget {
  final Duration target;
  final Duration total;
  final Duration delta;
  const SeekPreviewHud({
    super.key,
    required this.target,
    required this.total,
    required this.delta,
  });

  @override
  Widget build(BuildContext context) {
    final forward = !delta.isNegative;
    final ds = delta.inSeconds.abs();
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                  color: Colors.white, size: 24),
              const SizedBox(width: 8),
              Text('${forward ? '+' : '-'}${ds}s',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 6),
            RichText(
              text: TextSpan(children: [
                TextSpan(
                    text: fmtDuration(target),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                TextSpan(
                    text: ' / ${fmtDuration(total)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 长按倍速提示（顶部飘条）。
class SpeedBoostHud extends StatelessWidget {
  final double rate;
  const SpeedBoostHud({super.key, required this.rate});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.72),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.keyboard_double_arrow_right_rounded,
                color: PlayerColors.accent, size: 20),
            const SizedBox(width: 6),
            Text(
                '${rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate}x 倍速播放中',
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// 右上角超分角标。
class SrBadge extends StatelessWidget {
  final String label;
  const SrBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: PlayerColors.sr.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PlayerColors.sr.withValues(alpha: 0.6)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.auto_awesome, size: 12, color: PlayerColors.sr),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                color: PlayerColors.sr,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4)),
      ]),
    );
  }
}

/// GPU 开销星级小方块。
class CostBar extends StatelessWidget {
  final int cost;
  const CostBar({super.key, required this.cost});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        final on = i < cost;
        return Container(
          width: 10,
          height: 4,
          margin: const EdgeInsets.only(right: 3),
          decoration: BoxDecoration(
            color: on
                ? (cost >= 4
                    ? const Color(0xFFFF7043)
                    : PlayerColors.sr)
                : Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

/// ── 面板容器 ────────────────────────────────────────────────
/// 全屏时从右侧滑出（B 站式侧栏），竖屏时底部弹出。
Future<T?> showPlayerPanel<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  required bool fromRight,
  double width = 320,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, a1, a2) {
      final content = _PanelShell(title: title, child: Builder(builder: builder));
      if (fromRight) {
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
              width: width, height: double.infinity, child: content),
        );
      }
      return Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(width: double.infinity, child: content),
      );
    },
    transitionBuilder: (ctx, anim, sec, child) {
      final curved =
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween<Offset>(
          begin: fromRight ? const Offset(1, 0) : const Offset(0, 1),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

class _PanelShell extends StatelessWidget {
  final String title;
  final Widget child;
  const _PanelShell({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PlayerColors.panelBg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white54, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
            const SizedBox(height: 4),
            Flexible(child: child),
          ]),
        ),
      ),
    );
  }
}

/// 面板里通用的可选项行。
class PanelOptionTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool selected;
  final VoidCallback onTap;
  const PanelOptionTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: selected ? PlayerColors.accent.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? PlayerColors.accent.withValues(alpha: 0.8)
                : Colors.white12,
          ),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: selected ? PlayerColors.accent : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11, height: 1.3)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          if (selected) ...[
            const SizedBox(width: 8),
            const Icon(Icons.check_rounded,
                color: PlayerColors.accent, size: 18),
          ],
        ]),
      ),
    );
  }
}
