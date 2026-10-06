import 'dart:async';

import 'package:flutter/material.dart';

import '../sources/comic_source.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import 'bookshelf_store.dart';
import 'error_logger.dart';
import 'local_store.dart';
import 'novel_shelf_store.dart';
import 'update_notifier.dart';

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

  /// 单本详情请求的软超时：超时视为失败，避免某个源卡死拖垮整轮检查。
  static const Duration _perBookTimeout = Duration(seconds: 12);

  /// 同时探测的作品数上限（源侧反爬/连接池限制，避免并发打满全打 403）。
  static const int _concurrency = 6;

  /// 前台检查（书架页手动触发）：返回有更新的作品名列表。
  /// 不做通知，只更新 lastChapters 与返回结果。
  /// 并发探测（分组限流），任何失败（超时/网络）只跳过单本，不阻塞整轮；
  /// [onProgress] 每完成一本回调（done, total）供 UI 展示；[shouldCancel] 返回
  /// 非空时立即停止检查（返回 null 表示用户中途取消，调用方不再应用结果）。
  static Future<List<String>?> checkNow({
    void Function(int done, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    // 手动路径不经 checkInBackground：上一轮用户取消残留的 _isCancelled
    // 必须清零，否则本轮 checkOne/checkNovel 全部短路（空跑不报更新）。
    _isCancelled = false;
    final items = BookshelfStore.listAll();
    final novels = NovelShelfStore.listAll();
    final total = items.length + novels.length; // 进度总长（漫画+小说）
    final updated = <String>[];
    var done = 0;
    var index = 0;
    Future<void> checkOne(ComicDetail d) async {
      final sid = d.sourceId ?? BookshelfStore.sourceIdOf(d.id);
      if (sid == null) return;
      // byId 兜底回 current 永不返回 null；这里校验返回源是否真的匹配
      // 请求的 sid——不匹配视为未找到（小说 sid 混入漫画书架等异常场景），
      // 直接跳过，避免对错误源调 detail 后误报"无更新"或抛空指针被静默吞掉。
      final src = SourceManager.byId(sid);
      if (src.id != sid) {
        ErrorLogger.instance.warn(
            'shelf_updater: sid=$sid 返回源 ${src.id} 不匹配，跳过更新检查');
        return;
      }
      try {
        final detail = await src.detail(d.id).timeout(_perBookTimeout);
        if (!_isCancelled) {
          final cur = detail.chapters.length;
          if (cur > d.chapters.length) {
            updated.add(d.name);
            BookshelfStore.setLastSeenChapters(sid, d.id, cur);
          }
        }
      } catch (_) {
        // 单本失败不阻塞整体检查（源抖动/反爬），下一轮再试
      }
    }

    while (index < items.length) {
      final batch = items.skip(index).take(_concurrency).toList();
      await Future.wait(batch.map((d) async {
        await checkOne(d);
      }));
      if (shouldCancel?.call() ?? false) return null;
      done += batch.length;
      onProgress?.call(done, total);
      index += _concurrency;
    }

    // 阶段二：小说书架（NovelShelfStore）。基线是「上次检查记录的章节数」
    // lastChapters，而不是加入书架时的章节快照——加入时的 chapters 只是
    // 当时的目录，之后用户阅读过程中本地记录不会自动刷新。首次加入
    // （last=-1）先置基线不报更新，避免"第一次检查必报更新"的噪声。
    index = 0;
    Future<void> checkNovel(NovelDetail d) async {
      final sid = d.sourceId ?? '';
      if (sid.isEmpty) return;
      // novelById 找不到时兜底返回 currentNovel，必须校验 id 匹配
      // （与漫画阶段同构：错配视为未找到，跳过以免误报/误写别人的基线）。
      final src = SourceManager.novelById(sid);
      if (src == null || src.id != sid) {
        ErrorLogger.instance.warn(
            'shelf_updater: 小说 sid=$sid 未找到匹配源，跳过更新检查');
        return;
      }
      try {
        final detail = await src.detail(d.id).timeout(_perBookTimeout);
        if (_isCancelled) return;
        final cur = detail.chapters.length;
        final last = NovelShelfStore.lastSeenChapters(sid, d.id);
        if (last < 0) {
          NovelShelfStore.setLastSeenChapters(sid, d.id, cur);
        } else if (cur > last) {
          updated.add(d.name);
          NovelShelfStore.setLastSeenChapters(sid, d.id, cur);
        }
      } catch (_) {
        // 单本失败不阻塞整体检查（源抖动/反爬），下一轮再试
      }
    }

    while (index < novels.length) {
      final batch = novels.skip(index).take(_concurrency).toList();
      await Future.wait(batch.map(checkNovel));
      if (shouldCancel?.call() ?? false) return null;
      done += batch.length;
      onProgress?.call(done, total);
      index += _concurrency;
    }
    return updated;
  }

  /// 全局取消标记：任意一轮检查被 [checkNow] 取消时置位。
  static bool _isCancelled = false;

  /// 应用启动补检（B-6）：进程被杀后下次启动跑一轮后台检查，
  /// 命中更新即经 [checkInBackground] 走应用内横幅 + 系统通知
  /// （24h 冷却去重，见 [UpdateNotifier]）。
  /// 用户把轮询频率设为 off 时跳过，尊重关闭提醒的意图。
  /// 必须在书架数据绑定完成后调用（书架为空时检不出更新）。
  Future<void> checkOnStartup() async {
    if (await frequency() == UpdateFreq.off) return;
    await checkInBackground();
  }

  /// 后台定时检查：发现更新时通过 [onUpdatesFound] 通知 UI，并在
  /// 用户开启推送开关时补发系统通知（24h 冷却去重，见 [UpdateNotifier]）。
  Future<void> checkInBackground() async {
    if (_checking) return;
    _checking = true;
    _isCancelled = false;
    try {
      final updated = await checkNow();
      if (updated != null && updated.isNotEmpty) {
        onUpdatesFound?.call(updated);
        await UpdateNotifier.instance.notifyShelfUpdate(updated);
      }
    } finally {
      _checking = false;
    }
  }
}
