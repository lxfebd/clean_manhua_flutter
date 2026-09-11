import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统画中画（PiP）通道封装：Android 8.0+/API 26+ 原生 `enterPictureInPictureMode`。
///
/// 与本项目「App 内迷你小窗」（PlayerRegistry + MiniPlayer，跨页悬停）不同：
/// 这是**系统级** PiP 悬浮窗（退回桌面/切到其他 App 仍在系统层播放）。
/// 非 Android 或系统不支持时静默返回 false，播放页自行决定隐藏入口。
class PipChannel {
  PipChannel._();

  static const MethodChannel _channel = MethodChannel('xingmanxia/pip');

  /// PiP 状态变更回调（原生 onPictureInPictureModeChanged → Dart）。
  /// true=进入 PiP（Activity 转为小窗），false=退出 PiP（恢复全屏）。
  static ValueNotifier<bool>? inPip;

  /// 安装 PiP 状态监听（播放页 initState 调用一次，幂等）。
  /// 返回 true 时表示通道可用（Android + 系统支持）。
  static Future<bool> install() async {
    if (inPip != null) return true;
    final ok = await isSupported();
    if (!ok) return false;
    inPip = ValueNotifier(false);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        final v = call.arguments as bool? ?? false;
        inPip?.value = v;
      }
      return null;
    });
    return true;
  }

  /// 系统是否支持 PiP（Android 8+ 且有该特性声明）。
  static Future<bool> isSupported() async {
    // 仅 Android 有意义；其它平台走 App 内小窗路线。
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    if (kIsWeb) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 设置 PiP 画面比例（跟随视频实际宽高；不设置在 PiP 内变形）。
  static Future<void> setAspectRatio(int width, int height) async {
    if (width <= 0 || height <= 0) return;
    try {
      await _channel.invokeMethod('setAspectRatio',
          {'width': width, 'height': height});
    } catch (_) {}
  }

  /// 请求进入系统 PiP。成功后 Activity 转为小窗，Flutter 层收到
  /// [inPip] 变为 true。返回是否成功发起。
  static Future<bool> enter() async {
    try {
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } catch (_) {
      return false;
    }
  }
}