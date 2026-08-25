import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../utils/danmaku.dart';

/// 播放器弹幕层：按播放进度调度弹幕，Ticker 驱动位移。
/// 数据来自 [DanmakuFetcher]，本层只负责调度与渲染。
class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuItem> items;
  final double position; // 当前播放秒
  final DanmakuSettings settings;

  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    required this.settings,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _Active {
  final DanmakuItem item;
  final double startTick;
  final int lane;
  final double width;
  _Active(this.item, this.startTick, this.lane, this.width);
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  static const int _scrollLanes = 5;
  static const int _topLanes = 2;
  static const int _bottomLanes = 2;
  static const double _laneCoolDown = 1.4; // 同 lane 相邻弹幕最小间隔（秒）
  static const double _fixedHold = 4.0; // 顶部/底部弹幕停留时长（秒）

  Ticker? _ticker;
  final List<_Active> _active = [];
  final List<double> _laneLast = List.filled(_scrollLanes, -1e9);
  final List<double> _topLast = List.filled(_topLanes, -1e9);
  final List<double> _bottomLast = List.filled(_bottomLanes, -1e9);
  int _nextItem = 0;
  double _lastPos = 0;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _lastPos = widget.position;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    // 进度回退（重播 / seek 后退）或数据源变化：清空活跃并按新进度重调度
    if (widget.position < _lastPos - 0.5 || widget.items != old.items) {
      _reset();
    }
    _lastPos = widget.position;
    _spawnPending();
  }

  void _reset() {
    _active.clear();
    _nextItem = 0;
    _laneLast.fillRange(0, _scrollLanes, -1e9);
    _topLast.fillRange(0, _topLanes, -1e9);
    _bottomLast.fillRange(0, _bottomLanes, -1e9);
  }

  void _spawnPending() {
    final items = widget.items;
    while (_nextItem < items.length && items[_nextItem].time <= widget.position) {
      _spawn(items[_nextItem]);
      _nextItem++;
    }
  }

  void _spawn(DanmakuItem item) {
    if (!mounted) return;
    final tp = TextPainter(
      text: TextSpan(
        text: item.text,
        style: TextStyle(
          fontSize: widget.settings.fontSize,
          fontWeight: FontWeight.w600,
          color: Color(item.color),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    final now = _lastElapsed.inMicroseconds / 1e6;
    switch (item.type) {
      case 1:
        _spawnFixed(item, _topLanes, _topLast, now, w);
        break;
      case 2:
        _spawnFixed(item, _bottomLanes, _bottomLast, now, w);
        break;
      default:
        _spawnScroll(item, now, w);
    }
  }

  void _spawnFixed(DanmakuItem item, int lanes, List<double> last, double now, double w) {
    final lane = _pickLane(lanes, last, now, _fixedHold * 0.5);
    if (lane < 0) return; // 全部占满，丢弃防叠加
    last[lane] = now;
    _active.add(_Active(item, now, lane, w));
  }

  void _spawnScroll(DanmakuItem item, double now, double w) {
    final lane = _pickLane(_scrollLanes, _laneLast, now, _laneCoolDown);
    if (lane < 0) return;
    _laneLast[lane] = now;
    _active.add(_Active(item, now, lane, w));
  }

  int _pickLane(int lanes, List<double> last, double now, double cool) {
    for (var i = 0; i < lanes; i++) {
      if (now - last[i] >= cool) return i;
    }
    return -1;
  }

  void _onTick(Duration elapsed) {
    _lastElapsed = elapsed;
    if (!mounted || _active.isEmpty) return;
    final now = elapsed.inMicroseconds / 1e6;
    // 移除已完全移出屏幕 / 停留结束的弹幕
    _active.removeWhere((a) {
      if (a.item.type != 0) return now - a.startTick >= _fixedHold;
      return now - a.startTick >= _travelSec(a.width);
    });
    setState(() {});
  }

  double _travelSec(double textW) {
    final w = context.size?.width ?? 400;
    final px = 120 * widget.settings.speed; // 每秒移动像素
    return (w + textW) / px;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.settings.on || widget.items.isEmpty) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _DanmakuPainter(
          active: _active,
          fontSize: widget.settings.fontSize,
          opacity: widget.settings.opacity,
          tickerElapsed: _lastElapsed.inMicroseconds,
        ),
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  final List<_Active> active;
  final double fontSize;
  final double opacity;
  final int tickerElapsed;

  _DanmakuPainter({
    required this.active,
    required this.fontSize,
    required this.opacity,
    required this.tickerElapsed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (active.isEmpty) return;
    final now = tickerElapsed / 1e6;
    final lineH = fontSize * 1.6;
    final pxPerSec = 120.0;

    for (final a in active) {
      final item = a.item;
      final color = Color(item.color).withValues(alpha: opacity);
      final tp = TextPainter(
        text: TextSpan(
          text: item.text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dy = switch (item.type) {
        1 => 4 + a.lane * lineH, // 顶部弹幕
        2 => size.height - 4 - a.lane * lineH - lineH, // 底部弹幕
        _ => size.height * 0.14 + a.lane * lineH, // 滚动弹幕区
      };
      double dx;
      if (item.type == 0) {
        // 滚动：从右缘进入，横穿后从左侧移出
        final total = a.width + size.width;
        final progress = (now - a.startTick) * pxPerSec / total;
        dx = size.width - progress * total;
      } else {
        // 顶部/底部：水平居中停留
        dx = (size.width - a.width) / 2;
      }
      tp.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) =>
      old.active != active ||
      old.tickerElapsed != tickerElapsed ||
      old.fontSize != fontSize ||
      old.opacity != opacity;
}
