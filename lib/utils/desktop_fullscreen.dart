import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面端（Windows/macOS/Linux）「真全屏」辅助：把系统窗口本体切换为
/// 全屏/还原。手机端永远走 false（保持原有 SystemChrome 方向/沉浸逻辑）。
///
/// 背景：移动端 `SystemChrome.immersiveSticky + 横屏锁` 就能全屏；但桌面端
/// 这套只影响系统 UI，窗口本体还是原来的尺寸，效果只是「页面内全屏」。
/// window_manager 在桌面把窗口置为全屏（Windows 等效于 Win+Shift+Enter），
/// 才能真正占满屏幕。
class DesktopFullscreen {
  DesktopFullscreen._();

  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  static Future<bool> set(bool fullscreen) async {
    if (!isDesktop) return false;
    try {
      final win = windowManager;
      final target = await win.isFullScreen();
      if (target == fullscreen) return true;
      if (fullscreen) {
        await win.setFullScreen(true);
        // 全屏时也隐藏系统标题栏/菜单栏（macOS 全屏自带隐藏，Windows 由
        // window_manager 处理），退出时由 window_manager 自动恢复。
      } else {
        await win.setFullScreen(false);
      }
      return true;
    } catch (e) {
      // 平台不支持（如 Linux 无 WM 支持）时静默失败，页面内全屏仍可用。
      return false;
    }
  }
}
