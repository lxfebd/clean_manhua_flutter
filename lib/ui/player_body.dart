import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 播放主体布局（稳定树位）：舞台（Video/Texture）在任何模式下都挂在
/// 同一父链的同一槽位（Stack index 0），全屏切换只改变 Positioned 的
/// 矩形，绝不销毁重建 Video 子树。
///
/// 根因（2026-09-21 实测）：旧实现 `body: fullscreen ? stage : Column[
/// AspectRatio(stage), panel]` 父链类型不同且无 GlobalKey → 全屏时
/// Video/Texture 被销毁重建，media_kit 的 Windows 渲染在纹理重挂载后
/// 不再向新纹理推帧 → 画面定格、只剩声音（mpv 时钟与 DIAG 全程正常，
/// 退出全屏再重建一次才恢复）。
Widget buildPlayerBody({
  required bool fullscreen,
  required bool isTablet,
  required double panelWidth,
  required EdgeInsets padding,
  required Widget stage,
  required Widget panel,
}) {
  return LayoutBuilder(builder: (context, box) {
    final w = box.maxWidth;
    final h = box.maxHeight;
    if (fullscreen) {
      return Stack(children: [
        Positioned.fill(child: stage),
      ]);
    }
    final Rect stageRect;
    final Rect panelRect;
    if (isTablet) {
      // 左舞台右面板：舞台在剩余区域内按 16:9 居中（对齐旧 Row 布局）
      final areaW = math.max(0.0, w - panelWidth - padding.left - padding.right);
      final areaH = math.max(0.0, h - padding.top);
      final sw = math.min(areaW, areaH * 16 / 9);
      final sh = sw * 9 / 16;
      stageRect = Rect.fromLTWH(
        padding.left + (areaW - sw) / 2,
        padding.top + (areaH - sh) / 2,
        sw,
        sh,
      );
      panelRect = Rect.fromLTWH(w - panelWidth, 0, panelWidth, h);
    } else {
      // 上舞台下面板：舞台占满宽（减左右安全区），面板吃掉剩余高度
      final sw = math.max(0.0, w - padding.left - padding.right);
      final sh = sw * 9 / 16;
      stageRect = Rect.fromLTWH(padding.left, padding.top, sw, sh);
      panelRect = Rect.fromLTWH(padding.left, padding.top + sh, sw,
          math.max(0.0, h - padding.top - sh));
    }
    return Stack(children: [
      Positioned.fromRect(rect: stageRect, child: stage),
      Positioned.fromRect(
        rect: panelRect,
        child: isTablet
            ? DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Colors.white12, width: 0.8),
                  ),
                ),
                child: panel,
              )
            : panel,
      ),
    ]);
  });
}
