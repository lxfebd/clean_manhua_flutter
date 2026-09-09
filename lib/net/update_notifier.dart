import 'dart:async';

import 'package:flutter/services.dart';

import 'local_store.dart';

/// 书架更新推送通知：复用原生 MethodChannel（MainActivity 已实现
/// `xingmanxia/update_notification` 的 `showShelfUpdate`）。
///
/// 设计（对齐 PLANNING 批次 B-6）：
/// - 设置页开关（默认关），状态存 LocalStore `update_notify_enabled`
/// - 同一作品 24h 内只提醒一次（记录上次通知时间戳，按作品名去重）
/// - 通知点击回到书架（原生侧 PendingIntent 拉起 MainActivity）
/// - 纯前台触发（后台定时走 ShelfUpdater 的 Timer + 下次启动补检兜底，
///   不依赖 workmanager——国产 ROM 后台限制）
class UpdateNotifier {
  UpdateNotifier._();

  static final UpdateNotifier instance = UpdateNotifier._();

  static const _channel = MethodChannel('xingmanxia/update_notification');

  static const int _notifyCooldownHours = 24;

  /// 是否已打开系统通知权限（Android 13+ 首次调用前请求）。
  Future<bool> ensurePermission() async {
    try {
      await _channel.invokeMethod(
          'ensureNotificationPermission'); // Kotlin 侧实现（静默，失败不阻塞）
    } catch (_) {}
    return true;
  }

  /// 读取用户是否开启书架更新推送（默认关）。
  static Future<bool> enabled() async {
    final v = await LocalStore.readJson('update_notify_enabled');
    return v == true;
  }

  /// 持久化推送开关。
  static Future<void> setEnabled(bool value) async {
    await LocalStore.writeJson('update_notify_enabled', value);
  }

  /// 判断某作品是否在冷却期内（上次提醒后 [now] 前 [hours] 内）。
  static Future<bool> withinCooldown(String name, DateTime now) async {
    final raw = await LocalStore.readJson('update_notify_last');
    if (raw is! Map) return false;
    final last = raw[name] as num?;
    if (last == null) return false;
    return now.millisecondsSinceEpoch - last.toInt() <
        Duration(hours: _notifyCooldownHours).inMilliseconds;
  }

  /// 记录某作品已提醒时间（覆盖旧值）。
  static Future<void> markNotified(String name, DateTime now) async {
    final raw = await LocalStore.readJson('update_notify_last');
    final m = (raw is Map ? Map<String, dynamic>.from(raw) : {});
    m[name] = now.millisecondsSinceEpoch;
    await LocalStore.writeJson('update_notify_last', m);
  }

  /// 发送书架更新通知（自动处理 24h 冷却与开关）。
  Future<void> notifyShelfUpdate(List<String> names) async {
    if (names.isEmpty) return;
    if (!await enabled()) return;
    final now = DateTime.now();
    final fresh = <String>[];
    for (final n in names) {
      if (!await withinCooldown(n, now)) {
        fresh.add(n);
        await markNotified(n, now);
      }
    }
    if (fresh.isEmpty) return;
    try {
      await _channel.invokeMethod('showShelfUpdate', {
        'title': '收藏有更新',
        'text': '${fresh.take(2).join('、')}${fresh.length > 2 ? ' 等 ${fresh.length} 部作品' : ''}有新章节',
        'names': fresh,
      });
    } catch (e) {
      // 原生通道不可用（如桌面端无实现）静默
    }
  }
}
