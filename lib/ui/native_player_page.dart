import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../net/error_logger.dart';
import '../net/http_client.dart' show Net;
import '../net/local_store.dart';
import '../net/subtitle_srt.dart';
import '../net/video_download_manager.dart';
import '../services/player_registry.dart';
import '../sources/video_source.dart';
import '../utils/anime4k.dart';
import '../utils/danmaku.dart';
import '../utils/desktop_fullscreen.dart';
import '../utils/pip_channel.dart';
import 'anime_player_page.dart';
import 'responsive.dart';
import 'widgets/app_toast.dart';
import 'widgets/danmaku_overlay.dart';
import 'widgets/player_widgets.dart';
import 'widgets/subtitle_overlay.dart';

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

  /// 剧情简介（网页通道的 AnimePlayerPage 下面板展示）。
  final String? description;

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

  /// 画中画恢复：由迷你播放器取回的 [PlayerHandoff]，播放器直接接管该
  /// Player 继续播放（不新建），实现"全屏 → 小窗 → 全屏"无缝续播。
  final PlayerHandoff? take;

  const NativePlayerPage({
    super.key,
    required this.url,
    required this.title,
    this.cover,
    this.description,
    this.episodes = const [],
    this.season = 1,
    this.episode = 1,
    this.resolveUrl,
    this.sourceNames,
    this.historyKey,
    this.sourceId,
    this.videoId,
    this.take,
  });

  @override
  State<NativePlayerPage> createState() => _NativePlayerPageState();
}

