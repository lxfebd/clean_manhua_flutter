import 'dart:async';

import 'package:flutter/services.dart';

import 'error_logger.dart';
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
    } catch (e) {
      ErrorLogger.instance
          .warn('UpdateNotifier 请求系统通知权限失败，书架更新推送将不可用: $e');
    }
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

  /// 记录某作品已提醒时间（覆盖旧值）。Map 上限 [_maxNotifyRecords]，
  /// 超出时删最早记录，防收藏长期增长导致永久膨胀。
  static const int _maxNotifyRecords = 100;

  static Future<void> markNotified(String name, DateTime now) async {
    final raw = await LocalStore.readJson('update_notify_last');
    final m = (raw is Map ? Map<String, dynamic>.from(raw) : {});
    m[name] = now.millisecondsSinceEpoch;
    if (m.length > _maxNotifyRecords) {
      // 删除时间戳最小的记录（最久未提醒的作品）
      String? oldest;
      int? oldestTs;
      m.forEach((k, v) {
        final ts = v is num ? v.toInt() : 0;
        if (oldestTs == null || ts < oldestTs!) {
          oldest = k;
          oldestTs = ts;
        }
      });
      if (oldest != null) m.remove(oldest);
    }
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

  /// 下载完成通知：批量/单话下载收尾时告知结果（走同一「系统通知」开关）。
  ///
  /// 与收藏更新共用开关与原生通道；桌面/Web 无原生实现时静默降级。
  /// [title] 如「《某漫画》下载完成」；[text] 结果摘要（成功/失败计数）。
  /// 失败时用 showError 通道（红标错误图标），成功用 showDone。
  static Future<void> notifyDownloadResult({
    required String title,
    required String text,
    required bool error,
  }) async {
    if (!await enabled()) return;
    try {
      await _channel.invokeMethod(error ? 'showError' : 'showDone', {
        'title': title,
        'text': text,
        'path': '',
      });
    } catch (e) {
      // 原生通道不可用（桌面/Web）静默降级
    }
  }

  /// 下载进度通知（更新包下载用）：进度条类通知节流由调用方控制
  /// （下载每秒多次分块，此处不重复实现节流）。done 为 true 时通知栏转
  /// 「可点击」完成态。
  static Future<void> notifyProgress({
    required String title,
    required String text,
    required int received,
    required int total,
    required bool done,
  }) async {
    try {
      await _channel.invokeMethod('showProgress', {
        'title': title,
        'text': text,
        'received': received,
        'total': total,
        'done': done,
      });
    } catch (_) {}
  }

  /// 取消/移除当前进度通知（下载取消或结束时清理通知栏）。
  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  /// 更新包下载结果通知（无开关门闸：用户主动触发下载，完成/失败必须告知，
  /// 不受书架推送开关影响）。[error] 为 true 走 showError（红标错误图标），
  /// 否则 showDone。带 [path]（安装包本地路径，通知点击拉起安装）。
  static Future<void> notifyResult({
    required String title,
    required String text,
    required bool error,
    String path = '',
  }) async {
    try {
      await _channel.invokeMethod(error ? 'showError' : 'showDone', {
        'title': title,
        'text': text,
        'path': path,
      });
    } catch (_) {}
  }

  /// 安装器启动通知（Android 系统安装器 / Windows NSIS 静默安装时提示）。
  static Future<void> notifyInstall(String path) async {
    try {
      await _channel.invokeMethod('showInstall', {'path': path});
    } catch (_) {}
  }
}
