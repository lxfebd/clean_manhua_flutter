import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../net/local_store.dart';
import '../sources/video_source.dart';
import '../utils/anime4k.dart';
import '../utils/danmaku.dart';
import 'anime_player_page.dart';
import 'widgets/danmaku_overlay.dart';
import 'widgets/player_widgets.dart';

/// 手势类型。
enum _Gesture { none, brightness, volume, seek }

/// 现代化原生播放器。
///
/// 交互参考主流番剧播放器（B 站 / Animeko / NPlayer）：
/// * 左半屏上下滑 → 亮度，右半屏上下滑 → 音量
/// * 横滑 → 拖动进度并实时预览
/// * 长按 → 3x 快速播放，松手复原
/// * 双击左/右 → ±10 秒，双击中间 → 播放/暂停
/// * 全屏锁定、画面比例、倍速、选集、自动下一集、断点续播
/// * Anime4K CNN 超分（多档位）+ mpv 画质增强（去色带 / 高质量缩放核）
class NativePlayerPage extends StatefulWidget {
  final String url;
  final String title;
  final String? cover;

  /// 选集数据（可空）。传入后播放器内可直接切集、自动连播。
  final List<VideoEpisode> episodes;
  final int season;
  final int episode;

  /// 切集时用来解析新的播放直链。
  final Future<String> Function(int season, int episode)? resolveUrl;

  /// 播放源（线路）名称映射：season -> 源名。用于选集里按源分组。
  final Map<int, String>? sourceNames;

  /// 播放进度记忆用的唯一 key，默认用 url。
  final String? historyKey;

  /// 所属数据源 id（VideoSource.id）。有值时观看记录写进书架「动画记录」。
  final String? sourceId;

  /// 番剧 id。与 [sourceId] 一起用于书架续播重新解析播放链。
  final String? videoId;

  const NativePlayerPage({
    super.key,
    required this.url,
    required this.title,
    this.cover,
    this.episodes = const [],
    this.season = 1,
    this.episode = 1,
    this.resolveUrl,
    this.sourceNames,
    this.historyKey,
    this.sourceId,
    this.videoId,
  });

  @override
  State<NativePlayerPage> createState() => _NativePlayerPageState();
}

