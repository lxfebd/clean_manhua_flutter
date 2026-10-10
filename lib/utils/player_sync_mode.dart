/// 播放器同步模式决策（纯函数，可单测）。
///
/// 背景（2026-09-19 重写根治「什么都没开也倍速」）：mpv 的
/// display-resample 恒定 1 倍速依赖 `estimated-display-fps`（edisp），而该
/// 估算在窗口跨屏 / ANGLE / 远程桌面 / 合成器故障时可能读到垃圾值（实测
/// 4211→5512→6706→8922Hz，正常应 60/120/144）。显示时钟错了 mpv 就按错
/// 时钟追帧 → 视频被倍速，且与任何插帧/倍速开关无关。另外无音轨时 mpv
/// 没有音频时钟，display-resample 改用显示刷新率追赶 → 也倍速。
///
/// 因此不硬设某个 sync，而是**探测显示时钟 + 音轨**：任一不可靠就退回
/// `audio` 同步（以音频时钟为基准，恒 1 倍速，永不倍速——宁可丢流畅也
/// 不变速）。墙钟观测（[player_sync_guard.dart] 的 wrate）在诊断循环兜底，
/// 防探测不到的时钟错误；降级态由 [_PlayerPhase] 对应的 `syncDegraded`
/// 传入本决策。
library;

/// 合理的显示刷新率区间：正常屏幕 30~250Hz。低于/高于此区间说明 edisp
/// 是垃圾值（远程桌面/ANGLE/双屏估算错误），display-resample 不可信。
const double kSyncMinDispFps = 30.0;
const double kSyncMaxDispFps = 250.0;

/// 目标刷新率兜底（Windows ANGLE 读不到真实刷新率时锁 60Hz）。
const int kSyncTargetFps = 60;

/// 同步模式选型结果。
class SyncModeDecision {
  const SyncModeDecision({
    required this.mode,
    required this.dispFps,
    required this.hasAudio,
    required this.degraded,
  });

  /// 最终选定的 video-sync 值：'display-resample' 或 'audio'。
  final String mode;

  /// 读到的 estimated-display-fps（0 = 读不到/解析失败）。
  final double dispFps;

  /// 音轨探测结果（aid 非 no 且 audio-params/channels 非空非 0）。
  final bool hasAudio;

  /// 诊断循环墙钟守卫是否已判定显示时钟漂移（强制 audio）。
  final bool degraded;

  bool get usesDisplayResample => mode == 'display-resample';
}

/// 计算同步模式。
///
/// [edispRaw] 是 `estimated-display-fps` 属性读回值（可能为空串/垃圾值）；
/// [aidRaw] 是 `aid` 属性读回值（'no'/空 = 无音轨）；[audioChannelsRaw] 是
/// `audio-params/channels` 读回值（'0'/空/'ERR' = 音频通路未活）。
/// [degraded] 为 true 时无视探测结果直接强制 audio（墙钟守卫已抓现行，
/// 见 [player_sync_guard.dart]；降级态本文件内不自动恢复，切集/重开自然
/// 重置后重新评估）。
SyncModeDecision decideSyncMode({
  required String edispRaw,
  required String? aidRaw,
  required String audioChannelsRaw,
  required bool degraded,
}) {
  final dispFps = double.tryParse(edispRaw) ?? 0;
  final dispOk = dispFps >= kSyncMinDispFps && dispFps <= kSyncMaxDispFps;

  var hasAudio = aidRaw != null && aidRaw != 'no' && !(aidRaw == '0');
  if (hasAudio) {
    final a = audioChannelsRaw;
    hasAudio = a.isNotEmpty && !a.contains('ERR') && a != '0';
  }

  final mode =
      (degraded || !(dispOk && hasAudio)) ? 'audio' : 'display-resample';
  return SyncModeDecision(
    mode: mode,
    dispFps: dispFps,
    hasAudio: hasAudio,
    degraded: degraded,
  );
}