class _NativePlayerPageState extends State<NativePlayerPage>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription> _subs = [];

  /// 平板分栏右侧控制面板宽度（与 anime_player_page.dart 统一）。
  static const double _panelWidth = kPlayerPanelWidth;

  /// 控制面板宽度：大屏（>=1200dp）加宽 80dp 容纳更多控件，窄平板保持默认。
  static double _controlPanelWidth(BuildContext context) =>
      Responsive.isLarge(context) ? _panelWidth + 80 : _panelWidth;

  // ── 播放状态 ────────────────────────────────
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  bool _ready = false;
  bool _failed = false;
  bool _retrying = false;
  String _failMsg = '本地播放内核不可用';
  // 切集失败后记录失败目标集：错误页「重试/用网页播放」以此为准，
  // 而不是 widget.url（初始集）——否则重试会开回第一集。
  VideoEpisode? _pendingRetryEp;
  int _vw = 0, _vh = 0;
  // ── 真实渲染输出信息（每 2 秒采样自 mpv，非硬编码）─────
  /// 渲染输出分辨率 = mpv `dwidth`/`dheight`（VO 真正绘制到屏幕上的尺寸）。
  /// ⚠️ 2026-09-14 修正口径：**不要**用 `video-out-params` 当输出尺寸——
  /// Anime4K 跑在 VO 着色器阶段，位于视频滤镜链之后，`video-out-params`
  /// 反映的是滤镜链输出，即使超分正常工作也永远等于源尺寸，会把
  /// 「超分生效」误判成「没生效」。`dwidth` 才是 VO 侧的实际尺寸。
  /// `video-out-params` 仍读，但只写进诊断日志（vop=）供对照，不上界面。
  /// 0 表示尚无输出。
  int _outW = 0, _outH = 0;
  /// x2 放大链是否具备执行条件（见 [Anime4KManager.srChainEligible]）。
  /// null = 尺寸未知，无法判定（界面不显示该结论，避免误报）。
  bool? _srEligible;
  /// 连续多少次采样里 `vo-passes` 没有用户着色器 pass（用于自愈判定）。
  int _srPassMiss = 0;
  /// 已尝试重建视频链重下发 shader 的次数（封顶防死循环）。
  int _srHealTries = 0;
  /// 渲染输出帧率（约等于源容器帧率）。NaN/0 表示未知。
  double _outFps = 0;
  /// 显示器刷新率，未知为 0。
  double _dispFps = 0;

  // ── 网页通道（同一 Route 双状态机）────────────
  /// mpv 无法播放（网页加密/人机校验/直链带签名 Cookie）时切到内嵌 WebView
  /// 通道，由 AnimePlayerPage 状态机接管播放；捕获到直链再切回 mpv。
  /// 与旧实现「pushReplacement 跳到另一个播放页」相比，这是同一页面内的
  /// 通道切换，杜绝双页互跳/双播放器叠音。
  bool _useWeb = false;

  /// 网页通道当前要加载的地址；切通道/换集时更新。
  String _webUrl = '';

  /// 网页通道当前集（换集后同步给 AnimePlayerPage 的 initialSeason/Episode）。
  int _webSeason = 1;
  int _webEpisode = 1;

  /// 网页通道子树重建计数：换集/换地址时 +1 强制重建 WebView，
  /// 让 AnimePlayerPage 重新 initState 加载新地址。
  int _webGeneration = 0;

  /// mpv 当前是否正被「网页通道 handoff 打开直链」：open/异步 error 期间
  /// 置位。该阶段 mpv 打不开直链时切回网页通道而非弹失败页——网页通道捕获
  /// 的直链若源站已失效（bucket 删除/签名过期），mpv 打开失败不代表
  /// 「本地播放内核不可用」，用户应留在网页播放或换线路。
  bool _handoffOpening = false;

  /// 当前 handoff 尝试的直链：异步 error 到达时据此记忆「该直链打不开」。
  String _handoffSrc = '';

  /// mpv 已确认打不开的直链（源站失效/防盗链拒绝等）。同一失效直链不反复
  /// handoff，避免「mpv 失败 → 重建 WebView → 又解析同一失效直链 → 又失败」
  /// 的循环。仅本次页面生命周期内有效，换源/换集后自然失效。
  final Set<String> _rejectedHandoffs = {};

  // ── 画质 ────────────────────────────────────
  String _srId = 'off';
  bool _enhance = true;
  bool _srApplying = false;

  /// 最近一次 mpv 报告的着色器错误（无则 null）。
  String? _srFault;

  // ── 墙钟观测（诊断循环用）─────────────────────────────────
  /// 上一拍记录的 time-pos（秒）。
  double _lastPosSec = -1;

  /// 上一拍记录的墙钟（Stopwatch，单调递增）。
  final Stopwatch _posWatch = Stopwatch()..start();

  /// 真实播放速率 = time-pos 推进 / 墙钟流逝。mpv 的 `speed` 属性在显示时钟
  /// 估算错误时恒读回 1.0（自认 1x），只有这个比值能看出实际是否被倍速。
  double _wallClockRate = 1.0;

  // ── 播放参数 ────────────────────────────────

  /// 倍速档位。倍速面板与 `[`/`]` 快捷键共用同一份列表：
  /// 快捷键以它为锚步进/就近吸附，避免产生面板之外的中间值。
  static const List<double> _speedSteps = [
    0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 3.5, 4.0,
  ];
  double _speed = 1.0;
  int _fitIndex = 0;
  static const _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill];
  static const _fitNames = ['适应屏幕', '裁剪填充', '拉伸铺满'];

  // ── 本地字幕（SRT）───────────────────────────
  SubtitleIndex? _subtitles; // null = 未加载字幕（层不渲染）
  String _subtitleName = ''; // 已加载字幕的文件名（UI 展示）

  /// 当前可用的音轨列表（>2 条即多音轨，含 auto/no 保底两项）。
  List<AudioTrack> _audioTracks = [];

  /// 画中画移交后跳过 Player 释放（Player 已归迷你播放器所有）。
  bool _skipPlayerDispose = false;

  // ── 界面状态 ────────────────────────────────
  bool _fullscreen = false;
  bool _locked = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _clockTimer;
  String _clock = '';

  // ── 画质诊断（实测超分是否真的生效）────────────────
  /// 周期读取 mpv 属性验证超分实际输出与播放速率，结果写 ErrorLogger。
  Timer? _diagTimer;

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
  /// 单调最大的稳定播放位置（不含回退）。断流重连时 mpv 可能把 time-pos
  /// 倒卷归零再从头加载，直接用 _pos 算断点会取到 0 → 全部白看。用它 +
  /// 持久化进度兜底，保证重连回到倒卷前的位置附近。
  Duration _stablePos = Duration.zero;
  /// 主动 seek 的时间戳：position 倒卷守卫用它区分「用户/代码刻意 seek」
  /// 与「mpv HLS seek 失败把 time-pos 无事件地卷回 0」（media_kit #1331 类
  /// bug）。刻意 seek 后 3 秒内的回退放行，超窗的巨幅回退判为异常倒卷。
  DateTime _lastSeekCmd = DateTime.fromMillisecondsSinceEpoch(0);
  /// 倒卷守卫的 backoff 冷却末次触发：同一时刻最多主动 seek 回一次，
  /// 防止 mpv 反复倒卷时守卫与重载互相打架造成 seek 循环。
  DateTime _lastRewindGuard = DateTime.fromMillisecondsSinceEpoch(0);
  // 横滑拖拽 seek 时是否曾处于播放态（用于松手续播）
  bool _pauseBeforeSeek = false;
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
  /// 切集代际：每次切换剧集递增，自动连播/延迟任务据此作废过期动作。
  int _switchGen = 0;
  /// 播放中途流错误后的重连进行中标记（防并发重连）。
  bool _recovering = false;
  bool _completedHandled = false;
  /// 竖屏面板里「当前集」方块的定位锚点：每次切集后作废重建，
  /// 面板打开时用它把当前集滚进视口（长番几百集时当前集可能在第 150 集）。
  final GlobalKey _curEpKey = GlobalKey();

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

  /// 超分（Anime4K）仅保留桌面端：手机端不做超分（2026-09-16 用户决策，
  /// AI 超分与插帧只在电脑端做）。移动端强制隐藏入口并锁定为 off。
  /// 用 [DesktopUi.isDesktopPlatform] 判定（测试可覆盖），而非 dart:io
  /// [Platform]——后者在 `flutter test` 下恒报宿主机，widget 测试会误判。
  bool get _srAndroidOff => !DesktopUi.isDesktopPlatform;

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
    _autoMatchSubtitle(); // 本地播放自动匹配同目录同名 SRT
    // 系统画中画（Android 8+）：仅安装通道与状态监听，非 Android 静默跳过。
    unawaited(PipChannel.install().then((ok) {
      if (mounted && ok) setState(() {});
    }));
    // 桌面端播放快捷键：空格 播放/暂停、←/→ 快退/快进、↑/↓ 音量、
    // M 静音、F 全屏、Esc 隐藏控制层。仅桌面注册，避免蓝牙键盘误触。
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
    }
  }

  /// 生成代际 token：防老的 _loadDanmaku 响应覆盖当前集的弹幕。
  int _danmakuGen = 0;
  /// 加载弹幕设置并拉取当前集的弹幕（在线失败静默，不影响播放）。
  Future<void> _loadDanmaku() async {
    final gen = ++_danmakuGen;
    final set = await LocalStore.danmakuSettings();
    if (!mounted || gen != _danmakuGen) return;
    setState(() => _danmakuSet = set);
    final items = await DanmakuFetcher.fetch(widget.title, _curEpisode);
    if (!mounted || gen != _danmakuGen) return;
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

  /// 弹幕设置面板：字号 / 速度 / 透明度 / 开关（快捷键 C 呼出）。
  void _showDanmakuPanel() {
    _hideTimer?.cancel();
    showPlayerPanel(
      context: context,
      title: '弹幕设置',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Widget slider(String label, String display, double value, double min,
            double max, int divisions, ValueChanged<double> onChanged) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(label,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13)),
                const Spacer(),
                Text(display,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12)),
              ]),
              Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                activeColor: PlayerColors.accent,
                onChanged: (v) {
                  onChanged(v);
                  setSheet(() {});
                },
              ),
            ],
          );
        }

        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            PanelOptionTile(
              title: '弹幕开关',
              subtitle: _danmakuSet.on ? '已开启 · 数据源：弹弹 play' : '当前关闭',
              selected: _danmakuSet.on,
              trailing: Switch(
                value: _danmakuSet.on,
                activeTrackColor: PlayerColors.accent,
                onChanged: (v) async {
                  final next = _danmakuSet.copyWith(on: v);
                  setState(() => _danmakuSet = next);
                  await LocalStore.setDanmaku(next);
                  setSheet(() {});
                },
              ),
              onTap: () {},
            ),
            slider('字号', '${_danmakuSet.fontSize.round()}',
                _danmakuSet.fontSize, 12, 22, 10, (v) {
              final next = _danmakuSet.copyWith(fontSize: v);
              setState(() => _danmakuSet = next);
              LocalStore.setDanmaku(next);
            }),
            slider('速度', '${_danmakuSet.speed.toStringAsFixed(1)}x',
                _danmakuSet.speed, 1.0, 3.0, 20, (v) {
              final next = _danmakuSet.copyWith(speed: v);
              setState(() => _danmakuSet = next);
              LocalStore.setDanmaku(next);
            }),
            slider('透明度', '${(_danmakuSet.opacity * 100).round()}%',
                _danmakuSet.opacity, 0.2, 1.0, 8, (v) {
              final next = _danmakuSet.copyWith(opacity: v);
              setState(() => _danmakuSet = next);
              LocalStore.setDanmaku(next);
            }),
          ]),
        );
      }),
    ).then((_) => _scheduleHide());
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
    // 初始地址是网页播放页（非直链）：先走内嵌 WebView 通道，等捕获到
    // 直链再切 mpv。Player 仍需创建（_handoffWebToMpv 的 _open 要用），
    // 只是不 open 任何地址。
    if (!isDirectMediaUrl(widget.url)) {
      setState(() {
        _useWeb = true;
        _webUrl = widget.url;
        _webSeason = widget.season;
        _webEpisode = widget.episode;
      });
    }
    try {
      // 画中画恢复：直接接管迷你播放器移交的 Player，不再新建实例。
      final PlayerHandoff? taken = widget.take;
      // 非恢复场景（用户从书架/详情直接开新播放页）时，若小窗仍挂载
      // 着旧 Player，先收编销毁它，否则新旧两个 Player 同时出声（叠音）。
      if (taken == null && PlayerRegistry.active) {
        PlayerRegistry.retire();
      }
      final Player p;
      if (taken != null) {
        p = taken.player;
        // 恢复语速/音量等会跟随 handoff 快照的偏好
        _speed = taken.speed;
        _volume = (taken.volume / 100).clamp(0.0, 1.0);
        _curSeason = taken.season;
        _curEpisode = taken.episode;
      } else {
        p = Player(configuration: const PlayerConfiguration(
          // 需要收到 shader 编译的 warn 级日志用于失败诊断
          logLevel: MPVLogLevel.warn,
          // HLS/慢 CDN 源的播放缓冲。默认 32MB 在码率 1.26MB/s 的片源上
          // 只够 ~25 秒（实测 bf.modujx15.com 单连接仅 35-140KB/s），
          // 播几下就把缓冲耗尽进入「分片卡顿→重载」循环。提到 256MB，
          // 让慢源先攒够播放窗口再放（mpv 的 demuxer-max-bytes 是字节
          // 容量不是时间，256MB ≈ 20-30 分钟低码率播放窗口）。
          bufferSize: 256 * 1024 * 1024,
        ));
      }
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
        if (v > _stablePos) _stablePos = v;
        _maybeSaveProgress(v);
        _scheduleFlush();
        _watchRewind(v);
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
      // 音轨列表：打开切换面板时展示；播放器随选集/直链自动带出多音轨。
      _subs.add(p.stream.tracks.listen((t) {
        if (mounted && t.audio.length > 2) {
          setState(() => _audioTracks = t.audio);
        }
      }));
      _subs.add(p.stream.error.listen((e) {
        if (!mounted) return;
        if (!_ready) {
          // 网页通道 handoff 的直链打不开（源站失效/防盗链拒绝）：
          // 记住该直链不再尝试，切回网页通道继续播放，不弹失败页。
          if (_handoffOpening) {
            _handoffOpening = false;
            if (_handoffSrc.isNotEmpty) {
              _rejectedHandoffs.add(_handoffSrc);
            }
            setState(() {
              _useWeb = true;
              _failed = false;
              _webGeneration++;
            });
            _toast('直链播放失败，已切回网页播放');
            return;
          }
          setState(() {
            _failed = true;
            _failMsg = '播放失败，请重试';
          });
        } else {
          // 播放中途的流错误（源站中断/防盗链在分片期拒绝）：
          // 进入「缓冲重试」而非定格在最后一帧假装正常。
          _tryRecoverFromStreamError();
        }
        ErrorLogger.instance.warn('player stream error: $e');
      }));
      // 捕获 mpv 的着色器错误（编译失败会在 error 级日志里出现）。
      // 注意：不能用笼统的 contains('Failed to')——mpv 的缓存/网络错误
      // （如 "Failed to create file cache"）也会含 "Failed to"，会被误判
      // 成着色器失败并在 UI 上报「超分未生效」。只有同时提到 shader/glsl
      // 的错误才算着色器问题。
      _subs.add(p.stream.log.listen((log) {
        if (!mounted) return;
        final t = log.text;
        final isShaderErr = t.contains('shader') || t.contains('glsl');
        if (isShaderErr ||
            t.contains('Failed to') ||
            t.contains('hwdec') ||
            t.contains('vo=') ||
            t.contains('gpu-context') ||
            t.contains('Using hardware') ||
            t.contains('No hardware') ||
            t.contains('fp32') ||
            t.contains('Texture') ||
            t.contains('scale') ||
            // 显示同步诊断：mpv 在 display-fps 未知时的兜底行为
            //（"Assuming 60 FPS for display sync"）和 video-sync 相关
            // 消息都从这里透出，用于确认同步目标是否生效。
            t.contains('Assuming') ||
            t.contains('display sync') ||
            t.contains('vsync') ||
            t.contains('interpolation') ||
            t.contains('tscale') ||
            t.contains('display-resample')) {
          ErrorLogger.instance.debug('MPVLOG[${log.level}] ${t.trim()}');
        }
        if (log.level == 'error' && isShaderErr) {
          _srFault = t.trim();
        }
      }));

      // 网页通道初始加载：Player 已建好但不开网页地址（mpv 播不了），
      // 等 WebView 捕获直链后由 _handoffWebToMpv 切回 mpv。
      if (!_useWeb) {
        await _open(widget.url, adopted: taken != null);
      }
    } catch (e) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// mpv 拉流所需的请求头。部分源站 CDN 校验 Referer/UA，缺了会在 ts
  /// 分片阶段返回 403（表现为「播几秒后失败」）；补上与下载器一致的
  /// Referer（scheme://host/）+ 浏览器 UA。IP 直连（Cloudflare 优选）时
  /// 还要带正确 Host 头，否则 TLS 证书校验不过。
  ///
  /// ⚠️ 签名直链源（稀饭动漫 → media.vod 302 到 pan.wo.cn 移动云盘）**拒绝**
  /// 带 Referer 的请求（实测 HTTP 400 / ECONNRESET，无 Referer 才 206 正常
  /// 下载）。带 Referer 会让 mpv 拉流反复被 400 掐断 → 播 1-2 秒 → 缓存耗尽
  /// → 停 12-44 秒 → 重连 → 循环（v1.5.1 引入的回归，见 _open)。故对这类
  /// 签名直链域名不设 Referer。
  Map<String, String> _mediaHeaders(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return const {};
    final host = uri.host;
    final h = <String, String>{
      'User-Agent': Net.defaultUA,
      if (!RegExp(r'(^|\.)pan\.wo\.cn$').hasMatch(host))
        'Referer': '${uri.scheme}://$host/',
    };
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
      h['Host'] = 'www.tvtfun.net';
    }
    return h;
  }

  /// 用 mpv 打开媒体地址。返回是否成功打开。
  ///
  /// handoff 阶段（[_handoffOpening]，网页通道捕获直链后试开）打不开时
  /// 不外抛、不弹失败页：由调用方（[_handoffWebToMpv]）切回网页通道；
  /// 其余场景保持旧行为——打开失败进入失败视图（含重试/切网页播放）。
  Future<bool> _open(String url, {bool adopted = false, Duration? resumeAt}) async {
    final p = _player;
    if (p == null) return false;
    try {
      // 超分是桌面专属能力：移动端不拷 shader 资产（避免首次启动磁盘 IO），
      // 也跳过 mpv shader 编译缓存目录创建。
      if (DesktopUi.isDesktopPlatform) {
        await Anime4KManager.ensureShaders();
      }
      // mpv 0.37+ 默认开启 gpu shader 编译缓存（disk cache），但没指定
      // 目录时会尝试写默认路径并报「Failed to create file cache」——
      // 无害但会吓到用户（曾被误判为「超分未生效」）。显式指到应用
      // 支持目录（可写），缓存照常工作、错误彻底消失。
      try {
        final cacheDir = await getApplicationSupportDirectory();
        final shaderCache = Directory(
            '${cacheDir.path}${Platform.pathSeparator}mpv-shader-cache');
        await shaderCache.create(recursive: true);
        final native = p.platform;
        if (native is NativePlayer) {
          await (native as dynamic)
              .setProperty('gpu-shader-cache-dir', shaderCache.path);
          // media_kit 默认 network-timeout=5 对慢 CDN 分片太苛刻：实测
          // bf.modujx15.com 单连接 35-140KB/s，5 秒连握手+首字节都未必完成，
          // 分片 fetch 反复超时 → 缓冲耗尽 → 卡顿/重载。提到 15 秒让慢源
          // 的分片有充足时间抵达（读中断后 mpv 仍按分片粒度重试）。
          await (native as dynamic).setProperty('network-timeout', '15');
          // 切速（scaletempo 变速 + 视频时钟重同步）瞬间 mpv 会短暂判定
          // 缓存不足而 paused-for-cache 暂停（实测 33/272 采样 pfc=yes，
          // 多集中在 3x/4x↔1x 快速切换的瞬间）——但那一刻缓存明明是满的
          // （dct 实测可达 278-875s），暂停纯属误杀，用户感知为卡顿。
          // 把暂停阈值设 0：不再因缓存主动暂停；真正断流时走 demuxer
          // 读失败 → stream error 重连路径（_tryRecoverFromStreamError），
          // 不受影响。
          await (native as dynamic).setProperty('pause-after-cache', '0');
        }
      } catch (_) {
        // 目录创建/属性设置失败不影响播放，静默跳过。
      }
      _srFault = null;
      await _applyEnhance();
      await _applySr(silent: true);
      await _applySync();
      await p.setRate(_speed);
      if (adopted) {
        // 画中画恢复：Player 已在播放同一直链，仅需同步界面状态，不再重开。
        if (mounted) {
          setState(() {
            _pos = p.state.position;
            _dur = p.state.duration;
            _ready = true;
            _completedHandled = false;
          });
        }
      } else {
        await p.open(Media(url, httpHeaders: _mediaHeaders(url)), play: true);
        // Android 上 VideoController 会在拿到 wid 后把 vo=null→gpu 重建，
        // 提前塞的 glsl-shaders 可能被清掉。等首帧真正渲染完再补挂。
        try {
          await _controller?.waitUntilFirstFrameRendered
              .timeout(const Duration(seconds: 10));
        } catch (_) {}
        if (_sr.enabled) {
          await _applySr(silent: true);
          // vo 重建的时点可能在首帧回调之后（Android 上 texture 尺寸
          // 稳定才真正重建）。补挂后延迟再补两次，覆盖晚到/多次重建，
          // 每次补挂后读回 glsl-shaders，列表还在就不再重复设置。
          for (final ms in const [1500, 3000]) {
            if (!mounted) break;
            await Future<void>.delayed(Duration(milliseconds: ms));
            if (!mounted) break;
            final native = _player?.platform;
            if (native is! NativePlayer) break;
            final back =
                await (native as dynamic).getProperty('glsl-shaders');
            if (back.toString().isNotEmpty) break;
            await _applySr(silent: true);
          }
        }
        // vo 重建会重置 video-sync，且音轨要到首帧前后才解析出来：首帧后
        // **统一重设一次**（含音轨感知的同步模式选择），确保治卡顿 /
        // 防倍速的修复在「音轨已就绪」的正确状态下生效。
        await _applySync();
        if (mounted) {
          setState(() {
            _ready = true;
            _completedHandled = false;
          });
        }
      }
      // 重连（resumeAt 非空）时断点已由调用方 seek 回，静默跳过续播提示。
      await _prepareResume(silent: resumeAt != null);
      // 断流重连等场景重开同一 URL 时 seek 回断点（t-3s），避免从 0:00 重播。
      if (resumeAt != null && resumeAt > Duration.zero) {
        _player?.seek(resumeAt);
        ErrorLogger.instance
            .debug('resumed at ${resumeAt.inSeconds}s after reopen');
        _pos = resumeAt;
        if (resumeAt > _stablePos) _stablePos = resumeAt;
        if (mounted) setState(() {});
      }
      // 诊断轮询每 2 秒做十几次同步 FFI 属性读取（会阻塞 UI 线程），
      // 只在桌面端跑；移动端不需要这项观测。
      if (DesktopUi.isDesktopPlatform) _startDiag();
      _scheduleHide();
      return true;
    } catch (e) {
      if (mounted) {
        if (_handoffOpening) {
          // 网页通道试开的直链打不开：交由 _handoffWebToMpv 切回网页通道。
          return false;
        }
        setState(() {
          _failed = true;
          _failMsg = '播放失败，请重试';
        });
        ErrorLogger.instance.warn('player open failed: $e');
      }
      return false;
    }
  }

  /// 播放中途的流错误恢复（源站中断/分片期防盗链拒绝）。
  ///
  /// 旧的实现里 `error.listen` 只在 `!_ready` 时处理：一旦首帧出来，
  /// 播放中的错误被完全吞掉，画面定格在最后一帧、无任何提示（表现为
  /// 「播着播着冻住」）。这里对已就绪的播放尝试用 mpv 自动重连同一
  /// 地址（mpv 内部会重新拉流/重新握手，多数瞬时断流可自愈）；重连
  /// 仍失败才进失败视图，让用户能手动重试/切网页播放。
  Future<void> _tryRecoverFromStreamError() async {
    if (_recovering || _switching || _handoffOpening) return;
    _recovering = true;
    _toast('播放中断，正在重连…');
    // 记住断点，重开同一 URL 后 seek 回来（t-3s 稳一点，直接回精确点可能
    // 因关键帧偏移黑屏/重缓冲）。_open 失败时内部已置 _failed 并返回 false。
    //
    // ⚠️ 断点不能再直接取 _pos：HLS 分片失败时 mpv 会把 time-pos 倒卷归零，
    // 那一刻 _pos 已被污染成 0（实测 wrate=-161，2 秒内倒卷 323s），直接取
    // _pos 会让 resumeFrom=0 → seek 被跳过 → 从头重播。稳定位置 _stablePos
    // 只在 position 前进时更新，天然屏蔽倒卷；持久化进度（每 5 秒落盘）作为
    // 跨会话兜底。两者取最大，但不越过当前时长。
    var resumeFrom = _stablePos > _pos ? _stablePos : _pos;
    try {
      final saved = await LocalStore.videoProgressOf(_histKey);
      final savedDur = Duration(seconds: saved);
      if (savedDur > resumeFrom && savedDur <= (_dur > Duration.zero ? _dur : savedDur)) {
        resumeFrom = savedDur;
      }
    } catch (_) {}
    resumeFrom = resumeFrom > const Duration(seconds: 6)
        ? resumeFrom - const Duration(seconds: 3)
        : Duration.zero;
    final ok = await _open(widget.url, resumeAt: resumeFrom);
    if (mounted) {
      setState(() => _recovering = false);
      if (ok) _toast('重连成功，继续播放');
    }
  }

  // ── 偏好持久化 ──────────────────────────────
  Future<void> _loadPrefs() async {
    try {
      final raw = await LocalStore.readJson('player_prefs');
      if (raw is Map) {
        _srId = (raw['sr'] as String?) ?? 'off';
        if (Anime4KManager.levels.every((e) => e.id != _srId)) _srId = 'off';
        // AI 超分按用户要求仅保留桌面端；移动端强制关闭（即使旧持久化里
        // 存了档位），不展示入口。
        if (!DesktopUi.isDesktopPlatform) _srId = 'off';
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

  Future<void> _prepareResume({bool silent = false}) async {
    try {
      final sec = await LocalStore.videoProgressOf(_histKey);
      if (sec > 20 && mounted) {
        _resumeAt = Duration(seconds: sec);
        // 断流重连等中途重开同名 URL 时已由调用方 seek 回断点，不再弹
        // 「上次看到…」提示条（那是首次进入时的续播引导）。
        if (silent) return;
        setState(() => _resumeTipVisible = true);
        _resumeTipTimer?.cancel();
        _resumeTipTimer = Timer(const Duration(seconds: 8), () {
          if (mounted) setState(() => _resumeTipVisible = false);
        });
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
        // 统一收口到 LocalStore：整体排队写 + 上限裁剪，与小窗并发不互踩。
        await LocalStore.setVideoProgress(_histKey, done ? null : sec);
      } catch (e) {
        // 续播进度持久化失败需可观测，否则用户以为已保存实则丢失
        ErrorLogger.instance.warn('save video progress failed: $e');
      }
    }();
  }

  /// position 层倒卷守卫：mpv 在 HLS 上 seek 失败时（media_kit #1331 类 bug）
  /// 会把 time-pos **无任何 error/completed 事件地卷回 0** 并重载文件，用户
  /// 看到的就是「播着播着跳回 0:00 重播」。这个事件链不经过 stream error 恢复
  /// 路径（_tryRecoverFromStreamError 拦不到），所以必须在 position 流里兜底：
  /// 一旦发现「没有主动 seek 意图的巨幅回退」，主动 seek 回稳定断点。
  ///
  /// 触发条件（全部满足才干预）：
  /// * 回退幅度 ≥ 60s（缓冲倒卷/轻微 seek jitter 达不到这个量级）；
  /// * 当前 position 明显靠近 0（<10s）——排除「用户往前 seek 但幅度大」的
  ///   误伤（往前 seek 到 60s 处位置是 60s 不是 0）；
  /// * 距主动 seek 命令 ≥3s——刻意 seek 后的回退是正常的，放行；
  /// * 冷却 10s——mpv 可能连续倒卷，冷却防守卫自己与重载打架成 seek 循环。
  ///
  /// 恢复目标 = 稳定位置（单调最大，天然屏蔽倒卷），往后退 3s 留关键帧
  /// 偏移余量；<8s 不干预（本身就播在开头，救不救无差别）。
  void _watchRewind(Duration v) {
    if (_stablePos <= const Duration(seconds: 8)) return; // 没什么可救
    final regress = _stablePos - v;
    if (!(regress >= const Duration(seconds: 60) && v < const Duration(seconds: 10))) {
      return;
    }
    if (_recovering ||
        _switching ||
        _handoffOpening ||
        _draggingBar ||
        DateTime.now().difference(_lastSeekCmd) < const Duration(seconds: 3)) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastRewindGuard) < const Duration(seconds: 10)) return;
    _lastRewindGuard = now;
    final target = _stablePos - const Duration(seconds: 3);
    if (target < const Duration(seconds: 8)) return;
    _player?.seek(target);
    // _pos 已被 0 污染；seek 立即回写 UI 位置，避免进度条/字幕闪到 0。
    if (mounted) setState(() => _pos = target);
    ErrorLogger.instance
        .debug('rewound guard: stable=${_stablePos.inSeconds}s, saw=${v.inSeconds}s, seek back to ${target.inSeconds}s');
  }

  // ── 画质 ────────────────────────────────────

  /// 超分角标文案。
  ///
  /// ⚠️ 2026-09-14 修正：**不要**再写「→ 输出分辨率」。Anime4K 执行在 VO
  /// 着色器阶段，mpv 没有任何属性能直接给出"超分后的尺寸"；旧实现拿
  /// `video-out-params` 冒充，结果永远等于源尺寸，属于谎报（也是「超分到底
  /// 生效没有」长期判不出来的原因）。改为如实展示三件事：
  /// 档位 + 源分辨率 + x2 放大链是否具备执行条件（不成立时说明原因）。
  String _srBadgeLabel() {
    final buf = StringBuffer('AI 超分 · ${_sr.name}');
    if (_vw > 0 && _vh > 0) buf.write(' · $_vw×$_vh');
    if (_srEligible == false) {
      // 渲染输出比源还小（窗口/屏幕装不下源，正在缩小播放）：
      // shader 的 WHEN 条件不成立，本次只有 Restore 修复链在跑。
      buf.write(' · 缩小播放，仅修复');
    }
    return buf.toString();
  }

  /// 超分面板底部提示。
  ///
  /// 旧文案只写「低于 1080p 收益最明显」，没有回答用户真正的疑问
  /// （"为什么我开了没变化"、"是超到 1080 还是 2K"）。这里按 x2 链的
  /// 实际执行条件分三种情况如实说明。
  ///
  /// 2026-09-19 实测定案（渲染目标跟随窗口，删无效 setSize 后）：
  /// Anime4K x2 链的 `//!WHEN OUTPUT.w > MAIN.w/0.999` 要求**渲染输出
  /// （= mpv 渲染目标 = 窗口/全屏尺寸）比片源大**才执行；执行后画面
  /// 被放大到 2×源分辨率再由 VO 缩回窗口尺寸（超采样）。所以：
  /// * 全屏到 2K 屏（输出 2560×1440）播 1080p 源 → x2 链跑 → 真实 2K；
  /// * 窗口化播 1080p 源 → 输出≈源尺寸 → WHEN 不成立 → 只有修复链生效。
  String _srHintText() {
    final src = (_vw > 0 && _vh > 0) ? '当前片源 $_vw×$_vh' : '片源分辨率获取中';
    if (_srEligible == false) {
      return '$src，画面渲染尺寸比片源还小（正在缩小播放），放大链不执行，'
          '本次只有线条修复生效。全屏播放或调大窗口即可开启 2 倍超采样。';
    }
    if (_vw > 0 && _vw <= 1280) {
      return '$src，低于 720p 档位收益最明显；卡顿请降档。'
          'x2 档（极致画质）全屏到 2K 屏会自动放大到 2560×1440（2K 超采样）。';
    }
    return '$src。超分会把画面放大 2 倍再缩回屏幕尺寸（超采样，锐化线条与降噪），'
        '收益小于低分辨率片源但真实可见，开销较高，卡顿请降档。'
        'x2 档（极致画质）全屏到 2K 屏即为 2K 超分。';
  }

  /// 周期读取 mpv 关键属性，实测超分的实际输出并写日志。
  ///
  /// 对比对象：
  /// * `video-params`  — 解码源分辨率（超分前，权威）
  /// * `dwidth/dheight` — **VO 真正绘制到屏幕的尺寸**，超分判据用它
  /// * `video-out-params` — 视频滤镜链输出尺寸。⚠️ Anime4K 跑在 VO 着色器
  ///   阶段（滤镜链之后），该属性**不反映超分**，恒等于源尺寸；这里只作为
  ///   对照值写进日志（`vop=`），**不再当"超分后尺寸"用**（2026-09-14 修正，
  ///   旧实现拿它当判据，导致"超分到底生效没有"长期无法判断）。
  /// * `vo-passes`       — **唯一可靠的超分生效判据**：里面出现的
  ///   `user shader: Anime4K-*` pass 数量（日志字段 `a4k=`）。为 0 说明
  ///   着色器没进渲染图，此时会触发自愈（[`_healSrPipeline`]）。
  /// * `estimated-vf-fps` — 视频滤镜链估计帧率
  /// * `container-fps`   — 源容器帧率
  /// * `display-fps`     — 显示刷新率（override 后即同步目标）
  /// 每 2 秒采样一次，仅记录与上一次不同的关键变化，避免刷屏。
  ///
  /// 关于「真实播放速率」的测定：mpv 的 `speed` 属性在显示时钟估算错误时
  /// 恒读回 1.0（自认 1x），**不可信**；只有墙钟速率（time-pos 推进 / 墙钟
  /// 流逝，日志字段 `wrate=`）能看出视频是否被实际倍速。显示同步相关的
  /// 读数（`vsync`/`disp`/`edisp`/`ovr`）供诊断面板参考。
  void _startDiag() {
    _diagTimer?.cancel();
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    final dyn = native as dynamic;
    String? last;
    _diagTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      // 逐个读取并容错：某个属性失败时记下错误，不拖垮整行诊断。
      Future<String> rd(String name) async {
        try {
          return (await dyn.getProperty(name)).toString();
        } catch (e) {
          return 'ERR($e)';
        }
      }

      final wp = await rd('video-params/w');
      final hp = await rd('video-params/h');
      final dw = await rd('dwidth');
      final dh = await rd('dheight');
      final wop = await rd('video-out-params/w');
      final hop = await rd('video-out-params/h');
      final efps = await rd('estimated-vf-fps');
      final cfps = await rd('container-fps');
      final dfps = await rd('display-fps');
      final edfps = await rd('estimated-display-fps');
      final glsl = await rd('glsl-shaders');
      final vsync = await rd('video-sync');
      final hw = await rd('hwdec');
      // 音频通路是否真的活着（设备被独占 / 网络流音轨未解码 / wasapi 被占
      // 时 aid 非 no 但 channels 读不到 → 无音频时钟 → display-resample 会
      // 按显示时钟追赶视频造成倍速）。这是定位「播放被倍速」的关键证据。
      final ach = await rd('audio-params/channels');
      final aaid = await rd('aid');
      final spd = await rd('speed');
      // 墙钟速率（仅观测）：mpv 的 `speed` 属性在显示时钟估算错误时恒读回
      // 1.0（用户机器实测 edisp=419~525Hz 垃圾值、视频实时倍速、speed 仍
      // 1.000000），time-pos 推进 / 墙钟流逝 才是能看出实际倍速的量。
      final pos = await rd('time-pos');
      final posSec = double.tryParse(pos);
      if (posSec != null && _posWatch.isRunning) {
        final wallSec = _posWatch.elapsedMilliseconds / 1000.0;
        if (_lastPosSec >= 0 && wallSec >= 1.0) {
          _wallClockRate = (posSec - _lastPosSec) / wallSec;
        }
        _lastPosSec = posSec;
        _posWatch
          ..reset()
          ..start();
      }
      // 超分是否**真的进了渲染管线**：只认 vo-passes 里的 user shader pass。
      // glsl-shaders 读回非空不算数——真机实测过"属性读回两个路径、
      // vo-passes 里一个用户着色器 pass 都没有"的静默失效。
      final srPasses =
          Anime4KManager.userShaderPassCount(await rd('vo-passes'));
      // 同步目标刷新率：优先读真实 display-fps（Windows ANGLE 常为 ?），
      // 读不到时用 override-display-fps 设定的 60Hz 兜底。
      final ovr = await rd('options/override-display-fps');
      final srcW = int.tryParse(wp) ?? 0;
      final srcH = int.tryParse(hp) ?? 0;
      // 渲染输出 = VO 侧尺寸（`dwidth`/`dheight`）。个别构建可能读不回，
      // 此时退到 video-out-params：该值恒等于源尺寸，会让判据「偏向成立」
      // （src/src = 1.0 > 0.999），属于可接受的退化——日志里用 voSrc 标注
      // 实际取的是哪一个，方便一次性确认本构建能不能读 dwidth。
      var ow = int.tryParse(dw) ?? 0;
      var oh = int.tryParse(dh) ?? 0;
      var voSrc = 'dw';
      if (ow <= 0 || oh <= 0) {
        ow = int.tryParse(wop) ?? 0;
        oh = int.tryParse(hop) ?? 0;
        voSrc = 'vop';
      }
      // x2 放大链的执行条件判定（与 shader 的 //!WHEN 同源，见
      // Anime4KManager.srChainEligible）。尺寸缺一不可判，故用三态。
      final eligible = (srcW > 0 && srcH > 0 && ow > 0 && oh > 0)
          ? Anime4KManager.srChainEligible(
              srcW: srcW, srcH: srcH, outW: ow, outH: oh)
          : null;
      // 输出帧率：VO 出帧节奏即源容器帧率（无帧率级后处理时）。mpv 没有
      // 直接可读的「VO 实际出帧 fps」属性，用 container-fps 作源帧率、
      // display-fps 作显示同步目标；真正的倍速异常由墙钟 wrate 判定。
      final ddisp = double.tryParse(dfps) ?? ovrFps(ovr);
      final realFps = double.tryParse(cfps) ?? _outFps;
      if (!mounted) return;
      if (ow != _outW || oh != _outH || eligible != _srEligible ||
          realFps != _outFps || ddisp != _dispFps) {
        setState(() {
          _outW = ow;
          _outH = oh;
          _srEligible = eligible;
          _outFps = realFps;
          _dispFps = ddisp;
        });
      }
      final shaderCount = glsl
          .split(RegExp('[,\\n]'))
          .where((s) => s.trim().isNotEmpty)
          .length;
      // ── 超分自愈：属性设上了、但 pass 没进渲染图 ──────────────
      // 真机实测（2026-09-14，Android）存在这种静默失效：`glsl-shaders` 读回两个
      // 文件路径完全正常，`vo-passes` 里却一个 user shader pass 都没有 ——
      // 旧实现只信读回值，于是"以为开着"，用户看到的就是"开了超分毫无变化"。
      // 这里改成以 vo-passes 为准：连续 2 次采样（约 4 秒）都没有 pass，
      // 就强制重建一次视频链并重新下发 shader（实测这是唯一能让它生效的动作）；
      // 连试 3 次仍无效则如实报"未生效"，不再假装成功。
      //
      // ⚠️ 平台收口（2026-09-19 探针铁证）：`vo-passes` 只在真实 gpu VO 下可读。
      // Windows/macOS/Linux 桌面走 media_kit 的 `vo=libmpv` 渲染 API——mpv 官方
      // 证实该 API 只提供完整 VO 的一小部分能力（#10810），`vo-passes` **恒空**，
      // 但 `glsl-shaders` 列表被接受、无编译错误（探针 GLSHADERS_READBACK 正常 +
      // SHADERERR=0 + H/W D3D11/ANGLE 渲染）。若桌面端也按 vo-passes 判，会把
      // 「shader 已接受」误报成「未生效」→ 连重建 3 次视频链 → 弹红条（用户
      // 实测看到的假"超分没有"）。故自愈/红条只保留给能读 vo-passes 的
      // Android；桌面端以「glsl-shaders 被接受 + 无编译错误」为准，不重建。
      final canObservePasses = !DesktopUi.isDesktopPlatform;
      if (canObservePasses &&
          _sr.enabled && _ready && !_srApplying && srPasses == 0) {
        _srPassMiss++;
        if (_srPassMiss >= 2) {
          _srPassMiss = 0;
          if (_srHealTries < 3) {
            _srHealTries++;
            unawaited(_healSrPipeline());
          } else if (_srFault == null) {
            setState(() {
              _srFault = '着色器未进入渲染管线（已重建视频链重试 3 次仍无 pass，'
                  '可能是硬解模式或显卡驱动不支持）';
            });
          }
        }
      } else if (!canObservePasses || srPasses > 0) {
        _srPassMiss = 0;
        _srHealTries = 0;
      }
      // 字段含义（避免以后再误读）：
      //   src    = 解码源；vo = VO 实际绘制尺寸（超分判据）；voSrc = vo 取自
      //            哪个属性（dw=dwidth 可靠 / vop=video-out-params 退化值）；
      //   vop    = 滤镜链输出（**不含超分**，仅对照）；
      //   elig   = x2 链是否具备执行条件（1 成立 / 0 不成立 / ? 尺寸未知）；
      //   a4k    = vo-passes 里 user shader pass 数（0 = 着色器没进渲染图）。
      final srcTag = _wh(srcW, srcH);
      final voTag = _wh(ow, oh);
      // 渲染后端判定（2026-09-19 加）：超分「属性被接受但 vo-passes 0 pass」
      // 的静默失效，最常是渲染后端不支持用户着色器——软件 Vulkan
      // （vk_swiftshader）或 VO 回退到软渲染时 user shader 根本不执行。
      // 读回实际生效的 vo / gpu-api / gpu-context，一眼定位是哪条链。
      final rvo = await rd('vo');
      final rgapi = await rd('gpu-api');
      final rgctx = await rd('gpu-context');
      // 缓存取证：区分卡顿是「等网络分片」还是「渲染/音频停顿」。
      //   pfc=paused-for-cache（yes = mpv 因缓存空而主动暂停 → 等数据）
      //   dct=demuxer-cache-time（缓存内还剩多少秒媒体；≈0 且 pfc=yes → 网络瓶颈）
      // wrate≈0 且 pfc=yes → 网络慢，加大缓冲/超时有用；
      // wrate≈0 且 pfc=no 且 dct 有值 → 不是网络，是渲染链/音频设备/磁盘 I/O。
      final pfc = await rd('paused-for-cache');
      final dct = await rd('demuxer-cache-time');
      final line = 'DIAG src=$srcTag vo=$voTag($voSrc) vop=$wop x$hop '
          'elig=${eligible == null ? '?' : (eligible ? 1 : 0)} '
          'a4k=${canObservePasses ? srPasses : "?"} '
          'fps=${_fmtFps(efps)} srcFps=${_fmtFps(cfps)} realFps=${_fmtFps(realFps.toString())} '
          'disp=${_fmtFps(dfps)} ovr=${_fmtFps(ovr)} edisp=${_fmtFps(edfps)} '
          'shader=$shaderCount vsync=$vsync hwdec=$hw '
          'ach=$ach aid=$aaid speed=$spd wrate=${_fmtFps(_wallClockRate.toStringAsFixed(3))} '
          'rvo=$rvo gapi=$rgapi gctx=$rgctx '
          'pfc=$pfc dct=$dct';
      if (line == last) return;
      last = line;
      ErrorLogger.instance.debug(line);
      debugPrint('MPV[$line]');
    });
  }

  /// 拼「宽×高」文案（`×` 不是标识符字符，插值里不用加花括号）。
  static String _wh(int w, int h) => '$w×$h';

  static String _fmtFps(String v) {
    final d = double.tryParse(v);
    if (d == null) return v.isEmpty ? '?' : v;
    return d.toStringAsFixed(2);
  }

  /// 解析 override-display-fps 读回值（如 "60.000000" 或 "60/1"）。
  static double ovrFps(String v) {
    final d = double.tryParse(v);
    if (d != null && d > 0) return d;
    final parts = v.split('/');
    if (parts.length == 2) {
      final num = int.tryParse(parts[0]);
      final den = int.tryParse(parts[1]);
      if (num != null && den != null && den > 0) return num / den;
    }
    return 0;
  }

  Future<void> _applyEnhance() async {
    // 画质增强（EWA Lanczos 缩放 + deband 去色带）是桌面播放器的画质基线；
    // 移动端 GPU/带宽有限，跑整条链会掉帧。移动端沿用 mpv 默认 bilinear 缩放。
    if (!DesktopUi.isDesktopPlatform) return;
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    // web 上 NativePlayer 是 stub（无 libmpv），setProperty 不存在，
    // 但 `is NativePlayer` 检查仍会通过；用 dynamic 分发让非桌面端
    // 调用直接失败被吞掉，行为等价于"web 无超分"。
    final dyn = native as dynamic;
    final props =
        _enhance ? Anime4KManager.enhanceProps : Anime4KManager.enhanceOffProps;
    for (final e in props.entries) {
      try {
        await dyn.setProperty(e.key, e.value);
      } catch (_) {}
    }
  }

  /// 超分着色器没进渲染图时的自愈：重建视频链 → 重新下发 shader 列表。
  ///
  /// 为什么是这个动作（2026-09-14 真机实测）：把 `glsl-shaders` 设好、读回
  /// 也正常，`vo-passes` 里却一个 user shader pass 都没有。在反复实验里
  /// **唯一真正让 Anime4K 跑起来的一次**，是在 `hwdec` 发生过变更（触发视频链
  /// 重建）之后重新下发 shader 列表 —— 那次 `vo-passes` 里出现了 17 个
  /// `user shader: Anime4K-*` pass。所以这里照做：先把 hwdec 推到 auto-safe
  /// 再设回 auto-copy（逼 mpv 重建滤镜/VO 图），紧接着重新下发。
  ///
  /// 只在「开着超分却看不到 pass」时才触发，不影响正常播放路径。
  Future<void> _healSrPipeline() async {
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    final dyn = native as dynamic;
    try {
      await dyn.setProperty('hwdec', 'auto-safe');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await dyn.setProperty('hwdec', 'auto-copy');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (_) {}
    if (mounted) await _applySr(silent: true);
  }

  Future<void> _applySr({bool silent = false}) async {
    // 超分是桌面专属能力：移动端不自带（UI 已用 _srAndroidOff 隐藏入口），
    // 逻辑链也要在此收口——避免 Android 上仍写 hwdec/清 shader 影响播放。
    if (!DesktopUi.isDesktopPlatform) return;
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    final dyn = native as dynamic;
    // 用户主动改档位时重置自愈计数：给新档位重新观察的机会。
    if (!silent) {
      _srPassMiss = 0;
      _srHealTries = 0;
    }
    if (!silent) setState(() => _srApplying = true);
    try {
      _srFault = null;
      final list = await Anime4KManager.shaderListFor(_srId);
      // 超分强制放大：仅 x2 档（quality/ultimate）把渲染目标放大到源×2
      // （上限 2560 长边 = 2K），让 Upscale 链的 WHEN 条件成立、超分真实放大；
      // 关闭/降噪档还原为源尺寸。
      //
      // 分辨率来源必须是 mpv 当前**权威**值而非记忆的 _vw/_vh：切集时
      // _applySr 可能跑在 p.open() 之前，stream.width/height 与
      // video-params 都还是上一集的旧值——用旧值算目标会让新集 x2 倍率
      // 错乱（如 640p 源被当成 1080p，放大目标偏小、激活失败或过度）。
      // 这里每次读回 video-params/w/h 并同步 _vw/_vh（UI 角标也用它们）。
      // mpv 规定 video-params/w/h 只反映 **第一帧** 的分辨率，源集内
      // 分辨率中途变化（极少见）用它当「当前」没问题：源来自同一系列。
      try {
        final wp = await dyn.getProperty('video-params/w');
        final hp = await dyn.getProperty('video-params/h');
        final wpv = int.tryParse(wp.toString());
        final hpv = int.tryParse(hp.toString());
        if (wpv != null && wpv > 0 && hpv != null && hpv > 0) {
          _vw = wpv;
          _vh = hpv;
        }
      } catch (_) {}
      // 渲染目标尺寸 = VO 实际绘制尺寸（dwidth/dheight）。
      //
      // ⚠️ 2026-09-19 定案：`VideoController.setSize` 在 Windows 上**改不了**
      // mpv 的渲染目标**还**——media_kit_video 的 `VideoOutput::SetSize`（
      // video_output.cc:207-239）只改写 Flutter 纹理/EGL surface 的 width_/
      // height_ 成员；`CheckAndResize`（241-266）仅在视频尺寸变化时才
      // `Resize`，`Resize`（268+）只做 `surface_manager_->SetSize()` + 纹理
      // 重注册。mpv 的渲染目标仍等于视频输出尺寸，Anime4K x2 链的
      // `WHEN OUTPUT.w > MAIN.w` 恒不成立 → 之前 setSize 放大期待的效果
      // （源 1080p → 2K）从未发生过。
      //
      // 真正能让 x2 链跑起来的只有**渲染目标跟随窗口/全屏尺寸**：全屏到
      // 2K 屏（2560×1440）时 mpv 渲染输出即 2560×1440 > 源 1080p → WHEN 成立
      // → 自动超采样到 2K。窗口化时渲染目标 = 窗口/纹理尺寸（常=源尺寸），
      // x2 链不激活（不开降噪档时的正常表现，面板已提示）。
      //
      // 移除 setSize 后判据不变：诊断日志 `vo=`（dwidth/dheight）才是
      // 「实际渲染输出」，超分是否放大看它。目标尺寸计算不再需要，
      // Anime4KManager.srTargetSize 仅供算法参考（WHEN 门槛语义）。
      // 关键：mpv 的 hwdec 直通模式（Android mediacodec 零拷贝直通 GPU 纹理、
      // Windows d3d11va 零拷贝）会绕过 glsl-shaders 着色器管线——Anime4K
      // 这类 `//!HOOK MAIN` shader 将静默不生效。但**copy-back 模式**（
      // hwdec=auto-copy：硬解后把帧拷回主内存再交给渲染器）会让每一帧都
      // 完整经过着色器管线——超分、硬解可以同时全开，1080p 动画既清晰又
      // 不掉帧（纯 CPU 软解 1080p + VL 巨型 shader 才是掉帧元凶）。
      // 注意：仅本播放器实例生效，不影响全局。
      // ⚠️ 2026-09-14 实测更正：`hwdec=auto-copy` 在本机 Android 构建上
      // **是超分生效的前提，不只是性能增强**。真机对照实验：同一个
      // glsl-shaders 列表，`hwdec=no` 时 `vo-passes` 里 0 个用户着色器
      // pass；`hwdec=auto-copy` 时 17 个 `user shader: Anime4K-*` pass 全跑。
      // 所以这里失败**必须**被后续以 vo-passes 为准的自愈逻辑兜住
      // （见 [_healSrPipeline]），不能再像以前那样静默吞掉——否则用户
      // 只会看到"开了没变化"。
      try {
        await dyn.setProperty(
            'hwdec', _sr.enabled ? 'auto-copy' : 'auto-safe');
      } catch (_) {
        // 设不上：交给 vo-passes 自愈逻辑发现并重试。
      }
      // libmpv 对 path-list 选项用 mpv_set_property_string 设置时不会按
      // 逗号/换行拆分（会把整个串当单个文件名）。改用 change-list 命令，
      // 其 value 按平台路径列表分隔符解析：Windows=`;`，POSIX=`:`。
      // 路径本身已由 Anime4KManager.shaderListFor 转成正斜杠（Windows），
      // 避免 `\` 被 mpv 当转义序列破坏、盘符 `C:` 被当分隔符截断。
      final sep = Platform.isWindows ? ';' : ':';
      if (list.isEmpty) {
        await dyn.command(const ['change-list', 'glsl-shaders', 'set', '']);
      } else {
        await dyn.command([
          'change-list',
          'glsl-shaders',
          'set',
          list.replaceAll(',', sep),
        ]);
      }
      // 读回属性，确认 mpv 接受了这份 shader 列表。
      // 结论来自真实 libmpv 验证：无论 change-list 用什么分隔符传入，
      // glsl-shaders 读回永远是「逗号分隔」的已展开路径；而 Windows 盘符
      // 「C:」里也含冒号——所以绝不能按 [,:;] 拆，只能按逗号/换行拆，
      // 否则每个盘符路径会被切成两段（旧日志 shader=4 就是这么来的）。
      //
      // ⚠️ 但「读回非空」**只证明属性被接受，不证明 pass 真的执行**：
      // 2026-09-14 真机实测存在读回两个路径、`vo-passes` 里 0 个用户着色器
      // pass 的静默失效。真正的判据是 [Anime4KManager.userShaderPassCount]
      // 读 `vo-passes`，由 [_startDiag] 持续校验并在必要时自愈（[_healSrPipeline]）。
      final back = (await dyn.getProperty('glsl-shaders'))?.toString() ?? '';
      final applied = (!_sr.enabled && (back.isEmpty)) ||
          (_sr.enabled &&
              back
                  .split(RegExp('[,\\n]'))
                  .where((s) => s.trim().isNotEmpty)
                  .isNotEmpty);
      // shader 编译发生在下一帧渲染时（异步），列表非空不代表编译成功。
      // 等一个短窗口收集 mpv 的编译错误（p.stream.log → _srFault），
      // 让「未生效」能被如实告知而不是误报已启用。
      if (applied && !silent) {
        // 编译失败日志可能晚到（vo 重建/首次渲染才触发），窗口给足 2 秒。
        await Future<void>.delayed(const Duration(milliseconds: 2000));
      }
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
      if (!silent && mounted) {
        _toast('超分应用失败，请重试');
        ErrorLogger.instance.warn('superres apply failed: $e');
      }
    } finally {
      if (!silent && mounted) setState(() => _srApplying = false);
    }
  }

  void _setSr(String id) {
    if (!DesktopUi.isDesktopPlatform) return;
    setState(() => _srId = id);
    _applySr();
    _savePrefs();
  }

  /// 显示同步：mpv 原生 video-sync 调优（治卡顿，与画质无关）。
  ///
  /// 用途：把 video-sync 切到 `display-resample`，消除 audio 同步在 60Hz 屏上
  /// 的 3:2 拉扯抖动（"连 24 帧都没有、一顿一顿"）。这是播放体验的基线，
  /// 不是用户可见的"功能开关"——UI 不提供开关，启动/首帧后统一自动设置。
  ///
  /// 平台：**所有平台都走**。display-resample 是 mpv 内置显示同步（无音轨时
  /// 自动回退 audio），不依赖桌面专属能力（无 shader/无超分/无 GPU 调优），
  /// 是治「60Hz 屏上一顿一顿」的基线，不是画质功能——2026-09-16 曾误把
  /// 它也划进「桌面专属」整体关闭，导致移动端回归默认 audio-sync 抖动。
  /// 移动端只关桌面画质链（[_applyEnhance]/[_applySr]/[_healSrPipeline]）。
  ///
  /// 倍速防线：本函数**探测显示时钟 + 音轨**，两者都可靠才用 display-resample，
  /// 任一不可靠则退回 `audio` 同步（恒 1 倍速）。mpv 原生 `interpolation`
  /// （旧「补帧」档）已于 2026-09-19 移除——它不是 AI 插帧，且在显示时钟
  /// 不可靠的机器上无法安全生效；真插帧走 VapourSynth/RIFE 引擎链。
  Future<void> _applySync() async {
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    // web 端 NativePlayer 是 stub（无 libmpv），用 dynamic 分发让调用
    // 直接失败被吞掉，行为等价于「web 无同步」。
    final dyn = native as dynamic;
    try {
      // ── 同步模式选型（2026-09-19 重写，根治「什么都没开也倍速」）──
      // 背景：mpv 上游已知 bug（#18177/#10489/#11478，长期 open）——
      // display-resample 的恒定 1 倍速**依赖 `estimated-display-fps`**，而该
      // 估算在窗口跨屏 / ANGLE / 远程桌面 / 合成器故障时可能读到垃圾值
      // （本机实测 edisp=4211→5512→6706→8922Hz，正常应 60/120/144）。
      // 显示时钟错了，mpv 就按错时钟追帧 → 视频被倍速播放，且与任何
      // 插帧/倍速开关无关（正好对应用户「我什么都没开，1 倍速，视频却是
      // 倍速的」）。所以正确做法不是硬设某个 sync，而是**探测显示时钟，
      // 不可靠就退回 `audio` 同步**——audio 同步以音频时钟为基准，恒 1 倍速，
      // 永不倍速（宁可丢流畅也不变速）。
      final targetSync = 'display-resample';
      // 目标刷新率：60Hz 兜底（Windows ANGLE 读不到真实刷新率时）。
      const targetFps = 60;
      // 合理显示刷新率区间：正常屏幕 30~250Hz。低于/高于此区间说明
      // estimated-display-fps 是垃圾值（如远程桌面/ANGLE/双屏估算错误），
      // display-resample 不可信，必须退回 audio 同步。
      const kMinDispFps = 30.0;
      const kMaxDispFps = 250.0;

      // 读当前实际生效的显示刷新率估算。空/读错 → 不可信 → 走 audio。
      double dispFps = 0;
      try {
        final edfps = await dyn.getProperty('estimated-display-fps');
        dispFps = double.tryParse(edfps?.toString() ?? '') ?? 0;
      } catch (_) {}
      final dispOk = dispFps >= kMinDispFps && dispFps <= kMaxDispFps;

      // ── 音频感知（根治「倍速」）──
      // display-resample 的稳定 1 倍速**依赖音轨作为时间基准**：有音轨时
      // 它重采样音频贴合视频，速度恒定；**无音轨**时 mpv 没有音频时钟，
      // 改用显示刷新率追赶视频 → 按 60/24 ≈ 2.5 倍加速播放。故先探测
      // 音轨：无音轨则**不切** display-resample
      // （退回 audio 同步，恒 1 倍速）。
      bool hasAudio = true;
      try {
        final aid = await dyn.getProperty('aid');
        hasAudio = aid != null && aid != 'no' && !(aid is int && aid <= 0);
        // 二次确认：aid 只说明「轨道存在」，不代表音频设备**此刻真的在
        // 输出**——设备被独占（如用户另跑音频占用程序）、网络流音轨尚未
        // 解码、wasapi 独占被占等情况下，aid 非 no 但实际无音频时钟。
        // display-resample 在没有音频时钟时会按显示时钟追赶视频 → 倍速。
        // 读 audio-params/channels 确认音频通路真的活着：读不到/为 0/出错
        // 一律按无音轨处理（退回 audio 同步，恒 1 倍速）。
        if (hasAudio) {
          final ach = await dyn.getProperty('audio-params/channels');
          final a = ach?.toString() ?? '';
          hasAudio = a.isNotEmpty && !a.contains('ERR') && a != '0';
        }
      } catch (_) {}
      // 最终决策：显示时钟可信 **且** 音轨在 → display-resample（平滑）；
      // 任一不可靠 → audio 同步（恒 1 倍速，绝不倍速）。
      //
      // 2026-09-19 用户机器实测定案：
      //   * `estimated-display-fps`（edisp）是 mpv 实际用于追帧的估算值；
      //     用户机器实测 edisp=419~525Hz 垃圾值 → mpv 按错时钟追帧 → 实时
      //     倍速（speed 属性读回恒 1.0 不可信）。
      //   * `display-fps` 恒 60 可读，但它只反映**标称刷新率**，不能证明
      //     mpv 的实际重采样时钟可靠——用它放行是上一版回归的根源。
      //   → 结论：edisp 不可靠（? 或 30~250 之外）时**绝不进任何
      //     display-resample 系**。墙钟观测（time-pos vs 墙钟，日志 `wrate=`）
      //     在诊断循环兜底，防探测不到的时钟错误。
      final effectiveSync = (dispOk && hasAudio) ? targetSync : 'audio';

      // 1) 同步模式**最先设、独立容错**——这是治卡顿的前提。旧写法把
      //    video-sync 紧跟在插帧属性之后且不单独容错，一旦某构建不支持
      //    运行时改该属性就整段抛出被外层吞掉，video-sync 根本没设上 →
      //    退回默认 audio 同步 → 卡顿照旧（"改了没用"的元凶）。
      try {
        await dyn.setProperty('video-sync', effectiveSync);
      } catch (_) {}
      // 2) 加速上限兜底：`video-sync-max-factor` 是整数选项（mpv 源码
      //    M_RANGE(1,10)），默认 10 = 视频最多被加速到 10 倍速。钉到 1 收紧
      //    相对速率调整。⚠️ 2026-09-19 实测定案：它**挡不住** edisp 垃圾值
      //    引起的倍速——max-factor 限制的是「相对基准速率的调整幅度」，
      //    而 edisp=500Hz 时 mpv 把 500 当正常刷新率、自认 1 倍速，基准本身
      //    就是错的，相对限制等于没挡（用户机器实测 max-factor=1 时仍倍速，
      //    speed 属性还恒读回 1.0）。真正的防线是 _applySync 的 edisp 探测
      //    + 诊断循环的墙钟守卫，这里仅作为兜底保留。
      try {
        await dyn.setProperty('video-sync-max-factor', '1');
      } catch (_) {}
      // 3) 固定目标刷新率兜底 60Hz。仅桌面端（Windows ANGLE 读不到真实
      //    刷新率）需要锁死；移动端（Android/iOS）真实 display-fps 可读，
      //    不 override —— 90/120Hz 高刷屏上让 mpv 跟随真实刷新率，避免
      //    被锁成 60Hz 反而失去高刷优势（真机高刷屏上 override 会导致
      //    额外抖动）。它是 option 不是 property，走 command set。
      try {
        if (DesktopUi.isDesktopPlatform) {
          await dyn.command(['set', 'override-display-fps', '$targetFps']);
        }
      } catch (_) {}
    } catch (_) {
      // 显示同步失败不影响播放本身，静默跳过（UI 不展示）。
    }
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

  /// 快捷键 `[`/`]` 倍速：在 `_speedSteps` 档位内按 dir 步进到相邻档位。
  /// 若当前值恰好是某档位，直接步进；若落在档位之间（如 2.5x），
  /// 先就近吸附到最近档位（等距时向下取），再按 dir 步进。
  void _stepSpeed(int dir) {
    final steps = _speedSteps;
    var i = 0;
    for (var k = 0; k < steps.length; k++) {
      if ((_speed - steps[k]).abs() < (_speed - steps[i]).abs()) i = k;
    }
    final next = (i + dir).clamp(0, steps.length - 1);
    _setSpeed(steps[next]);
  }

  void _seekTo(Duration d) {
    final target = d < Duration.zero
        ? Duration.zero
        : (_dur > Duration.zero && d > _dur ? _dur : d);
    // 守卫用它区分「刻意 seek」与「mpv HLS seek 失败倒卷」——刻意 seek
    // 后 position 的回退放行 3s，超窗仍判异常。
    _lastSeekCmd = DateTime.now();
    _player?.seek(target);
    setState(() {
      _pos = target;
      // 用户主动 seek 本身就是新锚点：回拉/跳到更早处时把稳定位置同步压到
      // target，否则 _stablePos 仍留旧大值，3s 过窗后守卫会把用户又拉回
      // 中间（附件 #11 主动 seek 误伤）。
      if (target < _stablePos) _stablePos = target;
    });
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
    // 位置阈值校验：mpv 的 completed（eof-reached）在流异常中断/换源时
    // 也可能触发。只有确认已播到结尾（距时长 ≤5s）才视为真播完；否则
    // 仅暂停、不置位 _completedHandled，避免后续真播完被误拦截（混广告
    // 换源/断流重连可能触发伪 completed）。
    if (_dur > Duration.zero &&
        _pos < _dur - const Duration(seconds: 5)) {
      ErrorLogger.instance.debug(
          'completed but not at end: pos=${_pos.inSeconds}s dur=${_dur.inSeconds}s; treat as interrupted');
      if (mounted) setState(() => _playing = false);
      return;
    }
    if (_completedHandled) return;
    _completedHandled = true;
    if (mounted) setState(() => _playing = false);
    if (_hasNext) {
      _toast('即将播放下一集…');
      final gen = _switchGen;
      Future.delayed(const Duration(milliseconds: 900), () {
        // 延迟期间用户可能手动切集/退出：只有仍停留在刚完成的那一集、
        // 且没有新切集动作时才自动播下一集，否则作废。
        if (mounted && gen == _switchGen) _goRelative(1);
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
    _switchGen++;
    setState(() {
      _switching = true;
      _ready = false;
      _buffering = true;
      _resumeTipVisible = false;
    });
    try {
      final url = await resolver(ep.season, ep.episode);
      if (!mounted) return;
      // 有些源换集后拿到的是网页地址而非直链，此时切到内嵌 WebView 通道
      // （同一 Route，不再 pushReplacement 跳另一播放页）。
      if (!isDirectMediaUrl(url)) {
        _player?.pause();
        setState(() {
          _webUrl = url;
          _webSeason = ep.season;
          _webEpisode = ep.episode;
          _curSeason = ep.season;
          _curEpisode = ep.episode;
          _useWeb = true;
          _webGeneration++;
          _ready = false;
          _switching = false;
        });
        return;
      }
      setState(() {
        _curSeason = ep.season;
        _curEpisode = ep.episode;
        _pos = Duration.zero;
        _dur = Duration.zero;
        _buffer = Duration.zero;
        _lastSavedSec = -1;
        // 换集后稳定位置同步清零：否则旧集的大位置会把本集断流重连的
        // 断点带偏（seek 回上一集的位置播）。
        _stablePos = Duration.zero;
      });
      await _open(url);
      // 换集后重新拉取该集弹幕
      setState(() {
        _danmaku = const [];
      });
      _loadDanmaku();
    } catch (e) {
      if (mounted) {
        _toast('切换失败，请重试');
        ErrorLogger.instance.warn('native player switch failed: $e');
        // 持久错误态（替代卡在"正在解析直链…"）：保留 mpv 通道当前画面，
        // 提供「重试/用网页播放」两个出口。
        setState(() {
          _failed = true;
          _failMsg = '切集失败：$ep.season 第 $ep.episode 集解析失败';
          _pendingRetryEp = ep;
          _ready = false;
          _buffering = false;
        });
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _fallbackWeb() {
    // 同一 Route 内切换到内嵌 WebView 通道，而非 pushReplacement 另一播放页。
    _player?.pause();
    if (mounted) {
      setState(() {
        final retry = _pendingRetryEp;
        if (retry != null) {
          // 切集失败后落到本页：让网页通道从失败目标集开始加载。
          _webSeason = retry.season;
          _webEpisode = retry.episode;
        }
        _webUrl = widget.url;
        _useWeb = true;
        _failed = false;
        _pendingRetryEp = null;
        _webGeneration++;
      });
    }
  }

  /// WebView 通道捕获到可直连媒体 URL 时，切回 mpv 通道（同一 Route）。
  /// AnimePlayerPage 会在接管成功后 _killWebMedia 杀网页媒体，这里只负责
  /// 隐藏 WebView 子树并尝试用直链 open mpv。返回 true 表示接管成功。
  Future<bool> _handoffWebToMpv(String src) async {
    if (!mounted) return false;
    // 该直链已确认打不开（源站失效/防盗链拒绝）：不再反复尝试，
    // 让 WebView 留在网页通道播放，避免循环失败。
    if (_rejectedHandoffs.contains(src)) return false;
    setState(() => _useWeb = false);
    if (!mounted) return false;
    _handoffOpening = true;
    _handoffSrc = src;
    final ok = await _open(src);
    _handoffOpening = false;
    if (!mounted) return false;
    if (ok) return true;
    // mpv 打不开（_open 或异步 error 已把该直链记入 _rejectedHandoffs）：
    // 留在网页通道（AnimePlayerPage 仍在树中），不叠加报错。
    if (mounted && !_useWeb) {
      setState(() {
        _rejectedHandoffs.add(src);
        _useWeb = true;
        _failed = false;
        _webGeneration++;
      });
    }
    return false;
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
    AppToast.show(context, msg, duration: const Duration(milliseconds: 1600));
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
      // 桌面端把系统窗口本体切到真全屏（占满屏幕），移动端保持沉浸+横屏。
      DesktopFullscreen.set(true);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      _locked = false;
      DesktopFullscreen.set(false);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _unlockOrientation();
    }
    _bumpControls();
  }

  /// 进入系统画中画（Android 8+）：退出当前 UI 前先把视频纹理交给系统
  /// PiP 窗口；成功后 Activity 转小窗，播放不中断。非 Android 静默忽略
  /// （走手动的 [_minimizeToPip] App 内小窗）。
  Future<void> _toggleSystemPip() async {
    if (_vw > 0 && _vh > 0) {
      await PipChannel.setAspectRatio(_vw, _vh);
    }
    final ok = await PipChannel.enter();
    if (!ok && mounted) {
      AppToast.error(context, '当前设备不支持画中画');
      _bumpControls();
    }
  }

  /// 画中画：把当前 Player 移交迷你播放器并退出本页。
  ///
  /// 所有权转移：Player 仍持有真实播放（声音不中断），本页 dispose 不再
  /// 销毁它（_skipPlayerDispose 置位）；恢复时由 MainShell 取回重建页面。
  void _minimizeToPip() {
    final p = _player;
    if (p == null) return;
    // 保存当前快照，供小窗重建/续播使用。
    final h = widget.take;
    final histKey = widget.historyKey ??
        (widget.sourceId != null && widget.videoId != null
            ? '${widget.sourceId}::${widget.videoId}::$_curSeason-$_curEpisode'
            : '${widget.title}::${_curSeason}_$_curEpisode');
    _skipPlayerDispose = true;
    PlayerRegistry.publish(PlayerHandoff(
      player: p,
      url: h?.url ?? widget.url,
      title: widget.title,
      cover: widget.cover,
      position: _pos,
      speed: _speed,
      season: _curSeason,
      episode: _curEpisode,
      episodes: widget.episodes,
      sourceNames: widget.sourceNames,
      resolveUrl: widget.resolveUrl,
      sourceId: widget.sourceId,
      videoId: widget.videoId,
      historyKey: histKey,
      volume: (p.state.volume).round(),
      muted: _volume <= 0,
    ));
    // 全屏 → 竖屏回主界面悬停小窗
    if (_fullscreen) {
      _fullscreen = false;
      DesktopFullscreen.set(false);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _unlockOrientation();
    }
    Navigator.of(context, rootNavigator: true).maybePop();
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
    // 拖拽 seek 时暂停播放，松手自动续播（避免拖拽中画面跳变/声音噪声）
    _pauseBeforeSeek = _playing;
    if (_pauseBeforeSeek) _player?.pause();
    _gesture = _Gesture.seek;
    _seekStart = _pos;
    _seekTarget = _pos;
    _showHud(_Gesture.seek, keep: false);
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
    // 拖拽过程中持续重置自动隐藏计时器，避免中央进度预览在手势中途消失
    // （_showHud 默认 keep=true 会一直挂住，见下方 keep:false 修复）。
    _showHud(_Gesture.seek, keep: false);
  }

  void _onHorizontalEnd(DragEndDetails d) {
    if (_gesture == _Gesture.seek) {
      _seekTo(_seekTarget);
      // 拖拽前在播放 → 松手续播
      if (_pauseBeforeSeek) _player?.play();
    }
    _pauseBeforeSeek = false;
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
  // 连点 seek：800ms 内同侧再次双击，seek 幅度翻倍（Aniyomi 式连点快进）
  DateTime _lastDoubleTapAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _tapSide = 0; // 0=无, 1=左(回退), 2=右(快进)
  int _tapStreak = 0;

  void _onDoubleTap(Size size) {
    if (_locked) return;
    final x = _lastTapPos.dx;
    final now = DateTime.now();
    final side = x < size.width * 0.35
        ? 1
        : (x > size.width * 0.65 ? 2 : 0);
    if (side == 0) {
      _togglePlay();
      _tapStreak = 0;
      _tapSide = 0;
      return;
    }
    if (side == _tapSide &&
        now.difference(_lastDoubleTapAt).inMilliseconds <= 800) {
      _tapStreak++;
    } else {
      _tapStreak = 1;
      _tapSide = side;
    }
    _lastDoubleTapAt = now;
    // 连点累计幅度：第 1 次 10s，之后每次 +10s，上限 60s
    final amount = (_tapStreak * 10).clamp(10, 60);
    _seekBy(side == 1 ? -amount : amount);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _clockTimer?.cancel();
    _resumeTipTimer?.cancel();
    _diagTimer?.cancel();
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
    // 画中画移交后 Player 归迷你播放器所有，本页不再销毁（避免声音中断）。
    if (!_skipPlayerDispose) {
      _player?.dispose();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _unlockOrientation();
    // 离开播放页时还原桌面窗口（防全屏状态残留：下次进播放器仍是整屏窗口）
    DesktopFullscreen.set(false);
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.removeHandler(_keyHandler);
    }
    super.dispose();
  }

  /// 桌面端播放快捷键：空格 播放/暂停、←/→ 快退/快进 10s、
  /// ↑/↓ 音量、M 静音、F 全屏、Esc 隐藏/显示控制层。
  /// 扩展：0-9 跳转进度、[ / ] 倍速、N/P 切集、T 音轨、B 弹幕开关、
  /// C 弹幕设置、I 画中画。
  bool _keyHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _toggleControls();
      return true;
    }
    // 数字键：跳转进度 0%…90%（按集时长折算秒数）。
    // LogicalKeyboardKey 重写了 ==/hashCode，不能作 const map key。
    final d = switch (event.logicalKey) {
      LogicalKeyboardKey.digit0 => 0,
      LogicalKeyboardKey.digit1 => 1,
      LogicalKeyboardKey.digit2 => 2,
      LogicalKeyboardKey.digit3 => 3,
      LogicalKeyboardKey.digit4 => 4,
      LogicalKeyboardKey.digit5 => 5,
      LogicalKeyboardKey.digit6 => 6,
      LogicalKeyboardKey.digit7 => 7,
      LogicalKeyboardKey.digit8 => 8,
      LogicalKeyboardKey.digit9 => 9,
      _ => null,
    };
    if (d != null) {
      if (_dur > Duration.zero) {
        _seekTo(Duration(seconds: (_dur.inSeconds * d ~/ 10)));
      }
      return true;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _togglePlay();
        return true;
      // TV 遥控器媒体键：D-pad 中心键与播放/暂停、快进/快退、上下集映射到等价操作。
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlay();
        return true;
      case LogicalKeyboardKey.mediaFastForward:
      case LogicalKeyboardKey.arrowRight:
        _seekBy(10);
        return true;
      case LogicalKeyboardKey.mediaRewind:
      case LogicalKeyboardKey.arrowLeft:
        _seekBy(-10);
        return true;
      case LogicalKeyboardKey.mediaTrackNext:
        if (_hasNext) _goRelative(1);
        return true;
      case LogicalKeyboardKey.mediaTrackPrevious:
        if (_hasPrev) _goRelative(-1);
        return true;
      case LogicalKeyboardKey.arrowUp:
        _applyVolume((_volume + 0.1).clamp(0.0, 1.0));
        return true;
      case LogicalKeyboardKey.arrowDown:
        _applyVolume((_volume - 0.1).clamp(0.0, 1.0));
        return true;
      case LogicalKeyboardKey.keyM:
        _applyVolume(_volume > 0 ? 0 : 1);
        return true;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        return true;
      case LogicalKeyboardKey.keyB:
        _toggleDanmaku();
        return true;
      case LogicalKeyboardKey.keyC:
        _showDanmakuPanel();
        return true;
      case LogicalKeyboardKey.keyT:
        if (_audioTracks.length > 2) _showAudioTrackPanel();
        return true;
      case LogicalKeyboardKey.keyP:
        if (_hasPrev) _goRelative(-1);
        return true;
      case LogicalKeyboardKey.keyN:
        if (_hasNext) _goRelative(1);
        return true;
      case LogicalKeyboardKey.keyI:
        _minimizeToPip();
        return true;
      case LogicalKeyboardKey.bracketLeft:
        _stepSpeed(-1);
        return true;
      case LogicalKeyboardKey.bracketRight:
        _stepSpeed(1);
        return true;
      default:
        return false;
    }
  }

  /// 退出全屏/离开播放页时恢复方向：平板解锁跟随设备（横屏填满），
  /// 手机恢复竖屏避免卡横屏。dispose 中调用，不依赖 BuildContext。
  void _unlockOrientation() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final w = view.physicalSize.width / view.devicePixelRatio;
    final tablet = w >= Responsive.tabletBreakpoint;
    SystemChrome.setPreferredOrientations(tablet
        ? [
            DeviceOrientation.portraitUp,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : [DeviceOrientation.portraitUp]);
  }

  // ══════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    if (_failed) return _failedView();
    // 网页通道：同一 Route 内渲染 AnimePlayerPage 完整状态机（WebView +
    // 手势/亮度音量/选集/弹幕/全屏/直链捕获），不再跳另一个播放页。
    if (_useWeb) return _webChannelView();
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: buildPlayerBody(
          fullscreen: _fullscreen,
          isTablet: Responsive.isTablet(context),
          panelWidth: _controlPanelWidth(context),
          padding: MediaQuery.paddingOf(context),
          stage: _stage(),
          panel: _belowPanel(),
        ),
      ),
    );
  }

  /// 网页通道视图：直接渲染 AnimePlayerPage（完整 WebView 状态机：
  /// 手势/亮度音量/选集/弹幕/全屏/直链捕获/降级页），ValueKey 变更即重建。
  /// onDirectUrl 捕获直链时切回 mpv 通道，实现「一套播放器」双通道。
  Widget _webChannelView() {
    return AnimePlayerPage(
      key: ValueKey('web-$_webGeneration'),
      url: _webUrl,
      title: widget.title,
      cover: widget.cover,
      description: widget.description,
      episodes: widget.episodes,
      initialSeason: _webSeason,
      initialEpisode: _webEpisode,
      resolveUrl: widget.resolveUrl,
      sourceNames: widget.sourceNames,
      sourceId: widget.sourceId,
      videoId: widget.videoId,
      onDirectUrl: _handoffWebToMpv,
    );
  }

  Widget _failedView() {    return Scaffold(
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: _retryOpen,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _fallbackWeb,
                  icon: const Icon(Icons.language),
                  label: const Text('用网页播放'),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  /// 失败页「重试」：清错误态并重新打开失败目标集（切集失败时重试该集，
  /// 而非初始集），直链解析/首帧等待各带超时。
  Future<void> _retryOpen() async {
    if (_retrying) return;
    _retrying = true;
    setState(() {
      _failed = false;
      _failMsg = '播放失败：未知错误';
    });
    try {
      final retry = _pendingRetryEp;
      bool ok;
      if (retry != null) {
        _pendingRetryEp = null;
        await _switchTo(retry);
        ok = !_failed;
      } else {
        ok = await _open(widget.url);
      }
      if (!ok && mounted) {
        setState(() {
          _failed = true;
          _failMsg = _failMsg.isEmpty ? '播放失败' : _failMsg;
        });
      }
    } finally {
      _retrying = false;
    }
  }

  /// 缓冲/加载中提示文案：已有进度数据时给百分比，否则给阶段说明。
  String _bufferText() {
    if (_switching) return '正在解析直链…';
    if (_ready && _buffering) {
      final d = _dur.inMilliseconds;
      final b = _buffer.inMilliseconds;
      if (d > 0) {
        final pct = (b * 100 / d).clamp(0, 100).toInt();
        return '缓冲中 $pct%';
      }
    }
    return '加载中…';
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
          // 本地字幕层（SRT）：随播放进度显示当前命中字幕
          Positioned.fill(
            child: IgnorePointer(
              child: SubtitleOverlay(
                index: _subtitles,
                positionMs: _pos.inMilliseconds,
                fontSize: _fullscreen ? 24 : 18,
              ),
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
              onTapUp: (_) {
                _tapStreak = 0;
                _tapSide = 0;
                _toggleControls();
              },
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
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 38,
                    height: 38,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.6, color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _bufferText(),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12.5),
                  ),
                ],
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
                  label: _srApplying
                      ? '超分启用中…'
                      : (_srFault != null ? '超分未生效' : _srBadgeLabel()),
                ),
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
                // 全屏时显示真实渲染信息（每 2 秒从 mpv 采样，非硬编码）：
                // 输出分辨率（超分/缩放后的真实值）+ 输出帧率（源帧率）。
                // 没有采样到就不显示，绝不推断。
                if (_fullscreen &&
                    ((_outW > 0 && _outH > 0) || _outFps > 0))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        if (_outW > 0 && _outH > 0) '$_outW×$_outH',
                        if (_outFps > 0)
                          '${_outFps >= 60 ? _outFps.toStringAsFixed(0) : _outFps.toStringAsFixed(1)} fps',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10.5,
                          color: Colors.white54,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
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
            // 画中画：缩小到悬浮小窗继续播放（全屏时更靠前，号角清晰）
            _barBtn(
              Icons.picture_in_picture_alt_rounded,
              _minimizeToPip,
              active: true,
            ),
            const SizedBox(width: 2),
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
                enabled: !_locked,
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
                  // keep:false → 松手 700ms 后中央进度预览自动消失，
                  // 否则它只会被 _scheduleHide 隐藏控制条、自己永远挂着。
                  _showHud(_Gesture.seek, keep: false);
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
                enabled: !_locked,
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
                  // keep:false → 松手 700ms 后中央进度预览自动消失（见 _bottomBarCompact）。
                  _showHud(_Gesture.seek, keep: false);
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
              if (!_srAndroidOff)
                _textBtn(_srFault != null ? '未生效' : (_sr.enabled ? _sr.name : '超分'),
                    _showSrPanel,
                    icon: Icons.auto_awesome_rounded, active: _sr.enabled),
              _textBtn(_fitNames[_fitIndex], _showFitPanel,
                  icon: Icons.aspect_ratio_rounded, active: _fitIndex != 0),
              // 多音轨时展示音轨切换；单音轨不占位
              if (_audioTracks.length > 2)
                _textBtn('音轨', _showAudioTrackPanel,
                    icon: Icons.music_note_rounded),
              if (widget.episodes.isNotEmpty)
                _textBtn('选集', _showEpisodePanel,
                    icon: Icons.playlist_play_rounded),
              // 系统画中画：仅 Android（原生通道安装成功）显示；非 Android
              // 走 App 内小窗（_minimizeToPip），入口在左上返回位。
              if (PipChannel.inPip != null)
                _barBtn(Icons.picture_in_picture_alt_rounded, _toggleSystemPip),
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
                overflow: TextOverflow.ellipsis,
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
    final base = Theme.of(context).colorScheme;
    // 平板分栏右侧面板深色配色，与 AnimePlayerPage 保持一致
    final scheme = Responsive.isTablet(context)
        ? ColorScheme.fromSeed(
            seedColor: base.primary, brightness: Brightness.dark)
        : base;
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
            // 画面实际渲染尺寸（mpv `dwidth`/`dheight`，VO 真正绘制的尺寸），
            // 每 2 秒从 mpv 采样，不硬编码推断。
            // ⚠️ 不要用 video-out-params 充当这个值：它在滤镜链就截断了，
            // Anime4K 在更后面的 VO 着色器阶段执行，拿它永远是源尺寸。
            if (_outW > 0 && _outH > 0)
              _metaChip(scheme, '$_outW×$_outH', icon: Icons.hd_rounded),
            // 真实渲染帧率：estimated-vf-fps 是滤镜链估计的实际输出帧率
            //（插帧已移除，约等于源容器帧率）。
            if (_outFps > 0)
              _metaChip(
                  scheme,
                  '${_outFps >= 60 ? (_outFps >= 120 ? _outFps.toStringAsFixed(0) : _outFps.toStringAsFixed(1)) : _outFps.toStringAsFixed(1)} fps',
                  icon: Icons.speed_rounded),
            if (_speed != 1.0)
              _metaChip(scheme, '${_trimSpeed(_speed)}x',
                  icon: Icons.speed_rounded),
            if (_sr.enabled)
              _metaChip(scheme, _srFault != null ? '超分未生效' : _sr.name,
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
          if (!_srAndroidOff) ...[
            _srCard(scheme),
            const SizedBox(height: 10),
          ],
          Row(children: [
            Expanded(
                child: _miniCard(scheme, Icons.speed_rounded, '倍速',
                    '${_trimSpeed(_speed)}x', _showSpeedPanel)),
            const SizedBox(width: 10),
            Expanded(
                child: _miniCard(scheme, Icons.aspect_ratio_rounded, '画面',
                    _fitNames[_fitIndex], _showFitPanel)),
            if (!_srAndroidOff) ...[
              const SizedBox(width: 10),
              Expanded(
                  child: _miniCard(
                      scheme,
                      Icons.tune_rounded,
                      '画质增强',
                      _enhance ? '已开启' : '已关闭',
                      () => _setEnhance(!_enhance),
                      active: _enhance)),
            ],
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _miniCard(
                    scheme,
                    Icons.subtitles_rounded,
                    '字幕',
                    _subtitleName.isEmpty ? '未加载' : _subtitleName,
                    _showSubtitlePanel,
                    active: _subtitles != null)),
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
    final fault = _srFault;
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
          color: on
              ? null
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                    Flexible(
                      child: Text('Anime4K 超分',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: on
                              ? PlayerColors.sr.withValues(alpha: 0.2)
                              : scheme.onSurface.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          on ? (fault != null ? '未生效' : _sr.name) : '关闭',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: on
                                  ? PlayerColors.sr
                                  : scheme.onSurface.withValues(alpha: 0.6))),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(fault ?? _sr.desc,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color: fault != null
                              ? const Color(0xFFFF8A65)
                              : scheme.onSurface.withValues(alpha: 0.6))),
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
    return KeyedSubtree(
      // 当前集方块挂定位锚点：选集面板打开时滚进视口。
      key: cur ? _curEpKey : null,
      child: InkWell(
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
      title: '超分',
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
              activeThumbColor: PlayerColors.sr,
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
            const SizedBox(height: 6),
            const Divider(color: Colors.white12, height: 18),
            const SizedBox(height: 4),
            if (_srFault != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 13, color: Color(0xFFFF8A65)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '着色器未生效：$_srFault',
                      style: const TextStyle(
                          color: Color(0xFFFF8A65), fontSize: 10.5, height: 1.3),
                    ),
                  ),
                ]),
              ),
            Row(children: [
              const Icon(Icons.info_outline_rounded,
                  size: 13, color: Colors.white30),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _srHintText(),
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

  /// 本地视频自动匹配同目录同名 SRT（如 a.mp4 → a.srt / a.zh.srt / a.zh-CN.srt）。
  /// 仅本地 `file://` 播放生效，网络直链跳过。
  Future<void> _autoMatchSubtitle() async {
    final url = widget.url;
    if (!url.startsWith('file://')) return;
    final videoPath = url.replaceFirst('file://', '');
    final dir = File(videoPath).parent;
    if (!dir.existsSync()) return;
    final base = File(videoPath).uri.pathSegments.last;
    final stem = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
    final candidates = <String>[
      '$stem.srt',
      '$stem.zh.srt',
      '$stem.zh-CN.srt',
      '$stem.chs.srt',
      '$stem.zh-Hans.srt',
    ];
    File? match;
    for (final c in candidates) {
      final f = File('${dir.path}${Platform.pathSeparator}$c');
      if (f.existsSync()) {
        match = f;
        break;
      }
    }
    if (match == null) return;
    try {
      final cues = SubtitleSrt.parseBytes(await match.readAsBytes());
      if (cues == null || cues.isEmpty || !mounted) return;
      setState(() {
        _subtitles = SubtitleIndex(cues);
        _subtitleName = match!.uri.pathSegments.last;
      });
    } catch (e) {
      ErrorLogger.instance.warn('[subtitle] 自动匹配字幕解析失败: $e');
    }
  }

  /// 选择/加载本地 SRT 字幕文件。
  Future<void> _pickSubtitle() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择字幕文件（SRT）',
        type: FileType.custom,
        allowedExtensions: ['srt'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final f = result.files.single;
      // 优先用内存字节（withData），否则读路径文件。
      var bytes = f.bytes;
      if (bytes == null) {
        if (f.path == null) return;
        final file = File(f.path!);
        if (!file.existsSync()) return;
        bytes = await file.readAsBytes();
      }
      final cues = SubtitleSrt.parseBytes(bytes);
      if (cues == null || cues.isEmpty) {
        _toast('字幕解析失败：不支持的编码或格式');
        return;
      }
      setState(() {
        _subtitles = SubtitleIndex(cues);
        _subtitleName = f.name;
      });
      _toast('已加载字幕：${f.name}（${cues.length} 条）');
    } catch (e) {
      ErrorLogger.instance.warn('[subtitle] 加载字幕失败: $e');
      _toast('加载字幕失败');
    }
  }

  /// 清除当前字幕。
  void _clearSubtitle() {
    setState(() {
      _subtitles = null;
      _subtitleName = '';
    });
  }

  /// 字幕面板：加载 / 已加载展示 / 清除。
  void _showSubtitlePanel() {
    _hideTimer?.cancel();
    showPlayerPanel(
      context: context,
      title: '本地字幕',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final has = _subtitles != null;
        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (has)
              PanelOptionTile(
                title: '已加载：$_subtitleName',
                subtitle: '${_subtitles!.cues.length} 条字幕',
                selected: true,
                onTap: () {},
              ),
            PanelOptionTile(
              title: '加载 SRT 字幕…',
              subtitle: '同目录同名 .srt 亦自动匹配',
              selected: false,
              onTap: () {
                _pickSubtitle();
                setSheet(() {});
              },
            ),
            if (has)
              PanelOptionTile(
                title: '清除字幕',
                subtitle: null,
                selected: false,
                onTap: () {
                  _clearSubtitle();
                  setSheet(() {});
                },
              ),
            const SizedBox(height: 6),
            const Text('支持 SRT 字幕（UTF-8 / UTF-16 编码），倍速下自动同步',
                style: TextStyle(color: Colors.white30, fontSize: 11)),
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
        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // 速览 chips：点选即生效，不用再翻到底部
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _speedSteps.map((s) {
                final sel = _speed == s;
                return InkWell(
                  onTap: () {
                    _setSpeed(s);
                    setSheet(() {});
                  },
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 9),
                    decoration: BoxDecoration(
                      color: sel
                          ? PlayerColors.accent.withValues(alpha: 0.22)
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: sel
                            ? PlayerColors.accent
                            : Colors.white24,
                        width: sel ? 1.4 : 1,
                      ),
                    ),
                    child: Text(
                      '${_trimSpeed(s)}x',
                      style: TextStyle(
                        color: sel ? PlayerColors.accent : Colors.white,
                        fontSize: 13,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            ..._speedSteps.map((s) => PanelOptionTile(
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

  /// 音轨切换面板：列出多音轨（语言/标题），点选即切换。
  ///
  /// 直链含多音轨时自动显示入口；单音轨（仅 auto/no）时面板仍可打开，
  /// 展示"当前音轨"，无多余项时给出提示。
  void _showAudioTrackPanel() {
    _hideTimer?.cancel();
    showPlayerPanel(
      context: context,
      title: '音轨切换',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final p = _player;
        final tracks = _audioTracks;
        final current = p?.state.track.audio;
        final list = tracks.isEmpty ? <AudioTrack>[] : tracks;
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(14),
            child: Text('当前片源未提供多音轨',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          );
        }
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (final t in list)
            PanelOptionTile(
              title: t.title ?? t.language ?? '音轨 ${t.id}',
              subtitle: _audioTrackSubtitle(t),
              selected: current?.id == t.id ||
                  (current?.id == 'auto' && (t.isDefault ?? false)),
              onTap: () {
                if (p != null) p.setAudioTrack(t);
                setSheet(() {});
              },
            ),
        ]);
      }),
    ).then((_) => _scheduleHide());
  }

  static String? _audioTrackSubtitle(AudioTrack t) {
    final parts = <String>[];
    if (t.language != null && t.language!.isNotEmpty) {
      parts.add('语言 ${t.language}');
    }
    if (t.codec != null) parts.add(t.codec!);
    if (t.channels != null && t.channels!.isNotEmpty) {
      parts.add(t.channels!);
    }
    if (t.isDefault ?? false) parts.add('默认');
    return parts.isEmpty ? null : parts.join(' · ');
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
        _scrollCurrentEpisodeIntoView(); // 打开即把当前集滚进视口
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

  /// 把当前集方块滚进视口（选集面板/竖屏选集区共用）。
  /// GlobalKey 在同一个 Grid 里只能挂在一个元素上：选集面板是独立动态子树，
  /// 与竖屏面板的 _episodeGrid 不会同时挂载，天然隔离。
  void _scrollCurrentEpisodeIntoView({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _curEpKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: immediate
            ? Duration.zero
            : const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.5, // 垂直居中：避免面板很高时当前集沉在视口底部边缘
      );
    });
  }

  String _downloadSubtitle() {
    final sid = widget.sourceId;
    final vid = widget.videoId;
    if (sid == null || vid == null) return '当前片源不支持下载';
    final key = '$sid::$vid::$_curSeason-$_curEpisode';
    final t = VideoDownloadManager.instance.taskOf(key);
    if (t == null) return '保存到本地，可离线播放';
    switch (t.state) {
      case 'downloading':
        final p = (t.progress * 100).round();
        return '下载中 $p%';
      case 'done':
        return '已下载 · 点击重新下载';
      case 'failed':
        final err = t.error ?? '';
        return err.isEmpty ? '下载失败 · 点击重试' : '下载失败：$err';
      case 'canceled':
        return '已取消 · 点击重试';
      default:
        return '保存到本地，可离线播放';
    }
  }

  Future<void> _startDownload() async {
    final sid = widget.sourceId;
    final vid = widget.videoId;
    if (sid == null || vid == null) {
      _toast('当前片源不支持下载');
      return;
    }
    String url = widget.url;
    final resolver = widget.resolveUrl;
    if (resolver != null) {
      try {
        final resolved = await resolver(_curSeason, _curEpisode);
        if (isDirectMediaUrl(resolved)) url = resolved;
      } catch (_) {}
    }
    if (url.isEmpty || !url.startsWith('http')) {
      _toast('无法获取本集直链');
      return;
    }
    String referer = '';
    try {
      final u = Uri.parse(url);
      referer = '${u.scheme}://${u.host}/';
    } catch (_) {}
    await VideoDownloadManager.instance.start(
      sourceId: sid,
      videoId: vid,
      title: widget.title,
      season: _curSeason,
      episode: _curEpisode,
      url: url,
      headers: referer.isEmpty ? const {} : {'Referer': referer},
    );
    _toast('开始下载 ${widget.title} 第$_curEpisode集');
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
            if (!_srAndroidOff)
              PanelOptionTile(
                title: '超分',
                subtitle:
                    '${_sr.name}${_enhance ? ' · 画质增强开' : ''}',
                selected: false,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showSrPanel();
                },
              ),
            PanelOptionTile(
              title: '音轨切换',
              subtitle: _audioTracks.length > 2
                  ? '共 ${_audioTracks.length - 2} 条音轨可选'
                  : '当前片源未提供多音轨',
              selected: false,
              onTap: () {
                Navigator.of(ctx).pop();
                _showAudioTrackPanel();
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
            PanelOptionTile(
              title: '下载本集',
              subtitle: _downloadSubtitle(),
              selected: false,
              onTap: () {
                Navigator.of(ctx).pop();
                _startDownload();
              },
            ),
            PanelOptionTile(
              title: '画中画',
              subtitle: '缩小为悬浮小窗继续播放',
              selected: false,
              onTap: () {
                Navigator.of(ctx).pop();
                _minimizeToPip();
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

/// 播放主体布局（稳定树位）：舞台（Video/Texture）在任何模式下都挂在
/// 同一父链的同一槽位（Stack index 0），全屏切换只改变 Positioned 的
/// 矩形，绝不销毁重建 Video 子树。
///
/// 根因（2026-09-21 实测）：旧实现 `body: fullscreen ? stage : Column[
/// AspectRatio(stage), panel]` 父链类型不同且无 GlobalKey → 全屏时
/// Video/Texture 被销毁重建，media_kit 的 Windows 渲染在纹理重挂载后
/// 不再向新纹理推帧 → 画面定格、只剩声音（mpv 时钟与 DIAG 全程正常，
/// 退出全屏再重建一次才恢复）。
@visibleForTesting
Widget buildPlayerBody({
  required bool fullscreen,
  required bool isTablet,
  required double panelWidth,
  required EdgeInsets padding,
  required Widget stage,
  required Widget panel,
}) {
  return LayoutBuilder(builder: (context, box) {
    final w = box.maxWidth;
    final h = box.maxHeight;
    if (fullscreen) {
      return Stack(children: [
        Positioned.fill(child: stage),
      ]);
    }
    final Rect stageRect;
    final Rect panelRect;
    if (isTablet) {
      // 左舞台右面板：舞台在剩余区域内按 16:9 居中（对齐旧 Row 布局）
      final areaW = math.max(0.0, w - panelWidth - padding.left - padding.right);
      final areaH = math.max(0.0, h - padding.top);
      final sw = math.min(areaW, areaH * 16 / 9);
      final sh = sw * 9 / 16;
      stageRect = Rect.fromLTWH(
        padding.left + (areaW - sw) / 2,
        padding.top + (areaH - sh) / 2,
        sw,
        sh,
      );
      panelRect = Rect.fromLTWH(w - panelWidth, 0, panelWidth, h);
    } else {
      // 上舞台下面板：舞台占满宽（减左右安全区），面板吃掉剩余高度
      final sw = math.max(0.0, w - padding.left - padding.right);
      final sh = sw * 9 / 16;
      stageRect = Rect.fromLTWH(padding.left, padding.top, sw, sh);
      panelRect = Rect.fromLTWH(padding.left, padding.top + sh, sw,
          math.max(0.0, h - padding.top - sh));
    }
    return Stack(children: [
      Positioned.fromRect(rect: stageRect, child: stage),
      Positioned.fromRect(
        rect: panelRect,
        child: isTablet
            ? DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Colors.white12, width: 0.8),
                  ),
                ),
                child: panel,
              )
            : panel,
      ),
    ]);
  });
}
