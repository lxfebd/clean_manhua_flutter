import 'dart:async';

import 'package:flutter/material.dart';

import '../sources/source_manager.dart';
import 'bookshelf_store.dart';
import 'local_store.dart';

/// 更新检查频率。
enum UpdateFreq { off, every6h, every12h, daily }

extension UpdateFreqX on UpdateFreq {
  static const _labels = {
    UpdateFreq.off: '关闭',
    UpdateFreq.every6h: '每 6 小时',
    UpdateFreq.every12h: '每 12 小时',
    UpdateFreq.daily: '每天',
  };

  String get label => _labels[this] ?? '关闭';

  Duration? get interval => switch (this) {
        UpdateFreq.off => null,
        UpdateFreq.every6h => const Duration(hours: 6),
        UpdateFreq.every12h => const Duration(hours: 12),
        UpdateFreq.daily => const Duration(days: 1),
      };
}

/// 收藏更新检查：遍历书架，探测每本作品是否有新章节。
///
/// 用途：
/// - 书架页手动「检查更新」按钮（返回新增数量）
/// - 后台定时轮询（[ShelfUpdater] 持有 Timer，按用户设置的频率触发，
///   有更新时通过回调弹出应用内通知横幅）
///
/// 每次检查把最新章节数写入 BookshelfStore.lastChapters，
/// 供书架卡片角标（hasUpdate / newChapterCount）直接消费，
/// 避免同一作品在多次检查里重复计数。
class ShelfUpdater {
  ShelfUpdater._();

  /// 单例（应用生命周期内唯一 Timer）。
  static final ShelfUpdater instance = ShelfUpdater._();

  Timer? _timer;

  /// 后台检查发现新更新时的回调（UI 层挂横幅/提示）。
  ValueChanged<List<String>>? onUpdatesFound;

  /// 是否正在执行一轮检查（避免重入）。
  bool _checking = false;

  /// 从 LocalStore 恢复频率设置并启动/停止定时器。应用启动时调用。
  Future<void> restore() async {
    final f = await frequency();
    applyFrequency(f);
  }

  /// 读取用户设置的检查频率。
  static Future<UpdateFreq> frequency() async {
    final v = await LocalStore.readJson('update_check_freq');
    return switch (v) {
      '6h' => UpdateFreq.every6h,
      '12h' => UpdateFreq.every12h,
      'daily' => UpdateFreq.daily,
      _ => UpdateFreq.off,
    };
  }

  /// 持久化频率并立即生效（重启后由 [restore] 恢复）。
  static Future<void> setFrequency(UpdateFreq f) async {
    await LocalStore.writeJson('update_check_freq', switch (f) {
      UpdateFreq.off => 'off',
      UpdateFreq.every6h => '6h',
      UpdateFreq.every12h => '12h',
      UpdateFreq.daily => 'daily',
    });
  }

  /// 按频率启停定时器。off 时停止。
  void applyFrequency(UpdateFreq f) {
    _timer?.cancel();
    _timer = null;
    final iv = f.interval;
    if (iv == null) return;
    _timer = Timer.periodic(iv, (_) => checkInBackground());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// 前台检查（书架页手动触发）：返回有更新的作品名列表。
  /// 不做通知，只更新 lastChapters 与返回结果。
  static Future<List<String>> checkNow() async {
    final items = BookshelfStore.listAll();
    final updated = <String>[];
    for (final d in items) {
      final sid = d.sourceId ?? BookshelfStore.sourceIdOf(d.id);
      if (sid == null) continue;
      try {
        final detail = await SourceManager.byId(sid).detail(d.id);
        final cur = detail.chapters.length;
        if (cur > d.chapters.length) {
          updated.add(d.name);
          BookshelfStore.setLastSeenChapters(sid, d.id, cur);
        }
      } catch (_) {
        // 单本失败不阻塞整体检查（源抖动/反爬），下一轮再试
      }
    }
    return updated;
  }

  /// 后台定时检查：发现更新时通过 [onUpdatesFound] 通知 UI。
  Future<void> checkInBackground() async {
    if (_checking) return;
    _checking = true;
    try {
      final updated = await checkNow();
      if (updated.isNotEmpty) {
        onUpdatesFound?.call(updated);
      }
    } finally {
      _checking = false;
    }
  }
}
