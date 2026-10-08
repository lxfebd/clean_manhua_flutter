import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'desktop_fullscreen.dart';

/// 播放器全屏进出统一入口：桌面真全屏 + 移动端沉浸/横屏三件套。
///
/// native_player_page 与 anime_player_page 各有一份逐行同构的全屏切换
/// （DesktopFullscreen.set + immersiveSticky + 横屏锁，退出时 edgeToEdge +
/// 恢复方向），收敛为这一份；页面只负责自己的 UI 状态（_fullscreen 标志、
/// 控制栏显隐/轮询等）。
class PlayerFullscreen {
  PlayerFullscreen._();

  /// 进入全屏：桌面把系统窗口本体切到真全屏，移动端保持沉浸 + 横屏。
  static Future<void> enter() async {
    await DesktopFullscreen.set(true);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// 退出全屏：还原窗口与系统 UI，恢复阅读方向（平板三向、手机竖屏）。
  static Future<void> exit() async {
    await DesktopFullscreen.set(false);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await _unlockOrientation();
  }

  /// 恢复方向：与两页原有 _unlockOrientation 同语义——平板保留竖屏+横屏，
  /// 手机回到竖屏（播放器全屏前的常态）。
  static Future<void> _unlockOrientation() async {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final w = view.physicalSize.width / view.devicePixelRatio;
    await SystemChrome.setPreferredOrientations(w >= 600.0
        ? [
            DeviceOrientation.portraitUp,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : [DeviceOrientation.portraitUp]);
  }
}