import 'package:flutter/material.dart';

import '../../net/subtitle_srt.dart';

/// 播放器字幕层：按播放进度显示当前命中的 SRT 字幕。
///
/// 与弹幕层（[DanmakuOverlay] 的 Ticker 驱动）不同——字幕只是「当前时刻命中
/// 的一条文本」，由播放器 position 监听直接驱动，无需 Ticker，倍速下自动同步
/// （position 是播放器实际进度）。数据来自 [SubtitleIndex]（SRT 已解析缓存）。
class SubtitleOverlay extends StatelessWidget {
  final SubtitleIndex? index; // null = 无字幕（层不显示）
  final int positionMs; // 当前播放毫秒
  final double fontSize;
  final Color textColor;

  const SubtitleOverlay({
    super.key,
    required this.index,
    required this.positionMs,
    this.fontSize = 20,
    this.textColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final idx = index;
    if (idx == null || idx.isEmpty) return const SizedBox.shrink();
    final cue = idx.at(positionMs);
    if (cue == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.only(bottom: 88), // 置于控制条上方
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 70),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            // 半透明黑底 + 描边，保证任意背景下字幕可读
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            cue.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: fontSize,
              color: textColor,
              fontWeight: FontWeight.w600,
              shadows: const [
                Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}