class _NativePlayerPageState extends State<NativePlayerPage>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription> _subs = [];

  // ── 播放状态 ────────────────────────────────
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  bool _ready = false;
  bool _failed = false;
  String _failMsg = '本地播放内核不可用';
  int _vw = 0, _vh = 0;

  // ── 画质 ────────────────────────────────────
  String _srId = 'off';
  bool _enhance = true;
  bool _srApplying = false;

  /// 最近一次 mpv 报告的着色器错误（无则 null）。
  String? _srFault;

  // ── 播放参数 ────────────────────────────────
  double _speed = 1.0;
  int _fitIndex = 0;
  static const _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill];
  static const _fitNames = ['适应屏幕', '裁剪填充', '拉伸铺满'];

  // ── 界面状态 ────────────────────────────────
  bool _fullscreen = false;
  bool _locked = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _clockTimer;
  String _clock = '';

  // ── 手势 ────────────────────────────────────
  /// 亮度下限。系统亮度可以压到 0，遮罩兜底时不能低于 0.12 否则全黑。
  static const double _minBrightness = 0.0;
  static const double _minMaskBrightness = 0.12;

  /// 长按临时加速的倍率。
  static const double _boostRate = 3.0;

  _Gesture _gesture = _Gesture.none;

  /// 屏幕亮度（0~1）。`_brightnessNative` 为真时代表已接管系统亮度，
  /// 为假时退化成画面遮罩（桌面端 / 无权限时）。
  double _brightness = 1.0;
  bool _brightnessNative = false;

  /// 设备媒体音量（0~1），由 volume_controller 直接读写系统。
  double _volume = 1.0;
  bool _volumeNative = false;
  bool _selfVolumeChange = false;
  StreamSubscription<double>? _volumeSub;

  double _gestureStartValue = 0;
  Duration _seekStart = Duration.zero;
  Duration _seekTarget = Duration.zero;
  Timer? _hudTimer;
  bool _hudVisible = false;
  bool _boosting = false;
  double _speedBeforeBoost = 1.0;
  bool _draggingBar = false;

  // 节流：position 流每秒约 10 次，节流到 5Hz 即可减少重建压力。
  DateTime _lastUiFlush = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pendingFlush = false;

  // ── 选集 ────────────────────────────────────
  late int _curSeason;
  late int _curEpisode;
  bool _switching = false;
  bool _completedHandled = false;

  // ── 续播 ────────────────────────────────────
  Duration? _resumeAt;
  bool _resumeTipVisible = false;
  Timer? _resumeTipTimer;
  int _lastSavedSec = -1;

  // ── 弹幕 ────────────────────────────────────
  List<DanmakuItem> _danmaku = const [];
  DanmakuSettings _danmakuSet = const DanmakuSettings();

  String get _histKey => widget.historyKey ?? widget.url;
  SrPreset get _sr => Anime4KManager.presetById(_srId);

  int get _curIndex => widget.episodes.indexWhere(
      (e) => e.season == _curSeason && e.episode == _curEpisode);

  /// 把扁平的剧集按 [VideoEpisode.season]（播放源/线路）分组，保持源的顺序。
  /// 返回每组：源名（带「第N源」兜底）+ 该源下的剧集。仅当存在多个源时才展示分组头。
  List<({String name, List<VideoEpisode> eps})> get _groupedSeasons {
    final bySeason = <int, List<VideoEpisode>>{};
    for (final e in widget.episodes) {
      (bySeason[e.season] ??= []).add(e);
    }
    final keys = bySeason.keys.toList()..sort();
    return [
      for (final k in keys)
        (
          name: widget.sourceNames?[k] ?? '线路 $k',
          eps: bySeason[k]!,
        ),
    ];
  }

  bool get _multiSource => _groupedSeasons.length > 1;

  bool get _hasPrev => _curIndex > 0 && widget.resolveUrl != null;
  bool get _hasNext =>
      _curIndex >= 0 &&
      _curIndex < widget.episodes.length - 1 &&
      widget.resolveUrl != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _curSeason = widget.season;
    _curEpisode = widget.episode;
    _tickClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 20), (_) => _tickClock());
    _initSystemLevels();
    _boot();
    _loadDanmaku();
  }

  /// 加载弹幕设置并拉取当前集的弹幕（在线失败静默，不影响播放）。
  Future<void> _loadDanmaku() async {
    final set = await LocalStore.danmakuSettings();
    if (!mounted) return;
    setState(() => _danmakuSet = set);
    final items = await DanmakuFetcher.fetch(widget.title, _curEpisode);
    if (!mounted) return;
    setState(() {
      _danmaku = items;
    });
  }

  /// 切换弹幕开关（同步持久化）。
  Future<void> _toggleDanmaku() async {
    final v = !_danmakuSet.on;
    setState(() => _danmakuSet = _danmakuSet.copyWith(on: v));
    await LocalStore.setDanmaku(_danmakuSet);
    _toast(v ? '已开启弹幕' : '已关闭弹幕');
  }

  /// 接管设备音量与屏幕亮度。
  ///
  /// 任一平台不支持（桌面端、缺权限）就自动退回：音量退回播放器内部音量，
  /// 亮度退回画面遮罩，功能不会因为插件缺失而整个失效。
  Future<void> _initSystemLevels() async {
    // ── 设备音量 ──
    try {
      final vc = VolumeController.instance;
      // 关掉系统那条原生音量提示，避免和播放器自己的 HUD 叠在一起
      vc.showSystemUI = false;
      final v = await vc.getVolume();
      _volumeNative = true;
      if (mounted) setState(() => _volume = v.clamp(0.0, 1.0));
      // 监听物理音量键，外部改动也要同步到 HUD
      _volumeSub = vc.addListener((v) {
        if (!mounted) return;
        setState(() => _volume = v.clamp(0.0, 1.0));
        // 自己滑动引起的回调不弹 HUD，只有按物理键才提示
        if (!_selfVolumeChange && !_locked) {
          _showHud(_Gesture.volume, keep: false);
        }
      }, fetchInitialVolume: false);
    } catch (_) {
      _volumeNative = false;
    }

    // ── 屏幕亮度 ──
    try {
      final sb = ScreenBrightness.instance;
      final b = await sb.application;
      _brightnessNative = true;
      if (mounted) setState(() => _brightness = b.clamp(0.0, 1.0));
    } catch (_) {
      _brightnessNative = false;
      if (mounted) setState(() => _brightness = 1.0);
    }
  }

  Future<void> _applyBrightness(double v) async {
    if (!_brightnessNative) return;
    try {
      await ScreenBrightness.instance.setApplicationScreenBrightness(v);
    } catch (_) {
      _brightnessNative = false;
    }
  }

  Future<void> _applyVolume(double v) async {
    if (_volumeNative) {
      _selfVolumeChange = true;
      try {
        await VolumeController.instance.setVolume(v);
      } catch (_) {
        _volumeNative = false;
      }
      // 平台事件是异步回来的，稍等一拍再放开抑制标记
      Future.delayed(const Duration(milliseconds: 250), () {
        _selfVolumeChange = false;
      });
    } else {
      _player?.setVolume(v * 100);
    }
  }

  void _tickClock() {
    final n = DateTime.now();
    final s = '${n.hour.toString().padLeft(2, '0')}:'
        '${n.minute.toString().padLeft(2, '0')}';
    if (mounted && s != _clock) setState(() => _clock = s);
  }

  /// 把高频 position/buffer 流的 UI 刷新节流到 5Hz（200ms），
  /// 避免每秒数十次 rebuild 拖垮低端机。
  void _scheduleFlush() {
    if (_pendingFlush) return;
    final now = DateTime.now();
    final delta = now.difference(_lastUiFlush).inMilliseconds;
    if (delta >= 200) {
      _lastUiFlush = now;
      if (mounted) setState(() {});
      return;
    }
    _pendingFlush = true;
    Timer(Duration(milliseconds: 200 - delta), () {
      _pendingFlush = false;
      _lastUiFlush = DateTime.now();
      if (mounted) setState(() {});
    });
  }

  Future<void> _boot() async {
    await _loadPrefs();
    if (!mounted) return;
    try {
      final p = Player(configuration: const PlayerConfiguration(
        // 需要收到 shader 编译的 warn 级日志用于失败诊断
        logLevel: MPVLogLevel.warn,
      ));
      _player = p;
      _controller = VideoController(p);
      if (_volumeNative) {
        // 系统音量已接管，播放器内部音量固定拉满，避免两级衰减
        await p.setVolume(100);
      } else {
        _volume = (p.state.volume / 100).clamp(0.0, 1.0);
      }

      _subs.add(p.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }));
      _subs.add(p.stream.position.listen((v) {
        if (!mounted) return;
        _pos = v;
        _maybeSaveProgress(v);
        _scheduleFlush();
      }));
      _subs.add(p.stream.duration.listen((v) {
        if (mounted) setState(() => _dur = v);
      }));
      _subs.add(p.stream.buffer.listen((v) {
        if (!mounted) return;
        _buffer = v;
        _scheduleFlush();
      }));
      _subs.add(p.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }));
      _subs.add(p.stream.width.listen((v) {
        if (mounted && v != null) setState(() => _vw = v);
      }));
      _subs.add(p.stream.height.listen((v) {
        if (mounted && v != null) setState(() => _vh = v);
      }));
      _subs.add(p.stream.completed.listen((v) {
        if (v) _onCompleted();
      }));
      _subs.add(p.stream.error.listen((e) {
        if (mounted && !_ready) {
          setState(() {
            _failed = true;
            _failMsg = '播放失败：$e';
          });
        }
      }));
      // 捕获 mpv 的着色器错误（编译失败会在 error 级日志里出现）
      _subs.add(p.stream.log.listen((log) {
        if (!mounted) return;
        final t = log.text;
        if (t.contains('shader') ||
            t.contains('glsl') ||
            t.contains('Failed to') ||
            t.contains('hwdec') ||
            t.contains('vo=') ||
            t.contains('gpu-context') ||
            t.contains('Using hardware') ||
            t.contains('No hardware') ||
            t.contains('fp32') ||
            t.contains('Texture') ||
            t.contains('scale')) {
          // ignore: avoid_print
          print('MPVLOG[${log.level}] ${t.trim()}');
        }
        if (log.level == 'error' &&
            (t.contains('shader') ||
                t.contains('glsl') ||
                t.contains('Failed to'))) {
          _srFault = t.trim();
        }
      }));

      await _open(widget.url);
    } catch (e) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _open(String url) async {
    final p = _player;
    if (p == null) return;
    try {
      await Anime4KManager.ensureShaders();
      _srFault = null;
      await _applyEnhance();
      await _applySr(silent: true);
      await p.setRate(_speed);
      await p.open(Media(url), play: true);
      // Android 上 VideoController 会在拿到 wid 后把 vo=null→gpu 重建，
      // 提前塞的 glsl-shaders 可能被清掉。等首帧真正渲染完再补挂一次最稳。
      if (_sr.enabled) {
        try {
          await _controller?.waitUntilFirstFrameRendered
              .timeout(const Duration(seconds: 10));
        } catch (_) {}
        await _applySr(silent: true);
      }
      if (mounted) {
        setState(() {
          _ready = true;
          _completedHandled = false;
        });
      }
      await _prepareResume();
      _scheduleHide();
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failMsg = '播放失败：$e';
        });
      }
    }
  }

  // ── 偏好持久化 ──────────────────────────────
  Future<void> _loadPrefs() async {
    try {
      final raw = await LocalStore.readJson('player_prefs');
      if (raw is Map) {
        _srId = (raw['sr'] as String?) ?? 'off';
        if (Anime4KManager.levels.every((e) => e.id != _srId)) _srId = 'off';
        _enhance = (raw['enhance'] as bool?) ?? true;
        _speed = (raw['speed'] as num?)?.toDouble() ?? 1.0;
        _fitIndex = ((raw['fit'] as num?)?.toInt() ?? 0).clamp(0, _fits.length - 1);
        // 仅遮罩兜底模式下才恢复上次亮度；接管了系统亮度就以系统当前值为准
        if (!_brightnessNative) {
          _brightness = ((raw['bright'] as num?)?.toDouble() ?? 1.0)
              .clamp(_minMaskBrightness, 1.0);
        }
      }
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      await LocalStore.writeJson('player_prefs', {
        'sr': _srId,
        'enhance': _enhance,
        'speed': _speed,
        'fit': _fitIndex,
        'bright': _brightness,
      });
    } catch (_) {}
  }

  Future<void> _prepareResume() async {
    try {
      final raw = await LocalStore.readJson('video_progress');
      if (raw is Map) {
        final sec = (raw[_histKey] as num?)?.toInt() ?? 0;
        if (sec > 20 && mounted) {
          setState(() {
            _resumeAt = Duration(seconds: sec);
            _resumeTipVisible = true;
          });
          _resumeTipTimer?.cancel();
          _resumeTipTimer = Timer(const Duration(seconds: 8), () {
            if (mounted) setState(() => _resumeTipVisible = false);
          });
        }
      }
    } catch (_) {}
  }

  void _maybeSaveProgress(Duration v) {
    final sec = v.inSeconds;
    if (sec == _lastSavedSec || sec % 5 != 0 || sec < 5) return;
    _lastSavedSec = sec;
    // 快看完了就清掉续播记录，避免下次进来提示"续播 最后 3 秒"
    final done = _dur > Duration.zero && v >= _dur - const Duration(seconds: 15);
    final ts = DateTime.now().millisecondsSinceEpoch;
    // 结构化观看记录（书架「动画记录」用），看完也保留并标记到结尾。
    final sourceId = widget.sourceId;
    final videoId = widget.videoId;
    if (sourceId != null && videoId != null && sourceId.isNotEmpty) {
      LocalStore.recordVideo(VideoRecord(
        sourceId: sourceId,
        videoId: videoId,
        title: widget.title,
        cover: widget.cover,
        season: _curSeason,
        episode: _curEpisode,
        seconds: done ? _dur.inSeconds : sec,
        duration: _dur.inSeconds,
        timestamp: ts,
      ));
    }
    () async {
      try {
        final raw = await LocalStore.readJson('video_progress');
        final map = <String, dynamic>{};
        if (raw is Map) {
          raw.forEach((k, val) => map['$k'] = val);
        }
        if (done) {
          map.remove(_histKey);
        } else {
          map[_histKey] = sec;
        }
        await LocalStore.writeJson('video_progress', map);
      } catch (_) {}
    }();
  }

  // ── 画质 ────────────────────────────────────
  Future<void> _applyEnhance() async {
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    final props =
        _enhance ? Anime4KManager.enhanceProps : Anime4KManager.enhanceOffProps;
    for (final e in props.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (_) {}
    }
  }

  Future<void> _applySr({bool silent = false}) async {
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    if (!silent) setState(() => _srApplying = true);
    try {
      _srFault = null;
      final list = await Anime4KManager.shaderListFor(_srId);
      // libmpv 对 path-list 选项用 mpv_set_property_string 设置时不会按
      // 逗号/换行拆分（会把整个串当单个文件名）。改用 change-list 命令，
      // 其 value 按平台路径列表分隔符解析：POSIX(Android)=冒号。
      if (list.isEmpty) {
        await native.command(const ['change-list', 'glsl-shaders', 'set', '']);
      } else {
        await native.command([
          'change-list',
          'glsl-shaders',
          'set',
          list.replaceAll(',', ':'),
        ]);
      }
      // 读回属性，确认 mpv 真的接受了这份 shader 列表（对路径回规范化）。
      final back = await native.getProperty('glsl-shaders');
      final applied = (!_sr.enabled && (back.isEmpty)) ||
          (_sr.enabled &&
              back.split(RegExp('[,\\n:]')).where((s) => s.trim().isNotEmpty).isNotEmpty);
      if (!silent && mounted) {
        final fault = _srFault;
        if (!_sr.enabled) {
          _toast('超分已关闭');
        } else if (applied && fault == null) {
          _toast('超分：${_sr.name} 已启用');
        } else {
          _toast('超分未生效：${fault ?? 'mpv 未接受着色器（可能软渲染/vo 不支持）'}');
        }
      }
    } catch (e) {
      if (!silent && mounted) _toast('超分应用失败：$e');
    } finally {
      if (!silent && mounted) setState(() => _srApplying = false);
    }
  }

  void _setSr(String id) {
    setState(() => _srId = id);
    _applySr();
    _savePrefs();
  }

  void _setEnhance(bool v) {
    setState(() => _enhance = v);
    _applyEnhance();
    _savePrefs();
    _toast(v ? '画质增强已开启（去色带 + 高质量缩放）' : '画质增强已关闭');
  }

  // ── 播放控制 ────────────────────────────────
  void _togglePlay() {
    if (_playing) {
      _player?.pause();
    } else {
      _player?.play();
    }
    _bumpControls();
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _player?.setRate(s);
    _savePrefs();
  }

  void _seekTo(Duration d) {
    final target = d < Duration.zero
        ? Duration.zero
        : (_dur > Duration.zero && d > _dur ? _dur : d);
    _player?.seek(target);
    setState(() => _pos = target);
  }

  void _seekBy(int seconds) {
    final from = _pos;
    final target = from + Duration(seconds: seconds);
    setState(() {
      _seekStart = from;
      _seekTarget = target;
    });
    _seekTo(target);
    _showHud(_Gesture.seek, keep: false);
  }

  void _onCompleted() {
    if (_completedHandled) return;
    _completedHandled = true;
    if (mounted) setState(() => _playing = false);
    if (_hasNext) {
      _toast('即将播放下一集…');
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _goRelative(1);
      });
    }
  }

  Future<void> _goRelative(int delta) async {
    final idx = _curIndex;
    if (idx < 0) return;
    final target = idx + delta;
    if (target < 0 || target >= widget.episodes.length) return;
    await _switchTo(widget.episodes[target]);
  }

  Future<void> _switchTo(VideoEpisode ep) async {
    final resolver = widget.resolveUrl;
    if (resolver == null || _switching) return;
    setState(() {
      _switching = true;
      _ready = false;
      _buffering = true;
      _resumeTipVisible = false;
    });
    try {
      final url = await resolver(ep.season, ep.episode);
      if (!mounted) return;
      // 有些源换集后拿到的是网页地址而非直链，此时交回 WebView 播放
      if (!isDirectMediaUrl(url)) {
        _player?.pause();
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => AnimePlayerPage(
            url: url,
            title: widget.title,
            cover: widget.cover,
            episodes: widget.episodes,
            initialSeason: ep.season,
            initialEpisode: ep.episode,
            resolveUrl: widget.resolveUrl,
            sourceNames: widget.sourceNames,
          ),
        ));
        return;
      }
      setState(() {
        _curSeason = ep.season;
        _curEpisode = ep.episode;
        _pos = Duration.zero;
        _dur = Duration.zero;
        _buffer = Duration.zero;
        _lastSavedSec = -1;
      });
      await _open(url);
      // 换集后重新拉取该集弹幕
      setState(() {
        _danmaku = const [];
      });
      _loadDanmaku();
    } catch (e) {
      if (mounted) _toast('切换失败：$e');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _fallbackWeb() {
    _player?.dispose();
    if (mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => AnimePlayerPage(
            url: widget.url, title: widget.title, cover: widget.cover),
      ));
    }
  }

  // ── 控制层显隐 ──────────────────────────────
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && !_draggingBar) {
        setState(() => _showControls = false);
      }
    });
  }

  void _bumpControls() {
    setState(() => _showControls = true);
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1600),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ));
  }

  // ── 全屏 ────────────────────────────────────
  bool get _isLandscape {
    final size = MediaQuery.of(context).size;
    return size.width > size.height;
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    // 全屏状态完全由按钮 (_toggleFullscreen) 驱动，这里不再反向改写 _fullscreen，
    // 否则手动退出全屏时与旋转事件互相打架，会出现「退出后又被拉回全屏 /
    // 变成竖屏全屏、必须按返回键才能恢复」的问题。
    // 仅当处于全屏却被物理转到竖屏时，强制回到横屏，避免出现竖屏全屏的别扭观感。
    if (_fullscreen && !_isLandscape) {
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      _bumpControls();
    }
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      _locked = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
    _bumpControls();
  }

  // ── 手势 ────────────────────────────────────
  void _showHud(_Gesture g, {bool keep = true}) {
    setState(() {
      _gesture = g;
      _hudVisible = true;
    });
    _hudTimer?.cancel();
    if (!keep) {
      _hudTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _hudVisible = false);
      });
    }
  }

  void _hideHud() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _hudVisible = false;
          _gesture = _Gesture.none;
        });
      }
    });
  }

  void _onVerticalStart(DragStartDetails d, Size size) {
    if (_locked) return;
    final left = d.localPosition.dx < size.width / 2;
    _gesture = left ? _Gesture.brightness : _Gesture.volume;
    _gestureStartValue = left ? _brightness : _volume;
    _showHud(_gesture);
  }

  void _onVerticalUpdate(DragUpdateDetails d, Size size) {
    if (_locked || _gesture == _Gesture.none || _gesture == _Gesture.seek) {
      return;
    }
    // 竖屏小窗只有两百来像素高，若按窗口高度换算会灵敏到没法微调，
    // 所以统一以屏幕高度为标尺。
    final refH =
        (_fullscreen ? size.height : MediaQuery.of(context).size.height) * 0.7;
    final delta = -d.primaryDelta! / refH;
    final v = (_gestureStartValue + delta * 1.0);
    if (_gesture == _Gesture.brightness) {
      final lo = _brightnessNative ? _minBrightness : _minMaskBrightness;
      final nv = v.clamp(lo, 1.0);
      setState(() => _brightness = nv);
      _gestureStartValue = nv;
      _applyBrightness(nv);
    } else {
      final nv = v.clamp(0.0, 1.0);
      setState(() => _volume = nv);
      _gestureStartValue = nv;
      _applyVolume(nv);
    }
  }

  void _onVerticalEnd(DragEndDetails d) {
    // 系统亮度由系统自己记忆，只有遮罩兜底模式才需要本地持久化
    if (_gesture == _Gesture.brightness && !_brightnessNative) _savePrefs();
    _hideHud();
  }

  void _onHorizontalStart(DragStartDetails d) {
    if (_locked || _dur <= Duration.zero) return;
    _gesture = _Gesture.seek;
    _seekStart = _pos;
    _seekTarget = _pos;
    _showHud(_Gesture.seek);
  }

  void _onHorizontalUpdate(DragUpdateDetails d, Size size) {
    if (_locked || _gesture != _Gesture.seek) return;
    // 整屏宽 = 视频总时长的 1/4，最多不超过 180 秒，手感更稳
    final span = _dur.inSeconds / 4;
    final maxSpan = span > 180 ? 180.0 : span;
    final deltaSec = d.primaryDelta! / size.width * maxSpan * 2;
    var t = _seekTarget + Duration(milliseconds: (deltaSec * 1000).round());
    if (t < Duration.zero) t = Duration.zero;
    if (t > _dur) t = _dur;
    setState(() => _seekTarget = t);
  }

  void _onHorizontalEnd(DragEndDetails d) {
    if (_gesture == _Gesture.seek) _seekTo(_seekTarget);
    _hideHud();
  }

  void _onLongPressStart() {
    if (_locked || !_playing) return;
    _speedBeforeBoost = _speed;
    setState(() => _boosting = true);
    _player?.setRate(_boostRate);
  }

  void _onLongPressEnd() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    _player?.setRate(_speedBeforeBoost);
  }

  Offset _lastTapPos = Offset.zero;

  void _onDoubleTap(Size size) {
    if (_locked) return;
    final x = _lastTapPos.dx;
    if (x < size.width * 0.35) {
      _seekBy(-10);
    } else if (x > size.width * 0.65) {
      _seekBy(10);
    } else {
      _togglePlay();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _clockTimer?.cancel();
    _resumeTipTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    // 还原系统亮度，否则退出播放器后屏幕会一直保持播放时的亮度
    _volumeSub?.cancel();
    if (_volumeNative) {
      try {
        VolumeController.instance.removeListener();
        VolumeController.instance.showSystemUI = true;
      } catch (_) {}
    }
    if (_brightnessNative) {
      try {
        ScreenBrightness.instance.resetApplicationScreenBrightness();
      } catch (_) {}
    }
    _player?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  // ══════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    if (_failed) return _failedView();
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _fullscreen
            ? _stage()
            : SafeArea(
                bottom: false,
                child: Column(children: [
                  AspectRatio(aspectRatio: 16 / 9, child: _stage()),
                  Expanded(child: _belowPanel()),
                ]),
              ),
      ),
    );
  }

  Widget _failedView() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 56, color: Colors.white38),
            const SizedBox(height: 14),
            Text(_failMsg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 6),
            const Text('可切换为网页播放',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _fallbackWeb,
              icon: const Icon(Icons.language),
              label: const Text('用网页播放'),
            ),
          ]),
        ),
      ),
    );
  }

  /// 视频舞台：画面 + 亮度遮罩 + 手势 + 控制层。
  Widget _stage() {
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final ctl = _controller;
      return ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          Container(color: Colors.black),
          // 首帧出来之前用封面垫底，避免开场一片死黑
          if (!_ready && (widget.cover?.isNotEmpty ?? false))
            Positioned.fill(
              child: Opacity(
                opacity: 0.32,
                child: Image.network(
                  widget.cover!,
                  fit: BoxFit.cover,
                  cacheWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).toInt(),
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          if (ctl != null)
            Video(
              controller: ctl,
              controls: NoVideoControls,
              wakelock: true,
              fit: _fits[_fitIndex],
              // 默认是 low（最近邻），拉伸后很糊；开画质增强时用高质量采样
              filterQuality:
                  _enhance ? FilterQuality.high : FilterQuality.medium,
            ),
          // 弹幕层（在画面之上、手势/控制层之下）
          if (_danmakuSet.on)
            Positioned.fill(
              child: DanmakuOverlay(
                items: _danmaku,
                position: _pos.inMilliseconds / 1000.0,
                settings: _danmakuSet,
              ),
            ),
          // 亮度遮罩：只在拿不到系统亮度控制权时兜底
          if (!_brightnessNative && _brightness < 1.0)
            IgnorePointer(
              child: Container(
                  color: Colors.black.withValues(alpha: 1 - _brightness)),
            ),
          // 手势层
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (_) => _toggleControls(),
              onDoubleTapDown: (d) => _lastTapPos = d.localPosition,
              onDoubleTap: () => _onDoubleTap(size),
              onLongPressStart: (_) => _onLongPressStart(),
              onLongPressEnd: (_) => _onLongPressEnd(),
              onLongPressCancel: _onLongPressEnd,
              onVerticalDragStart: (d) => _onVerticalStart(d, size),
              onVerticalDragUpdate: (d) => _onVerticalUpdate(d, size),
              onVerticalDragEnd: _onVerticalEnd,
              onHorizontalDragStart: _onHorizontalStart,
              onHorizontalDragUpdate: (d) => _onHorizontalUpdate(d, size),
              onHorizontalDragEnd: _onHorizontalEnd,
            ),
          ),
          // 缓冲
          if (_buffering || !_ready || _switching)
            const Center(
              child: SizedBox(
                width: 38,
                height: 38,
                child: CircularProgressIndicator(
                    strokeWidth: 2.6, color: Colors.white),
              ),
            ),
          // 超分角标
          if (_sr.enabled && !_locked)
            Positioned(
              right: 12 +
                  (_fullscreen ? MediaQuery.of(context).viewPadding.right : 0),
              top: _showControls ? (_fullscreen ? 56 : 44) : 10,
              child: AnimatedOpacity(
                opacity: 1,
                duration: const Duration(milliseconds: 200),
                child: SrBadge(
                    label: _srApplying ? '超分启用中…' : 'AI 超分 · ${_sr.name}'),
              ),
            ),
          // 控制层
          if (!_locked)
            AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(fit: StackFit.expand, children: [
                  _topBar(),
                  if (!_buffering && _ready) _centerPlayButton(),
                  _bottomBar(),
                ]),
              ),
            ),
          // 锁定按钮（全屏时才有意义）
          if (_fullscreen && (_showControls || _locked))
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(
                    left: 14 + MediaQuery.of(context).viewPadding.left),
                child: _roundBtn(
                  _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                  () {
                    setState(() => _locked = !_locked);
                    _toast(_locked ? '已锁定，再点解锁' : '已解锁');
                    if (!_locked) _bumpControls();
                  },
                  active: _locked,
                ),
              ),
            ),
          // HUD
          if (_hudVisible) _hud(),
          if (_boosting) const SpeedBoostHud(rate: _boostRate),
          // 续播提示
          if (_resumeTipVisible && _resumeAt != null) _resumeTip(),
        ]),
      );
    });
  }

  Widget _hud() {
    switch (_gesture) {
      case _Gesture.brightness:
        return SideLevelHud(
          left: true,
          icon: _brightness > 0.6
              ? Icons.brightness_high_rounded
              : (_brightness > 0.25
                  ? Icons.brightness_medium_rounded
                  : Icons.brightness_low_rounded),
          value: _brightness,
          tint: const Color(0xFFFFD54F),
        );
      case _Gesture.volume:
        return SideLevelHud(
          left: false,
          icon: _volume <= 0.001
              ? Icons.volume_off_rounded
              : (_volume < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded),
          value: _volume,
        );
      case _Gesture.seek:
        return SeekPreviewHud(
            target: _seekTarget, total: _dur, delta: _seekTarget - _seekStart);
      case _Gesture.none:
        return const SizedBox.shrink();
    }
  }

  Widget _resumeTip() {
    final pad = MediaQuery.of(context).viewPadding;
    return Positioned(
      left: 14 + (_fullscreen ? pad.left : 0),
      // 竖屏底部栏只有一行，气泡不用抬那么高
      bottom: _showControls ? (_fullscreen ? 100 : 60) : 20,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            _seekTo(_resumeAt!);
            setState(() => _resumeTipVisible = false);
            _toast('已跳转到 ${fmtDuration(_resumeAt!)}');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xCC000000),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: PlayerColors.accent.withValues(alpha: 0.7)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.history_rounded,
                  size: 16, color: PlayerColors.accent),
              const SizedBox(width: 6),
              Text('上次看到 ${fmtDuration(_resumeAt!)}，点击续播',
                  style: const TextStyle(color: Colors.white, fontSize: 12.5)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final pad = MediaQuery.of(context).viewPadding;
    final sideL = _fullscreen ? (pad.left > 0 ? pad.left + 2 : 10.0) : 2.0;
    final sideR = _fullscreen ? (pad.right > 0 ? pad.right + 2 : 12.0) : 6.0;
    final top = _fullscreen ? 8.0 : 2.0;
    // 竖屏小窗高度有限，渐变拖尾要短一些，否则半个画面都是黑纱
    final bottomFade = _fullscreen ? 26.0 : 16.0;
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        padding: EdgeInsets.fromLTRB(sideL, top, sideR, bottomFade),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.0, 0.65, 1.0],
              colors: [
                Color(0xCC000000),
                Color(0x59000000),
                Color(0x00000000)
              ]),
        ),
        child: Row(children: [
          _barBtn(Icons.arrow_back_ios_new_rounded, () {
            if (_fullscreen) {
              _toggleFullscreen();
            } else {
              Navigator.maybePop(context);
            }
          }),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: _fullscreen ? 14.5 : 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                // 竖屏下方面板里已经写了集数，顶部就不重复了
                if (_fullscreen && widget.episodes.isNotEmpty)
                  Text(_epLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white60)),
              ],
            ),
          ),
          if (_fullscreen) ...[
            Text(_clock,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
          ],
          // 弹幕开关（竖屏小窗也显示，方便快速开/关）
          _barBtn(
            _danmakuSet.on ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
            _toggleDanmaku,
            active: _danmakuSet.on,
          ),
          const SizedBox(width: 2),
          _barBtn(Icons.more_vert_rounded, _showMorePanel),
        ]),
      ),
    );
  }

  String _epLabel() {
    final i = _curIndex;
    if (i >= 0) {
      final t = widget.episodes[i].title;
      return t.isEmpty ? '第 $_curEpisode 集' : t;
    }
    return '第 $_curEpisode 集';
  }

  Widget _centerPlayButton() {
    // 竖屏底部已有播放键，中央只在暂停时补一个大点击目标，避免遮画面
    if (!_fullscreen && _playing) return const SizedBox.shrink();
    final d = _fullscreen ? 60.0 : 50.0;
    return Center(
      child: GestureDetector(
        onTap: _togglePlay,
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 36),
        ),
      ),
    );
  }

  /// 竖屏小窗底部：单行 —— 播放键 / 时间 / 进度条 / 全屏。
  ///
  /// 16:9 小窗只有两百来像素高，塞全屏那套两行控制条会占掉近一半画面，
  /// 所以倍速、超分、选集这些都下放到视频下方的面板里。
  Widget _bottomBarCompact() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.fromLTRB(2, 26, 6, 2),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: [0.0, 0.6, 1.0],
              colors: [
                Color(0xD9000000),
                Color(0x66000000),
                Color(0x00000000)
              ]),
        ),
        child: SizedBox(
          height: 38,
          child: Row(children: [
            _barBtn(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                _togglePlay),
            Text(
              '${fmtDuration(_pos)} / ${fmtDuration(_dur)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PlayerProgressBar(
                position: _pos,
                duration: _dur,
                buffered: _buffer,
                onSeek: _seekTo,
                onDragStateChanged: (v) {
                  setState(() => _draggingBar = v);
                  if (!v) _scheduleHide();
                },
                onDragUpdate: (t) {
                  setState(() {
                    _seekStart = _pos;
                    _seekTarget = t;
                  });
                  _showHud(_Gesture.seek);
                },
              ),
            ),
            const SizedBox(width: 4),
            _barBtn(Icons.fullscreen_rounded, _toggleFullscreen),
          ]),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    if (!_fullscreen) return _bottomBarCompact();
    // 横屏时要避开刘海/挖孔与底部手势条，否则按钮会被系统 UI 压住
    final pad = MediaQuery.of(context).viewPadding;
    final sideL = pad.left > 0 ? pad.left + 4 : 16.0;
    final sideR = pad.right > 0 ? pad.right + 4 : 16.0;
    final bottom = pad.bottom > 0 ? 12.0 : 8.0;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: EdgeInsets.fromLTRB(sideL, 28, sideR, bottom),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: [0.0, 0.6, 1.0],
              colors: [
                Color(0xE6000000),
                Color(0x73000000),
                Color(0x00000000)
              ]),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const SizedBox(width: 4),
            _timeText(_pos, Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: PlayerProgressBar(
                position: _pos,
                duration: _dur,
                buffered: _buffer,
                onSeek: _seekTo,
                onDragStateChanged: (v) {
                  setState(() => _draggingBar = v);
                  if (!v) _scheduleHide();
                },
                onDragUpdate: (t) {
                  setState(() {
                    _seekStart = _pos;
                    _seekTarget = t;
                  });
                  _showHud(_Gesture.seek);
                },
              ),
            ),
            const SizedBox(width: 10),
            _timeText(_dur, Colors.white60),
            const SizedBox(width: 4),
          ]),
          const SizedBox(height: 4),
          SizedBox(
            height: 40,
            child: Row(children: [
              _barBtn(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  _togglePlay),
              if (widget.episodes.length > 1) ...[
                _barBtn(Icons.skip_previous_rounded,
                    _hasPrev ? () => _goRelative(-1) : null),
                _barBtn(Icons.skip_next_rounded,
                    _hasNext ? () => _goRelative(1) : null),
              ],
              const Spacer(),
              _textBtn('${_trimSpeed(_speed)}x', _showSpeedPanel,
                  icon: Icons.speed_rounded),
              _textBtn(_sr.enabled ? _sr.name : '超分', _showSrPanel,
                  icon: Icons.auto_awesome_rounded, active: _sr.enabled),
              _textBtn(_fitNames[_fitIndex], _showFitPanel,
                  icon: Icons.aspect_ratio_rounded, active: _fitIndex != 0),
              if (widget.episodes.isNotEmpty)
                _textBtn('选集', _showEpisodePanel,
                    icon: Icons.playlist_play_rounded),
              _barBtn(Icons.fullscreen_exit_rounded, _toggleFullscreen),
            ]),
          ),
        ]),
      ),
    );
  }

  static String _trimSpeed(double s) =>
      s == s.roundToDouble() ? s.toStringAsFixed(1) : s.toString();

  /// 定宽时间文本，避免秒数进位时把进度条挤得左右抖动。
  Widget _timeText(Duration d, Color color) {
    return SizedBox(
      width: _dur.inHours > 0 ? 56 : 40,
      child: Text(
        fmtDuration(d),
        textAlign: TextAlign.center,
        maxLines: 1,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  /// 紧凑图标按钮：固定 42x40 热区，图标严格居中，禁用态自动变灰。
  Widget _barBtn(IconData icon, VoidCallback? onTap, {bool active = false}) {
    final color = onTap == null
        ? Colors.white24
        : (active ? PlayerColors.sr : Colors.white);
    return SizedBox(
      width: 42,
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Center(child: Icon(icon, size: 22, color: color)),
        ),
      ),
    );
  }

  /// 图标 + 文字的组合按钮，只在全屏下使用。
  Widget _textBtn(String text, VoidCallback onTap,
      {bool active = false, IconData? icon}) {
    final color = active ? PlayerColors.sr : Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.center,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 5),
            ],
            Text(text,
                maxLines: 1,
                style: TextStyle(
                    color: color,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 20, color: active ? PlayerColors.accent : Colors.white),
      ),
    );
  }

  // ══ 竖屏下方面板 ══════════════════════════════
  Widget _belowPanel() {
    final scheme = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    final multi = widget.episodes.length > 1 && widget.resolveUrl != null;
    return Container(
      color: scheme.surface,
      child: ListView(
        padding: EdgeInsets.fromLTRB(14, 14, 14, 24 + bottomPad),
        children: [
          Text(widget.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (widget.episodes.isNotEmpty) _metaChip(scheme, _epLabel()),
            if (_vw > 0 && _vh > 0)
              _metaChip(scheme, '$_vw×$_vh', icon: Icons.hd_rounded),
            if (_speed != 1.0)
              _metaChip(scheme, '${_trimSpeed(_speed)}x',
                  icon: Icons.speed_rounded),
            if (_sr.enabled)
              _metaChip(scheme, _sr.name,
                  icon: Icons.auto_awesome_rounded, highlight: true),
          ]),
          if (multi) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _stepBtn(scheme, Icons.skip_previous_rounded, '上一集',
                    _hasPrev ? () => _goRelative(-1) : null),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _stepBtn(scheme, Icons.skip_next_rounded, '下一集',
                    _hasNext ? () => _goRelative(1) : null),
              ),
            ]),
          ],
          const SizedBox(height: 14),
          _srCard(scheme),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _miniCard(scheme, Icons.speed_rounded, '倍速',
                    '${_trimSpeed(_speed)}x', _showSpeedPanel)),
            const SizedBox(width: 10),
            Expanded(
                child: _miniCard(scheme, Icons.aspect_ratio_rounded, '画面',
                    _fitNames[_fitIndex], _showFitPanel)),
            const SizedBox(width: 10),
            Expanded(
                child: _miniCard(
                    scheme,
                    Icons.tune_rounded,
                    '画质增强',
                    _enhance ? '已开启' : '已关闭',
                    () => _setEnhance(!_enhance),
                    active: _enhance)),
          ]),
          if (widget.episodes.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(children: [
              Text('选集',
                  style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('共 ${widget.episodes.length} 集',
                  style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.5),
                      fontSize: 12)),
              const Spacer(),
              if (widget.episodes.length > _gridLimit)
                GestureDetector(
                  onTap: _showEpisodePanel,
                  child: Row(children: [
                    Text('全部',
                        style: TextStyle(
                            color: PlayerColors.accent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                    const Icon(Icons.chevron_right_rounded,
                        size: 18, color: PlayerColors.accent),
                  ]),
                ),
            ]),
            const SizedBox(height: 10),
            _episodeGrid(scheme),
          ],
        ],
      ),
    );
  }

  Widget _srCard(ColorScheme scheme) {
    final on = _sr.enabled;
    return InkWell(
      onTap: _showSrPanel,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: on
              ? LinearGradient(colors: [
                  PlayerColors.sr.withValues(alpha: 0.20),
                  PlayerColors.sr.withValues(alpha: 0.05),
                ])
              : null,
          color: on ? null : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          border: Border.all(
              color: on
                  ? PlayerColors.sr.withValues(alpha: 0.55)
                  : scheme.outlineVariant),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: on
                  ? PlayerColors.sr.withValues(alpha: 0.22)
                  : scheme.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.auto_awesome,
                size: 20,
                color: on
                    ? PlayerColors.sr
                    : scheme.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('Anime4K 超分',
                        style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: on
                            ? PlayerColors.sr.withValues(alpha: 0.2)
                            : scheme.onSurface.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(_sr.name,
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: on
                                  ? PlayerColors.sr
                                  : scheme.onSurface.withValues(alpha: 0.6))),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(_sr.desc,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color: scheme.onSurface.withValues(alpha: 0.6))),
                ]),
          ),
          Icon(Icons.chevron_right_rounded,
              color: scheme.onSurface.withValues(alpha: 0.4)),
        ]),
      ),
    );
  }

  /// 竖屏面板里的元信息小标签。
  Widget _metaChip(ColorScheme scheme, String text,
      {IconData? icon, bool highlight = false}) {
    final fg = highlight
        ? PlayerColors.sr
        : scheme.onSurface.withValues(alpha: 0.62);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight
            ? PlayerColors.sr.withValues(alpha: 0.12)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
        ],
        Text(text,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }

  /// 上一集 / 下一集按钮，禁用态自动变灰。
  Widget _stepBtn(
      ColorScheme scheme, IconData icon, String label, VoidCallback? onTap) {
    final on = onTap != null;
    final fg = on
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.3);
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: on ? 0.55 : 0.25),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 40,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
          ]),
        ),
      ),
    );
  }

  Widget _miniCard(ColorScheme scheme, IconData icon, String label,
      String value, VoidCallback onTap,
      {bool active = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          border: Border.all(
              color: active
                  ? PlayerColors.sr.withValues(alpha: 0.5)
                  : Colors.transparent),
        ),
        child: Column(children: [
          Icon(icon,
              size: 19,
              color: active
                  ? PlayerColors.sr
                  : scheme.onSurface.withValues(alpha: 0.7)),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.55))),
          const SizedBox(height: 2),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: active ? PlayerColors.sr : scheme.onSurface)),
        ]),
      ),
    );
  }

  /// 竖屏面板里直接铺开的最大集数，超出的走「全部」面板，
  /// 否则几百集的长番一次性建几百个 Widget 会明显掉帧。
  static const int _gridLimit = 40;

  /// 单个选集方块（竖屏面板与全屏面板复用）。
  Widget _episodeTile(ColorScheme scheme, VideoEpisode e) {
    final cur = e.season == _curSeason && e.episode == _curEpisode;
    return InkWell(
      onTap: widget.resolveUrl == null || cur ? null : () => _switchTo(e),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 54),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: cur
              ? PlayerColors.accent.withValues(alpha: 0.15)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: cur ? PlayerColors.accent : Colors.transparent),
        ),
        child: Text(
          e.title.isEmpty ? '${e.episode}' : e.title,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: cur ? FontWeight.w700 : FontWeight.w500,
            color: cur ? PlayerColors.accent : scheme.onSurface,
          ),
        ),
      ),
    );
  }

  /// 分组头：源名 + 该源集数（仅多源时显示）。
  Widget _groupHeader(ColorScheme scheme, String name, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(children: [
        Icon(Icons.playlist_play_rounded,
            size: 15, color: scheme.onSurface.withValues(alpha: 0.5)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ),
        Text('$count 集',
            style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.5),
                fontSize: 11.5)),
      ]),
    );
  }

  Widget _episodeGrid(ColorScheme scheme) {
    final groups = _groupedSeasons;
    final children = <Widget>[];
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      if (_multiSource) {
        children.add(_groupHeader(scheme, g.name, g.eps.length));
      }
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: g.eps.map((e) => _episodeTile(scheme, e)).toList(),
      ));
      if (gi < groups.length - 1) {
        children.add(const SizedBox(height: 12));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ══ 面板 ══════════════════════════════════════
  void _showSrPanel() {
    _hideTimer?.cancel();
    showPlayerPanel(
      context: context,
      title: 'Anime4K 超分',
      fromRight: _fullscreen,
      width: 340,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ...Anime4KManager.levels.map((p) => PanelOptionTile(
                  title: p.name,
                  subtitle: p.desc,
                  selected: p.id == _srId,
                  trailing: p.cost > 0 ? CostBar(cost: p.cost) : null,
                  onTap: () {
                    _setSr(p.id);
                    setSheet(() {});
                  },
                )),
            const SizedBox(height: 6),
            const Divider(color: Colors.white12, height: 18),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _enhance,
              activeColor: PlayerColors.sr,
              title: const Text('画质增强',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              subtitle: const Text('去色带 + 高质量缩放核，开销极小',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
              onChanged: (v) {
                _setEnhance(v);
                setSheet(() {});
              },
            ),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.info_outline_rounded,
                  size: 13, color: Colors.white30),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _vw > 0
                      ? '当前片源 ${_vw}x$_vh，低于 1080p 时超分收益最明显'
                      : '超分对 720p 及以下片源提升最明显；卡顿请降档',
                  style: const TextStyle(
                      color: Colors.white30, fontSize: 10.5, height: 1.3),
                ),
              ),
            ]),
          ]),
        );
      }),
    ).then((_) => _scheduleHide());
  }

  void _showSpeedPanel() {
    _hideTimer?.cancel();
    showPlayerPanel(
      context: context,
      title: '播放速度',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ...speeds.map((s) => PanelOptionTile(
                  title: '${_trimSpeed(s)}x',
                  subtitle: s == 1.0 ? '正常速度' : null,
                  selected: _speed == s,
                  onTap: () {
                    _setSpeed(s);
                    setSheet(() {});
                  },
                )),
            const SizedBox(height: 6),
            const Text('提示：画面上长按可临时 3x 快进',
                style: TextStyle(color: Colors.white30, fontSize: 11)),
          ]),
        );
      }),
    ).then((_) => _scheduleHide());
  }

  void _showFitPanel() {
    _hideTimer?.cancel();
    showPlayerPanel(
      context: context,
      title: '画面比例',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < _fitNames.length; i++)
            PanelOptionTile(
              title: _fitNames[i],
              subtitle: const ['保留全部画面，可能有黑边', '铺满屏幕，会裁掉边缘', '强制拉伸，可能变形'][i],
              selected: _fitIndex == i,
              onTap: () {
                setState(() => _fitIndex = i);
                _savePrefs();
                setSheet(() {});
              },
            ),
        ]);
      }),
    ).then((_) => _scheduleHide());
  }

  void _showEpisodePanel() {
    if (widget.episodes.isEmpty) return;
    _hideTimer?.cancel();
    final groups = _groupedSeasons;
    showPlayerPanel(
      context: context,
      title: '选集（共 ${widget.episodes.length} 集）',
      fromRight: _fullscreen,
      width: 360,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final children = <Widget>[];
        for (final g in groups) {
          if (_multiSource) {
            children.add(Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Row(children: [
                const Icon(Icons.playlist_play_rounded,
                    size: 15, color: Colors.white54),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                Text('${g.eps.length} 集',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11.5)),
              ]),
            ));
          }
          children.add(Wrap(
            spacing: 8,
            runSpacing: 8,
            children: g.eps.map((e) {
              final cur = e.season == _curSeason && e.episode == _curEpisode;
              return InkWell(
                onTap: widget.resolveUrl == null
                    ? null
                    : () {
                        Navigator.of(ctx).pop();
                        if (!cur) _switchTo(e);
                      },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 56),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: cur
                        ? PlayerColors.accent.withValues(alpha: 0.18)
                        : Colors.white10,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: cur ? PlayerColors.accent : Colors.transparent),
                  ),
                  child: Text(
                    e.title.isEmpty ? '${e.episode}' : e.title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: cur ? FontWeight.w700 : FontWeight.w500,
                      color: cur ? PlayerColors.accent : Colors.white,
                    ),
                  ),
                ),
              );
            }).toList(),
          ));
          children.add(const SizedBox(height: 10));
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }),
    ).then((_) => _scheduleHide());
  }

  void _showMorePanel() {
    _hideTimer?.cancel();
    showPlayerPanel(
      context: context,
      title: '更多设置',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            PanelOptionTile(
              title: '画面比例',
              subtitle: _fitNames[_fitIndex],
              selected: false,
              onTap: () {
                Navigator.of(ctx).pop();
                _showFitPanel();
              },
            ),
            PanelOptionTile(
              title: '超分与画质',
              subtitle: '${_sr.name}${_enhance ? ' · 画质增强开' : ''}',
              selected: false,
              onTap: () {
                Navigator.of(ctx).pop();
                _showSrPanel();
              },
            ),
            PanelOptionTile(
              title: '用网页播放',
              subtitle: '当前直链播放异常时可切换',
              selected: false,
              onTap: () {
                Navigator.of(ctx).pop();
                _fallbackWeb();
              },
            ),
            const Divider(color: Colors.white12, height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '片源信息\n'
                '分辨率：${_vw > 0 ? '${_vw}x$_vh' : '获取中'}\n'
                '时长：${fmtDuration(_dur)}\n'
                '手势：左右滑动进度 · 左上下亮度 · 右上下音量 · 长按 3x',
                style: const TextStyle(
                    color: Colors.white38, fontSize: 11, height: 1.6),
              ),
            ),
          ]),
        );
      }),
    ).then((_) => _scheduleHide());
  }
}
