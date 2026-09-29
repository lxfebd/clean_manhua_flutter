import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android TV 平台判定（缓存一次查询结果）。
///
/// 播放器页需要区分「TV 遥控器媒体键」与桌面键盘快捷键：媒体键在
/// Android TV 上注册监听，桌面键仅桌面注册，避免移动端蓝牙键盘误触。
class TvPlatform {
  TvPlatform._();

  static bool? _isTv;

  static const MethodChannel _channel = MethodChannel('xingmanxia/tv');

  /// 是否运行在 Android TV（UI_MODE_TYPE_TELEVISION 或具备 leanback 特性）。
  /// 非 Android 平台恒 false；查询失败按 false 处理（不注册媒体键）。
  static Future<bool> get isTv async {
    if (_isTv != null) return _isTv!;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        _isTv = await _channel.invokeMethod<bool>('isTv') ?? false;
        return _isTv!;
      } catch (_) {
        _isTv = false;
      }
    } else {
      _isTv = false;
    }
    return _isTv!;
  }
}
