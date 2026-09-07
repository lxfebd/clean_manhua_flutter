import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../net/local_store.dart';
import '../../services/player_registry.dart';
import 'player_widgets.dart';

/// 画中画迷你播放器：承接全屏播放器移交过来的 [Player] 实例，
/// 以悬浮小窗形式继续播放，让用户读小说/逛书架时"听+瞄"番剧不中断。
///
/// 生命周期归属 MainShell 底部浮层管理：
/// - [handoff] 由 NativePlayerPage 最小化时写入 [PlayerRegistry]，本组件只读展示；
///   关闭走 [onClose]（宿主调 [PlayerRegistry.retire] 释放 Player）。
/// - 点击小窗 → [onResume]（宿主取回 Player 并重新进入原生播放页）。
/// - 播放进度照常写入 LocalStore（video_progress），小窗期间观看不中断记忆。
class MiniPlayer extends StatefulWidget {
  final PlayerHandoff handoff;
  final VoidCallback? onResume;
  final VoidCallback? onClose;
  const MiniPlayer({
    super.key,
    required this.handoff,
    this.onResume,
    this.onClose,
  });

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final List<StreamSubscription> _subs = [];
  VideoController? _controller;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _dragSeek = false;
  double _dragRatio = 0;
  int _lastSaveSec = -1;

  Player get _player => widget.handoff.player;

  @override
  void initState() {
    super.initState();
    final p = _player;
    _controller = VideoController(p);
    _playing = p.state.playing;
    _pos = p.state.position;
    _dur = p.state.duration;
    _subs.add(p.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
    _subs.add(p.stream.position.listen((v) {
      if (!mounted) return;
      setState(() => _pos = v);
      _maybeSave(v);
    }));
    _subs.add(p.stream.duration.listen((v) {
      if (mounted) setState(() => _dur = v);
    }));
    _subs.add(p.stream.buffer.listen((v) {
      if (mounted) setState(() => _buffer = v);
    }));
  }

  void _maybeSave(Duration v) {
    final sec = v.inSeconds;
    if (sec == _lastSaveSec || sec % 5 != 0 || sec < 5) return;
    _lastSaveSec = sec;
    final h = widget.handoff;
    final done = _dur > Duration.zero && v >= _dur - const Duration(seconds: 15);
    final sourceId = h.sourceId;
    final videoId = h.videoId;
    if (sourceId != null && videoId != null && sourceId.isNotEmpty) {
      LocalStore.recordVideo(VideoRecord(
        sourceId: sourceId,
        videoId: videoId,
        title: h.title,
        cover: h.cover,
        season: h.season,
        episode: h.episode,
        seconds: done ? _dur.inSeconds : sec,
        duration: _dur.inSeconds,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    () async {
      try {
        final raw = await LocalStore.readJson('video_progress');
        final map = <String, dynamic>{};
        if (raw is Map) {
          raw.forEach((k, val) => map['$k'] = val);
        }
        if (done && h.historyKey != null) {
          map.remove(h.historyKey);
        } else if (h.historyKey != null) {
          map[h.historyKey!] = sec;
        }
        await LocalStore.writeJson('video_progress', map);
      } catch (e) {
        debugPrint('save mini video progress failed: $e');
      }
    }();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = _controller;
    return Material(
      color: const Color(0xF0141418),
      elevation: 12,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onResume,
        child: SizedBox(
          width: 264,
          height: 176,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ctl != null)
                Video(
                  controller: ctl,
                  controls: NoVideoControls,
                  wakelock: false,
                  fit: BoxFit.contain,
                )
              else
                Center(
                  child: Icon(Icons.movie_rounded,
                      size: 40, color: Colors.white24),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 24, 6, 6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        stops: [0.0, 0.7, 1.0],
                        colors: [
                          Color(0xD9000000),
                          Color(0x66000000),
                          Color(0x00000000)
                        ]),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        widget.handoff.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                      icon: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        final p = _player;
                        p.state.playing ? p.pause() : p.play();
                      },
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 36),
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70),
                      onPressed: widget.onClose,
                    ),
                  ]),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 2,
                child: PlayerProgressBar(
                  position: _dragSeek
                      ? Duration(
                          milliseconds: (_dragRatio * _dur.inMilliseconds)
                              .round())
                      : _pos,
                  duration: _dur,
                  buffered: _buffer,
                  onSeek: (t) {
                    final p = _player;
                    p.seek(t);
                    if (!p.state.playing) p.play();
                  },
                  onDragStateChanged: (v) {
                    setState(() => _dragSeek = v);
                  },
                  onDragUpdate: (t) {
                    setState(() {
                      _dragSeek = true;
                      if (_dur.inMilliseconds > 0) {
                        _dragRatio = t.inMilliseconds / _dur.inMilliseconds;
                      }
                    });
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}