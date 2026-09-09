import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../sources/video_source.dart';

/// 画中画播放器全局登记：全屏播放器与迷你小窗之间的 Player 交接门户。
///
/// 所有权契约：
/// - 播放页最小化时调用 [publish]，把 Player + 元数据交给迷你播放器持有；
///   迷你小窗关闭时调用 [retire] 释放 Player。
/// - 迷你小窗点击"继续观看"时调用 [resumePlayer] 取回：
///   新的 NativePlayerPage 不再新建 Player，而是接管已持有的实例继续播放
///   （通过 [PlayerHandoff] 一次性携带选集/解析器，页面可完整重建）。
///
/// 同一份 Player 引用全程流转：交还用 publish，取回用 resumePlayer，
/// 状态回调（playing/position/duration…）由双方各自订阅，互不写死。
class PlayerRegistry {
  PlayerRegistry._();

  static final ValueNotifier<PlayerHandoff?> notifier = ValueNotifier(null);

  /// 已经登记的小窗（无则 null）。
  static PlayerHandoff? get current => notifier.value;

  static bool get active => notifier.value != null;

  /// 播放页最小化 → 移交给迷你播放器。
  static void publish(PlayerHandoff handoff) {
    // 覆盖旧登记前先停掉旧小窗的 Player，否则新播放器接管时
    // 旧小窗仍在后台出声（双 Player 叠音）。
    _stopAndRelease();
    notifier.value = handoff;
  }

  /// 迷你小窗关闭 → 彻底释放 Player。
  static void retire() {
    _stopAndRelease();
  }

  /// 小窗点击"继续观看" → 取回（所有权回到播放页）。
  static PlayerHandoff? resumePlayer() {
    final handoff = notifier.value;
    notifier.value = null;
    return handoff;
  }

  /// 停声 + 释放当前登记的 Player（若存在）。先 pause 止血再 dispose，
  /// 避免 dispose 前最后一帧仍输出音频。
  static void _stopAndRelease() {
    final handoff = notifier.value;
    if (handoff == null) return;
    notifier.value = null;
    try {
      final p = handoff.player;
      if (p.state.playing) p.pause();
      p.dispose();
    } catch (_) {}
  }
}

/// 一次画中画交接的数据载体。
@immutable
class PlayerHandoff {
  final Player player;
  final String url;
  final String title;
  final String? cover;
  final Duration position;
  final double speed;
  final int season;
  final int episode;

  /// 选集与解析器快照：重建播放页时原样带回，保证切集/连播可用。
  final List<VideoEpisode> episodes;
  final Map<int, String>? sourceNames;
  final Future<String> Function(int season, int episode)? resolveUrl;
  final String? sourceId;
  final String? videoId;
  final String? historyKey;

  final int volume;
  final bool muted;

  const PlayerHandoff({
    required this.player,
    required this.url,
    required this.title,
    required this.episodes,
    this.cover,
    this.position = Duration.zero,
    this.speed = 1.0,
    this.season = 1,
    this.episode = 1,
    this.sourceNames,
    this.resolveUrl,
    this.sourceId,
    this.videoId,
    this.historyKey,
    this.volume = 100,
    this.muted = false,
  });
}