import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../net/error_logger.dart';
import '../net/http_client.dart';
import '../net/local_store.dart';
import '../sources/video_source.dart';
import '../utils/desktop_fullscreen.dart';
import '../utils/player_fullscreen.dart';
import '../utils/tv_platform.dart';
import 'desktop_webview.dart';
import 'episode_grouping.dart';
import 'native_player_page.dart';
import 'responsive.dart';
import 'style_scope.dart';
import 'style_tokens.dart';
import 'widgets/app_toast.dart';
import 'widgets/player_widgets.dart';

/// 直接可播视频直链判定 / 广告直链判定（定义见 sources/video_source.dart），
/// 在此 re-export 以兼容依赖本文件符号的既有调用方（含测试）。
export '../sources/video_source.dart' show isDirectMediaUrl, isAdMediaUrl;

/// B站风格 WebView 播放器：16:9 视频区 + 选集 + 简介 + 全屏 + 有声。
class AnimePlayerPage extends StatefulWidget {
  final String url;
  final String title;
  final String? cover;
  final String? description;
  final List<VideoEpisode> episodes;
  final int initialSeason;
  final int initialEpisode;
  final ValueChanged<int>? onEpisodeChanged;

  /// 解析指定集的播放直链，传入后原生播放器可在内部切集/自动连播。
  final Future<String> Function(int season, int episode)? resolveUrl;
  /// 播放源（线路）名称映射：season -> 源名，用于选集按源分组。
  final Map<int, String>? sourceNames;

  /// 所属数据源 id 与番剧 id：WebView 捕获直链切原生播放器时透传，
  /// 用于书架「动画记录」记录与续播。
  final String? sourceId;
  final String? videoId;

  /// 捕获到可直连媒体 URL 时交由外部处理（同一 Route 内切回 mpv 通道）。
  /// 为 null 时保持旧行为：本页内 pushReplacement 到 NativePlayerPage。
  /// 回调返回 true 表示外部接管成功（本页不再跳转）；false/null 走旧逻辑。
  final Future<bool> Function(String src)? onDirectUrl;

  const AnimePlayerPage({
    super.key,
    required this.url,
    required this.title,
    this.cover,
    this.description,
    this.episodes = const [],
    this.initialSeason = 1,
    this.initialEpisode = 1,
    this.onEpisodeChanged,
    this.resolveUrl,
    this.sourceNames,
    this.sourceId,
    this.videoId,
    this.onDirectUrl,
  });

  @override
  State<AnimePlayerPage> createState() => _AnimePlayerPageState();
}

/// 网页通道子树注入（依赖倒置）：native 播放器不 import 本文件，
/// 由各入口在构造 NativePlayerPage 时传入本闭包，实现同一 Route 内
/// 内嵌 WebView 双状态机协作（换集/切通道/直链捕获行为与原实现一致）。
WebChannelBuilder animePlayerWebChannel = (WebChannelArgs args) {
  return AnimePlayerPage(
    key: args.key,
    url: args.url,
    title: args.title,
    cover: args.cover,
    description: args.description,
    episodes: args.episodes,
    initialSeason: args.initialSeason,
    initialEpisode: args.initialEpisode,
    resolveUrl: args.resolveUrl,
    sourceNames: args.sourceNames,
    sourceId: args.sourceId,
    videoId: args.videoId,
    onDirectUrl: args.onDirectUrl,
  );
};

class _AnimePlayerPageState extends State<AnimePlayerPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final WebViewController _controller;
  DesktopWebview? _desktop;
  final List<StreamSubscription> _desktopSubs = [];
  bool _loading = true;
  bool _muted = false;
  bool _fullscreen = false;
  int _curSeason = 1;
  int _curEpisode = 1;
  /// 切集防重入：_switchingEp 拒绝并发切集；_switchGen 作废陈旧 await 后的覆写。
  bool _switchingEp = false;
  int _switchGen = 0;
  // 切集（_switchToEpisode 解析/装载）失败标记：错误态重试按钮据此
  // 重跑切集到目标集，而不是 reload 当前 WebView 地址（旧集）。
  bool _switchFail = false;
  /// 选集面板「当前集」定位锚点：面板打开时把当前集滚进视口。
  final GlobalKey _curEpKey = GlobalKey();
  double _speed = 1.0;
  bool _descExpanded = false;

  /// 移动端单指手势：左半屏上下滑调亮度、右半屏上下滑调音量（仅非全屏/小窗
  /// 下视频区域）。用 raw Listener 采集原始指针事件，不参与手势竞技场，
  /// 与 WebView 内部滚动/点击互不抢占。
  bool _gestureActive = false;
  int? _gesturePointer;
  bool _gestureVolume = false; // true=调音量，false=调亮度
  double _gestureStartValue = 0; // 起手时的目标值（亮度或音量）
  double _gestureAccum = 0; // 累计位移（未超阈值前不动作）
  static const double _gestureSlop = 18.0;
  static const double _gestureRef = 560.0;

  /// 手势 HUD 状态：_hudVolume=true 显示音量条、false 显示亮度条。
  bool _hudVisible = false;
  bool _hudVolume = true;
  double _hudValue = 0;
  Timer? _hudTimer;
  // 亮度：优先真实调系统亮度；无权限/桌面端降级为黑色遮罩（复用阅读器方式）。
  bool _brightnessNative = false;
  double _brightness = 1.0;
  /// WebView 音量（0~1）。移动端手势实时写入 video.volume；桌面端同步音量。
  double _volume = 1.0;

  /// WebView 是否真的初始化完成。桌面端异步 initialize，完成前显示加载态。
  bool _webviewInit = false;

  /// 桌面 WebView2 初始化失败（缺运行时等）：显示系统浏览器降级页。
  bool _desktopInitFailed = false;

  /// WebView2 失败态「重试」是否进行中：防止连点造成多次并发初始化。
  bool _desktopRetry = false;

  /// 统一 JS 执行：自动路由到 webview_flutter 或 WebView2。
  Future<String?> _evalJs(String js) async {
    final d = _desktop;
    if (d != null) return d.evaluate(js);
    try {
      final r = await _controller.runJavaScriptReturningResult(js);
      return r as String?;
    } catch (_) {
      return null;
    }
  }

  /// 统一 JS 执行（忽略返回值）。
  Future<void> _runJs(String js) async {
    final d = _desktop;
    if (d != null) {
      await d.runJavaScript(js);
      return;
    }
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  /// 平板分栏右侧控制面板宽度（与 native_player_page.dart 统一）。
  static const double _panelWidth = kPlayerPanelWidth;

  // 解析中：WebView 加载后先隐藏网页内容，等直链捕获后直接切原生播放器。
  // 5 秒超时后放弃隐藏（降级为 WebView 播放），避免卡在黑屏。
  bool _resolving = true;
  // 直链解析已超时（真机 AGE 源排查用）：为 true 时轮询输出 Hls 诊断。
  bool _resolveFault = false;
  Timer? _resolveTimer;
  // WebView 主页面加载失败（断网/超时/服务器错误）时记录，优先展示错误态而非黑屏。
  String? _webError;
  // 已从视图树物理移除 WebView（切原生播放器/退出页时置位），
  // 置位后 WebView 不再渲染，其音频来源被同步切断，杜绝双音轨残留。
  bool _webViewRemoved = false;

  /// 等待「导航到 about:blank」真正完成的 Future。onPageFinished 时 complete。
  /// about:blank 会连带卸载整个文档树（含跨域 iframe 里的 <video>），
  /// 切原生播放器前必须等它完成，否则转场期间网页音频仍在播放（双音轨）。
  Completer<void>? _pendingBlank;

  static const ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 若 URL 主机是已知优选 IP，返回正确的 Host 头（映射见表
  /// [preferredIpHosts]），否则返回空。WebView 直连 IP 仍需 CDN 证书覆盖该
  /// 域名，否则会证书错误。
  static Map<String, String> _hostHeader(String url) => hostHeaderFor(url);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _curSeason = widget.initialSeason;
    _curEpisode = widget.initialEpisode;
    _initBrightness(); // 读取系统亮度；无权限时降级为遮罩
    // 桌面端播放快捷键：空格 播放/暂停、←/→ 快退/快进、M 静音、
    // F 全屏、Esc 返回。仅桌面注册，避免移动端蓝牙键盘误触。
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
    } else {
      // Android TV：遥控器媒体键（网页通道也有等价 JS 操作）。
      unawaited(TvPlatform.isTv.then((tv) {
        if (tv && mounted) {
          _tvKeysRegistered = true;
          HardwareKeyboard.instance.addHandler(_tvKeyHandler);
        }
      }));
    }
    if (isWindowsWebView2) {
      // Windows：内嵌 WebView2 解析直链 → 切内置原生播放器（mpv 硬解 + Anime4K 超分）。
      // 网页只做“拿直链”的中间层，绝不让用户离开内置播放器。
      _initDesktopWebview();
    } else if (isWebViewSupported) {
      // Android/iOS/macOS：官方 webview_flutter。
      _initMobileWebview();
    } else {
      // Linux：无内嵌实现，走降级页（系统浏览器可播放）。
      return;
    }
  }

  /// Windows 内嵌 WebView2（webview_windows）：初始化、加载播放页、注入
  /// resolve API 拦截 + 直链轮询，捕获后即切 NativePlayerPage（与移动端同链路）。
  Future<void> _initDesktopWebview() async {
    final wv = DesktopWebview();
    _desktop = wv;
    try {
      await wv.initialize(userAgent: ua);
      if (!mounted) return;
      setState(() => _webviewInit = true);
      // 导航失败 / 加载状态变化，复用现有状态字段
      _desktopSubs.add(wv.loadErrors.listen((e) {
        if (!mounted) return;
        // 记录错误态但不取消轮询：页面可能已在自动播放（有声音），
        // 捕获到直链后自动切原生播放器并清除错误态。
        setState(() {
          _webError ??= '页面加载失败\n$e';
          _loading = false;
          _resolving = false;
        });
      }));
      _desktopSubs.add(wv.loadingState.listen((loading) {
        if (!mounted) return;
        setState(() {
          _loading = loading;
          if (loading) {
            _webError = null;
          } else {
            _triggerAutoPlay();
            _restoreProgress();
          }
        });
        // about:blank 导航到位：放行等待它的切原生播放器流程。
        if (!loading) {
          final p = _pendingBlank;
          if (p != null && !p.isCompleted) p.complete();
        }
        if (loading) {
          _injectApiInterceptor();
        }
      }));
      // 页面脚本执行前预注入拦截器：避免错过首屏 resolve API 响应，
      // 并同步拦截 Hls.loadSource（AGE 类 WASM 解密直链）。
      await wv.injectOnDocumentCreated(_apiInterceptorJs);
      await wv.injectOnDocumentCreated(_hlsHookJs);
      await wv.loadUrl(widget.url);
      _hookVideoSource();
      _resolveTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _resolving) {
          setState(() => _resolving = false);
          _resolveFault = true;
        }
      });
    } catch (e) {
      ErrorLogger.instance.warn('WebView2 init failed: $e');
      if (!mounted) return;
      setState(() {
        _webError = '网页播放器初始化失败\n$e\n请检查系统是否安装了 WebView2 运行时';
        _webviewInit = false;
        _desktopInitFailed = true;
      });
    }
  }

  /// 降级页「重试内嵌播放」：WebView2 初始化失败后重跑一遍初始化。
  ///
  /// 此前失败态一旦置位就永久锁死（只能退出重进）。这里覆盖两个出口：
  /// _desktopInitFailed=true（已建过实例，先清理再新建），以及 _desktop==null
  /// 的极端情况（DesktopWebview() 构造即抛异常）。_desktopRetry 防连点。
  /// 运行时仍未装时重试同样失败、回到本降级页（按钮重新可用，不再锁死）；
  /// 已装运行时（首次因环境初始化抖动失败）则可当场恢复内嵌播放。
  Future<void> _retryDesktopInit() async {
    if (_desktopRetry || !mounted) return;
    // Linux 等平台本就没有内嵌 WebView 实现，重试无意义，保持降级页。
    if (_desktop == null && !isWindowsWebView2) return;
    _desktopRetry = true;
    // 清理上一轮失败的实例与事件订阅：避免旧 controller 残留句柄，
    // 也保证新一轮 loadErrors/loadingState 不被旧流串扰。_desktop 同时置空，
    // 让 build 的「_desktop != null 才渲染 WebView」守卫挡住重试期间的视图树。
    // _desktopInitFailed 保持 true 直到重试成功：降级页文案与重试按钮
    // 据此显示，重试期间按钮置灰而不是消失。
    for (final s in _desktopSubs) {
      s.cancel();
    }
    _desktopSubs.clear();
    final old = _desktop;
    _desktop = null;
    _resolveTimer?.cancel();
    setState(() {
      _webError = null;
      _loading = true;
      _resolving = true;
    });
    try {
      await _initDesktopWebview();
      // 重试成功：_initDesktopWebview 内部已置 _webviewInit=true，
      // 这里复位失败标记（build 在 _webviewInit 为真时走 WebView 分支）。
      if (!mounted) return;
      setState(() => _desktopInitFailed = false);
    } catch (e) {
      // 覆盖 DesktopWebview() 构造即抛异常的极端情况（该异常在
      // _initDesktopWebview 的 try 之外，不会被它接住）。
      ErrorLogger.instance.warn('WebView2 init failed: $e');
      if (!mounted) return;
      setState(() {
        _desktopInitFailed = true;
        _webError =
            '网页播放器初始化失败\n$e\n请检查系统是否安装了 WebView2 运行时';
        _webviewInit = false;
        _loading = false;
        _resolving = false;
      });
    } finally {
      _desktopRetry = false;
      // 旧实例在 initialize 失败时 _ready 仍为 false，dispose 内部自行短路。
      try {
        await old?.dispose();
      } catch (_) {}
    }
  }

  /// Android/iOS/macOS：官方 webview_flutter 初始化。
  void _initMobileWebview() {
    _webviewInit = true;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(ua)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (!mounted) return;
          setState(() {
            _loading = true;
            _webError = null;
          });
          _injectApiInterceptor();
          // AGE 类源的直链是页面内 WASM 解密后交给 Hls.loadSource 的
          // http m3u8（<video> 实际拿到的是 blob:）。必须在 WebView 里
          // hook 住 Hls.loadSource 才能在真机上捕获真实直链切 mpv。
          // 脚本自带 30s 重试，onPageStarted 注入一次即可覆盖后续 Hls 初始化。
          _injectHlsHook();
        },
        onPageFinished: (_) {
          if (!mounted) return;
          setState(() => _loading = false);
          _triggerAutoPlay();
          _restoreProgress();
          // 页面就绪后 Hls 可能已初始化完成，再补注入一次确保 hook 生效。
          _injectHlsHook();
          // about:blank 导航到位：放行等待它的切原生播放器流程。
          final p = _pendingBlank;
          if (p != null && !p.isCompleted) p.complete();
        },
        onWebResourceError: (err) {
          // 主框架加载失败（断网/超时/服务器错误）时记录错误态。
          // 注意：不能取消 _videoPollTimer/_resolveTimer——页面可能已在
          // 自动播放（有声音），只是个别资源报错；轮询仍要跑，捕获到
          // 直链后自动切原生播放器并清除错误态。
          if (!mounted) return;
          if (err.isForMainFrame == true && _webError == null) {
            final desc = err.description.trim();
            setState(() {
              _webError =
                  '页面加载失败${desc.isNotEmpty ? '\n$desc' : ''}';
              // 主框架失败时结束静音解析态，让网页继续出声（有声音说明
              // 页面实际可用），而非卡在黑屏 loading。
              _resolving = false;
            });
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url), headers: _hostHeader(widget.url));
    _enableWebViewMediaPlayback();
    _hookVideoSource();
    // 8 秒后放弃隐藏 WebView（降级为网页播放），避免一直黑屏。
    // 弱网环境下 5 秒可能不够解析直链。
    _resolveTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _resolving) {
        setState(() => _resolving = false);
        // 真机 AGE 源直链捕获长期失败时开启 Hls 诊断（排查用）
        _resolveFault = true;
      }
    });
  }

  /// WebView 内 video 直链被捕获时，切到 mpv 原生播放器
  /// （Anime4K 超分 + 硬解），仅在拿到真实 m3u8/mp4 直链时生效。
  Future<void> _onVideoSrcCaptured(String src) async {
    if (src.isEmpty || !isDirectMediaUrl(src)) return;
    // JS 侧过滤的兜底：广告直链（path 含 ad/ads/adv 等段或已知广告域名）
    // 即便溜过筛选也在此拦截，防止广告 m3u8 先于正片被接管原生播放器。
    if (isAdMediaUrl(src)) {
      ErrorLogger.instance.debug('ad url filtered: ${_trimUrl(src)}');
      return;
    }
    // blob URL 是页面内 WASM 解密出的 MSE 流，原生播放器取不到字节，
    // 无法直接播放；保留 WebView 走网页播放器（AGE 等源）。
    if (src.startsWith('blob:')) return;
    // Anime1 的 CDN 直链（.v.anime1.me）需携带签名 Cookie(h/p/e) 才能访问，
    // 原生播放器无法携带 Cookie，保留 WebView 由站点播放器播放（同域自动带）。
    if (widget.sourceId == 'anime1' && src.contains('anime1.me')) return;
    if (!mounted) return;
    // 首见 URL 才走接管流程；重复 URL 直接忽略（轮询每 900ms 一次）。
    if (src == _hookedVideoUrl) return;
    _hookedVideoUrl = src;
    if (_handedOffToMpv) {
      // 已接管过原生播放器：后续捕获到不同直链（广告换源/清晰度切换）
      // 不再重复 handoff，避免再次从 0:00 重播。只提醒一次，具体换源
      // 由用户手动操作（切集/进度条），防止轮询高频打断播放。
      ErrorLogger.instance.debug(
          'handoff already taken; ignored new src (ad/switch): ${src.length > 80 ? src.substring(0, 80) : src}');
      return;
    }
    // 页面确实在播（拿到直链）→ 之前的加载失败提示是误报，清除错误态。
    if (_webError != null || _switchFail) {
      setState(() {
        _webError = null;
        _switchFail = false;
      });
    }
    // 同一 Route 内嵌模式（NativePlayerPage 持有 WebView 状态机）：
    // 由宿主切回 mpv 通道，本页不 pushReplacement，杜绝双页互跳。
    final cb = widget.onDirectUrl;
    if (cb != null) {
      _resolveTimer?.cancel();
      // 先由宿主用 mpv 试开直链：成功才杀网页媒体（杜绝双音轨窗口），
      // 失败则 WebView 完好，原样留在网页通道继续播放，不弹失败页。
      final taken = await cb(src);
      if (!mounted) return;
      if (taken) {
        _handedOffToMpv = true;
        await _killWebMedia();
      } else {
        // handoff 被拒（直链失效/打不开）：留在网页通道。此时 _resolving
        // 仍为 true 而上面的 cancel 已把 8 秒计时器取消 —— 不重武装的话
        // "解析直链中…"黑幕会永久挂着、轮询持续强杀网页音量。重新武装
        // 一次超时放弃计时器，让 _resolving 能正常回落。
        _resolveTimer = Timer(const Duration(seconds: 8), () {
          if (mounted && _resolving) {
            setState(() => _resolving = false);
            _resolveFault = true;
          }
        });
      }
      return;
    }
    // 取消解析定时器，防止 pushReplacement 后定时器触发 setState
    _resolveTimer?.cancel();
    _videoPollTimer?.cancel();
    // 先杀掉网页播放器（暂停+清空 src+about:blank）并同步物理移除 WebView，
    // 再切原生播放器。WebView 从视图树移除后不可能再渲染或出声，
    // 转场期间与 WebView2 异步释放期间都不会残留网页音频（双音轨）。
    await _killWebMedia();
    // about:blank 导航会连带卸载整个文档树（含跨域 iframe 里的 <video>），
    // 必须等导航真正完成再推原生播放器，否则转场期间网页音频仍在播放（双音轨）。
    if (!(_pendingBlank?.isCompleted ?? true)) {
      try {
        await _pendingBlank!.future.timeout(const Duration(milliseconds: 900));
      } catch (_) {}
    }
    if (!mounted) return;
    // 用 pushReplacement 替换当前网页播放器，避免栈里叠两层播放器：
    // 选集页 → 网页播放器 → 原生播放器。返回时直接回到选集页。
    // 用纯淡入转场：当前页是黑屏 loading，切到同为黑底的原生播放器
    // 时几乎无感，不出现"先跳一个页面再跳一个页面"的闪烁。
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => NativePlayerPage(
          url: src,
          title: widget.title,
          cover: widget.cover,
          episodes: widget.episodes,
          season: _curSeason,
          episode: _curEpisode,
          resolveUrl: widget.resolveUrl,
          sourceNames: widget.sourceNames,
          sourceId: widget.sourceId,
          videoId: widget.videoId,
          historyKey: widget.sourceId != null && widget.videoId != null
              ? '${widget.sourceId}/${widget.videoId}/$_curSeason-$_curEpisode'
              : '${widget.title}/$_curSeason-$_curEpisode',
          webChannelBuilder: animePlayerWebChannel,
        ),
        transitionDuration: context.uiStyle == UIStyle.minimalist
            ? const Duration(milliseconds: 260)
            : StyleTokens.transitionDuration(context),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  /// 监听 WebView 内 HTML5 video 的真实直链（m3u8/mp4/flv）。
  ///
  /// AGE 类站点把真实直链用 WASM 在网页内解密后交给 <video> 播放，
  /// 这里轮询捕获解密后的 src，交由 mpv（NativePlayer + Anime4K 超分）
  /// 接管播放，以获得原生硬解 + CNN 超分画质。
  String _hookedVideoUrl = '';
  Timer? _videoPollTimer;
  /// 已成功接管到原生播放器后置位：后续再捕获到不同直链（含广告切换
  /// 导致 src 变化）时不再重复 handoff/重建，只尝试让 mpv 更新播放源，
  /// 防止「广告 src → 正片 src」两次接管各从 0:00 重播。
  bool _handedOffToMpv = false;

  /// AGE 类（WASM 解密）Hls.loadSource 拦截：解密后的真实 m3u8
  /// 写入 window._resolvedVideoUrl，由轮询捕获后交原生播放器。
  ///
  /// AGE 的播放器在站内 iframe（/vip/ 页）里运行 Hls.js，移动端
  /// runJavaScript 只能注入主 frame，够不到 iframe 的 window.Hls。
  /// 故递归遍历文档里所有 iframe（同源可访问 contentWindow），
  /// 把每一个 window.Hls 都 hook 住，url 统一写到主 window 上，
  /// 轮询脚本（_videoPollJs）在主 frame 读取到后切原生播放器。
  static const String _hlsHookJs = '''
    (function(){
      if (!window._rxHlsHookInstalled) {
        window._rxHlsHookInstalled = true;
        window._resolvedVideoUrl = '';
        // 广告直链判定：path 独立段 ad/ads/adv 等，或广告域名特征。
        // 广告 m3u8 混入正片流时若无条件捕获，会先接管原生播放器、
        // 从 0:00 播广告；此处过滤让正片成为首个被捕获的直链。
        var isAdUrl = function(u){
          try {
            var low = ('' + u).toLowerCase();
            var segs = low.split('?')[0].split('/');
            for (var i = 0; i < segs.length; i++) {
              var s = segs[i];
              if (s === 'ad' || s === 'ads' || s === 'adv' ||
                  s === 'advert' || s === 'adverts' || s === 'advertise' ||
                  s === 'advertising' || s === 'advertisement' ||
                  s === 'adserve' || s === 'adserver' || s === 'adservice' ||
                  s === 'adtrack' || s === 'adtag') return true;
            }
            return low.indexOf('doubleclick') >= 0 ||
                   low.indexOf('googlesyndication') >= 0 ||
                   low.indexOf('amazon-adsystem') >= 0 ||
                   low.indexOf('adnxs') >= 0 ||
                   low.indexOf('applovin') >= 0 ||
                   low.indexOf('unityads') >= 0 ||
                   low.indexOf('adcolony') >= 0 ||
                   low.indexOf('pstatp.com') >= 0 ||
                   low.indexOf('topbuzzcdn.com') >= 0 ||
                   low.indexOf('capcut.com') >= 0;
          } catch(e){ return false; }
        };
        var hookWin = function(w){
          try {
            if (!w || !w.Hls || w.__rxHlsHooked) return;
            var proto = w.Hls.prototype;
            if (!proto || !proto.loadSource) return;
            w.__rxHlsHooked = true;
            var orig = proto.loadSource;
            proto.loadSource = function(url){
              try {
                // 无条件记录最后传给 loadSource 的 url，诊断用
                window.__lastHlsUrl = '' + (url || '');
                // 接受 http(s) 与协议相对（//host/xx.m3u8）两种直链形；
                // 广告 URL 过滤：混入正片流的广告 m3u8 不被捕获。
                var u = '' + (url || '');
                if ((u.indexOf('http:') === 0 ||
                     u.indexOf('https:') === 0 ||
                     u.indexOf('//') === 0) &&
                    u.indexOf('blob:') !== 0 &&
                    !isAdUrl(u)) {
                  // 统一写到主 frame，脚本都跑在主 frame 的 JS 上下文
                  window._resolvedVideoUrl = u;
                }
              } catch(e){}
              return orig.apply(this, arguments);
            };
          } catch(e){}
        };
        var hookDoc = function(doc){
          try {
            if (doc && doc.querySelectorAll) {
              var frs = doc.querySelectorAll('iframe');
              for (var i = 0; i < frs.length; i++) {
                var f = frs[i];
                try {
                  hookWin(f.contentWindow);
                  if (f.contentDocument) hookDoc(f.contentDocument);
                } catch(e){}
              }
            }
          } catch(e){}
        };
        var tryHook = function(){
          hookWin(window);
          hookDoc(document);
        };
        tryHook();
        var t = setInterval(function(){
          tryHook();
          if (window.__rxHlsHooked) clearInterval(t);
        }, 800);
        setTimeout(function(){ clearInterval(t); }, 60000);
      }
    })();
  ''';

  /// 轮询捕获脚本：优先取拦截到的直链，其次扫描 DOM 里的 <video>。
  /// 同时过滤广告直链：path 含 ad/ads/adv 段或已知广告域名，不捕获。
  static const String _videoPollJs = '''
    (function(){
      var isAdUrl = function(u){
        try {
          var low = ('' + u).toLowerCase();
          var segs = low.split('?')[0].split('/');
          for (var i = 0; i < segs.length; i++) {
            var s = segs[i];
            if (s === 'ad' || s === 'ads' || s === 'adv' ||
                s === 'advert' || s === 'adverts' || s === 'advertise' ||
                s === 'advertising' || s === 'advertisement' ||
                s === 'adserve' || s === 'adserver' || s === 'adservice' ||
                s === 'adtrack' || s === 'adtag') return true;
          }
          return low.indexOf('doubleclick') >= 0 ||
                 low.indexOf('googlesyndication') >= 0 ||
                 low.indexOf('amazon-adsystem') >= 0 ||
                 low.indexOf('adnxs') >= 0 ||
                 low.indexOf('applovin') >= 0 ||
                 low.indexOf('unityads') >= 0 ||
                 low.indexOf('adcolony') >= 0 ||
                 low.indexOf('pstatp.com') >= 0 ||
                 low.indexOf('topbuzzcdn.com') >= 0 ||
                 low.indexOf('capcut.com') >= 0;
        } catch(e){ return false; }
      };
      var _hooked = window._resolvedVideoUrl || '';
      if (_hooked.indexOf('blob:') !== 0 && _hooked.indexOf('http') === 0 &&
          !isAdUrl(_hooked)) {
        return _hooked;
      }
      var find = function(doc){
        var v = doc.querySelector('video');
        if(v){
          var s = v.currentSrc || v.src || '';
          if(s.indexOf('blob:') === 0) return '';
          if(s && !isAdUrl(s)) return s;
          var src = v.querySelector('source');
          if(src && src.src && !isAdUrl(src.src)) return src.src;
        }
        var fr = doc.querySelector('iframe');
        if(fr){
          try{
            var s2 = find(fr.contentDocument || fr.contentWindow.document);
            if(s2) return s2;
          }catch(e){}
        }
        return '';
      };
      return find(document);
    })()
  ''';

  /// 诊断脚本：报告主 frame / iframe 的 Hls 与直链捕获状态。
  /// 仅 AGE 类源直链捕获长期失败时用于真机排查，稳定后移除。
  static const String _hlsDiagJs = '''
    (function(){
      var info = {
        pageHref: (location.href || '').toString().slice(0, 90),
        selfHls: typeof window.Hls !== 'undefined' ? 'yes' : 'no',
        rxInstalled: window._rxHlsHookInstalled ? 'yes' : 'no',
        rxHooked: (window.__rxHlsHooked ? 'yes' : 'no'),
        resolved: (window._resolvedVideoUrl || '').toString().slice(0, 80),
        lastHlsUrl: (window.__lastHlsUrl || '').toString().slice(0, 80),
        videos: [],
        iframes: [],
        videoSrc: ''
      };
      try {
        var vs = document.querySelectorAll('video');
        for (var i = 0; i < vs.length; i++) {
          info.videos.push((vs[i].currentSrc || vs[i].src || 'none').toString().slice(0, 60));
        }
        var frs = document.querySelectorAll('iframe');
        for (var i = 0; i < frs.length && i < 3; i++) {
          var f = frs[i];
          try {
            var w = f.contentWindow;
            var doc = f.contentDocument || w.document;
            info.iframes.push((doc.location ? doc.location.href : '?').toString().slice(0, 60) +
              '|Hls:' + (w.Hls ? 'yes' : 'no'));
            var v = doc.querySelector('video');
            if (v) info.videoSrc = (v.currentSrc || v.src || '').toString().slice(0, 60);
          } catch(e) {
            info.iframes.push('CROSS:' + e.message);
          }
        }
      } catch(e) {
        info.iframes.push('ERR:' + e.message);
      }
      return JSON.stringify(info);
    })()
  ''';
  
  void _hookVideoSource() {
    _videoPollTimer?.cancel();
    _videoPollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) async {
      if (!mounted) return;
      // 0) 解析直链期间持续压制网页播放器音量，防止站点抢先出声
      if (_resolving) {
        await _muteWebMedia();
      }
      // 1) 播完检测：video.ended → 自动切下一集
      if (!_autoNextFired && _hasNext) {
        String ended = '';
        try {
          ended = (await _evalJs(_autoNextJs)) ?? '';
        } catch (_) {}
        if (ended == 'ENDED') {
          _autoNextFired = true; // 去重：切集前置位，防止轮询重复触发
          _goToAdjacent(1);
          return;
        }
      }
      // 1.5) 下一集预热：剩余 ≤5 分钟时后台解析直链，连播/手动切集零等待。
      // 预热失败 30 秒后重试一次；解析成功后切集直接复用，不再等源站。
      if (_hasNext && !_autoNextFired &&
          widget.resolveUrl != null &&
          !_prefetchingNext &&
          DateTime.now().isAfter(_prefetchRetryAt)) {
        final next = widget.episodes[_nextIndex];
        final key = '${next.season}-${next.episode}';
        if (key != _prefetchKey) {
          String remain = '';
          if (!_resolving && !_webViewRemoved) {
            try {
              remain = (await _evalJs(_videoRemainJs)) ?? '';
            } catch (_) {}
          }
          final remainSec = int.tryParse(remain) ?? -1;
          // 取不到时长（爬虫/直播/页面未就绪）不反复试，防止高频请求源站
          if (remainSec > 0 && remainSec <= 5 * 60) {
            _prefetchNext(key);
          }
        }
      }
      // 2) 直链捕获：解析到视频 src → 交原生播放器
      String? src;
      try {
        final r = await _evalJs(_videoPollJs);
        if (r != null && r.isNotEmpty) {
          final decoded = r.startsWith('"') && r.endsWith('"')
              ? (r.substring(1, r.length - 1))
              : r;
          if (decoded.isNotEmpty) src = decoded;
        }
        // 诊断：AGE 类源直链捕获状态（真机排查用，稳定后移除）
        if (widget.sourceId == 'agedm' && mounted && _resolveFault) {
          final diag = await _evalJs(_hlsDiagJs);
          debugPrint('MPVSRC[${src ?? 'null'}] HlsDiag[$diag]');
        }
      } catch (_) {}
      if (src != null) await _onVideoSrcCaptured(src);
    });
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

  /// 轮询 WebView 内 <video> 的播放状态（paused/currentTime/duration），
  /// 驱动全屏控制层的进度条/时间/播放按钮。仅桌面端跑（全屏主要在桌面）。
  Timer? _fsPollTimer;
  void _startFsPoll() {
    // 只在全屏时创建：非全屏起轮询会每秒空转一次 WebView eval。
    if (!_fullscreen) return;
    _fsPollTimer?.cancel();
    _fsPollTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) async {
      if (!mounted || !_fullscreen) return;
      final r = await _evalJs(_fsPollJs);
      if (!mounted) return;
      final parts = (r ?? '').split('|');
      if (parts.length < 3) return;
      final paused = parts[0] == '1';
      final pos = double.tryParse(parts[1]) ?? 0;
      final dur = double.tryParse(parts[2]) ?? 0;
      setState(() {
        if (!_fsSeeking) _fsPos = pos;
        _fsDur = dur;
        _fsPlaying = !paused;
      });
    });
  }
  static const String _fsPollJs = '''
    (function(){
      var v = document.querySelector('video');
      if(!v) return '0|0|0';
      return (v.paused ? '1' : '0') + '|' + (v.currentTime || 0) + '|' + (v.duration || 0);
    })()
  ''';

  /// 全屏播放/暂停按钮：paused 时 play，播放中 pause。
  void _fsTogglePlay() {
    _runJs('''
      (function(){
        var v = document.querySelector('video');
        if(!v) return;
        if(v.paused){ v.play().catch(function(){}); } else { v.pause(); }
      })();
    ''');
    setState(() => _fsPlaying = !_fsPlaying);
  }

  /// 全屏进度条拖动 seek：结束拖拽时写入 currentTime。
  void _fsSeekTo(double pos) {
    if (pos < 0) pos = 0;
    _runJs('''
      (function(){
        var v = document.querySelector('video');
        if(!v || !v.duration || v.duration === Infinity) return;
        v.currentTime = ${pos.toStringAsFixed(3)};
      })();
    ''');
  }

  /// 全屏控制层显示状态更新：延后 [ _fsHideDelayMs] 自动隐藏。

  @override
  void dispose() {
    if (DesktopUi.isDesktopPlatform) {
      HardwareKeyboard.instance.removeHandler(_keyHandler);
    }
    if (_tvKeysRegistered) {
      HardwareKeyboard.instance.removeHandler(_tvKeyHandler);
    }
    _videoPollTimer?.cancel();
    _resolveTimer?.cancel();
    _fsPollTimer?.cancel();
    _fsHideTimer?.cancel();
    // 兜底：页面销毁时放行未完成的 about:blank 等待，避免 Completer 悬挂。
    if (_pendingBlank != null && !_pendingBlank!.isCompleted) {
      _pendingBlank!.complete();
    }
    // 兜底：离开播放页时若网页播放器仍在播放（如未捕获直链直接退出），
    // 立即硬销毁网页媒体并停掉 WebView2，避免页面销毁后音频残留。
    // 不能复用 _killWebMedia：它在内部 setState，dispose 期间调用会崩。
    if (!_webViewRemoved) {
      _runJs(_destroyWebMediaJs); // fire-and-forget：销毁脚本本身同步执行
      try {
        _desktop?.stop();
      } catch (_) {}
      // 跨域 iframe 内的媒体销毁脚本够不着（SecurityError），只剩
      // 导航 about:blank 能连根卸载整个文档树（含跨域 iframe 的 <video>）。
      // fire-and-forget，不等待 onPageFinished，不 setState。
      try {
        _controller.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
    }
    _webViewRemoved = true;
    for (final s in _desktopSubs) {
      s.cancel();
    }
    _desktopSubs.clear();
    _desktop?.dispose();
    _desktop = null;
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _unlockOrientation();
    // 离开播放页时还原桌面窗口（防全屏状态残留）
    DesktopFullscreen.set(false);
    super.dispose();
  }

  /// 退到后台前网页通道是否在播：回前台据此恢复轮询与网页播放。
  bool _webPlayingBeforePause = false;

  /// 生命周期代次：每次 paused/resumed 自增。paused 处理里有两次 await
  /// （探测在播 → 静音），若其间收到 resumed，旧的处理必须整体作废——
  /// 否则它会在回前台之后继续静音、并停掉刚恢复的轮询（表现为「切回来
  /// 没声音、进度不再跟进」）。跨 await 校验代次即可。
  int _lifecycleGen = 0;

  /// App 切后台/回前台。后台时网页若在播：压掉声音（否则后台一直外放）并
  /// 停掉直链/全屏两个轮询 Timer（后台 eval WebView 纯属空转）；
  /// 回前台时恢复轮询与播放。initState 已 addObserver、dispose 已 removeObserver。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      final gen = ++_lifecycleGen;
      unawaited(_handleAppPaused(gen));
    } else if (state == AppLifecycleState.resumed) {
      _lifecycleGen++;
      _handleAppResumed();
    }
  }

  Future<void> _handleAppPaused(int gen) async {
    if (_webViewRemoved) return;
    // inactive→paused 可能连发：已判定过在播就不再重检，否则第二次检测时
    // 媒体已被静音暂停，会把「之前在播」误判成否、回前台不再恢复。
    if (_webPlayingBeforePause) return;
    final playing = await _isWebMediaPlaying();
    if (!mounted || gen != _lifecycleGen) return;
    if (!playing) return;
    _webPlayingBeforePause = true;
    // 复用解析期的静音/暂停脚本：只 muted+pause、不摘元素，回前台可续播。
    await _muteWebMedia();
    if (!mounted) return;
    if (gen != _lifecycleGen) {
      // 静音期间回了前台：resume 可能已恢复过，但我们的静音脚本后到，
      // 必须再恢复一次（保证最后落地的动作是「回前台」），且绝不停轮询。
      _restoreWebMedia();
      return;
    }
    _videoPollTimer?.cancel();
    _fsPollTimer?.cancel();
  }

  void _handleAppResumed() {
    if (!_webPlayingBeforePause) return;
    _webPlayingBeforePause = false;
    _restoreWebMedia();
  }

  /// 恢复网页播放：解除退后台时的静音/暂停（尊重用户静音开关），重挂直链
  /// 探测，并在全屏时恢复全屏轮询。resume 与「静音期间回前台」的兜底共用，
  /// 保证两条路径行为一致（且可重复调用，幂等）。
  void _restoreWebMedia() {
    if (!mounted) return;
    final muted = _muted ? 'true' : 'false';
    unawaited(_runJs('''
      (function(){
        var resume = function(doc){
          if(!doc || !doc.querySelectorAll) return;
          var nodes = doc.querySelectorAll('video,audio');
          for(var i=0;i<nodes.length;i++){
            try{ nodes[i].muted = $muted; }catch(e){}
            try{ var p = nodes[i].play(); if(p && p.catch){ p.catch(function(){}); } }catch(e){}
          }
        };
        resume(document);
        var fs = document.querySelectorAll ? document.querySelectorAll('iframe') : [];
        for(var j=0;j<fs.length;j++){
          try{ var fd = fs[j].contentDocument; if(fd){ resume(fd); } }catch(e){}
        }
      })();
    '''));
    _hookVideoSource();
    if (_fullscreen) _startFsPoll();
  }

  /// 顶层 + 同域 iframe 是否有媒体正在播放（跨域读不到时按未播处理）。
  static const String _anyMediaPlayingJs = '''
    (function(){
      var check = function(doc){
        if(!doc || !doc.querySelectorAll) return false;
        var nodes = doc.querySelectorAll('video,audio');
        for(var i=0;i<nodes.length;i++){
          try{ if(!nodes[i].paused) return true; }catch(e){}
        }
        var fs = doc.querySelectorAll('iframe');
        for(var j=0;j<fs.length;j++){
          try{ var fd = fs[j].contentDocument; if(fd && check(fd)) return true; }catch(e){}
        }
        return false;
      };
      return check(document) ? '1' : '0';
    })();
  ''';

  Future<bool> _isWebMediaPlaying() async {
    try {
      return await _evalJs(_anyMediaPlayingJs) == '1';
    } catch (_) {
      return false;
    }
  }

  /// 拦截 resolve-play-url 的 API 响应（fetch + XHR 双拦截），
  /// 以及 Hls.js 加载的 m3u8 直链。广告 URL（path 含 ad/ads/adv 等段
  /// 或已知广告域名）被过滤，防止广告 m3u8 先于正片被捕获接管原生播放器。
  static const String _apiInterceptorJs = '''
    (function() {
      if (window._videoUrlIntercepted) return;
      window._videoUrlIntercepted = true;
      window._resolvedVideoUrl = '';

      // 广告直链判定（与 _videoPollJs/_hlsHookJs 一致）
      var isAdUrl = function(u) {
        try {
          var low = ('' + u).toLowerCase();
          var segs = low.split('?')[0].split('/');
          for (var i = 0; i < segs.length; i++) {
            var s = segs[i];
            if (s === 'ad' || s === 'ads' || s === 'adv' ||
                s === 'advert' || s === 'adverts' || s === 'advertise' ||
                s === 'advertising' || s === 'advertisement' ||
                s === 'adserve' || s === 'adserver' || s === 'adservice' ||
                s === 'adtrack' || s === 'adtag') return true;
          }
          return low.indexOf('doubleclick') >= 0 ||
                 low.indexOf('googlesyndication') >= 0 ||
                 low.indexOf('amazon-adsystem') >= 0 ||
                 low.indexOf('adnxs') >= 0 ||
                 low.indexOf('applovin') >= 0 ||
                 low.indexOf('unityads') >= 0 ||
                 low.indexOf('adcolony') >= 0 ||
                 low.indexOf('pstatp.com') >= 0 ||
                 low.indexOf('topbuzzcdn.com') >= 0 ||
                 low.indexOf('capcut.com') >= 0;
        } catch(e){ return false; }
      };

      // 判断是否为可交给原生播放器的直链（m3u8 / mp4 / flv / 部分 json 接口）
      var isPlayable = function(u) {
        if (typeof u !== 'string' || !u) return false;
        if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return false;
        if (u.indexOf('http:') !== 0 && u.indexOf('https:') !== 0 &&
            u.indexOf('//') !== 0) return false;
        var low = u.toLowerCase();
        return low.indexOf('.m3u8') >= 0 ||
               low.indexOf('.mp4') >= 0 ||
               low.indexOf('.flv') >= 0;
      };
      // 统一写入（广告 URL 不写入，防止误接管）
      var mark = function(u) {
        if (isPlayable(u) && !isAdUrl(u)) window._resolvedVideoUrl = u;
      };

      // 拦截 fetch 请求中匹配 resolve-play-url 的 API，以及所有 m3u8 响应
      var origFetch = window.fetch;
      window.fetch = function(url, opts) {
        return origFetch.apply(this, arguments).then(function(response) {
          var urlStr = (typeof url === 'string') ? url : (url ? url.url || '' : '');
          if (urlStr.indexOf('/api/videos/resolve-play-url') >= 0) {
            response.clone().json().then(function(data) {
              if (data && data.data && data.data.url) {
                var ru = '' + data.data.url;
                if (!isAdUrl(ru)) window._resolvedVideoUrl = ru;
              }
            }).catch(function(){});
          } else if (isPlayable(urlStr)) {
            // Hls.js 加载 m3u8 片段/主清单时同步捕获直链
            mark(urlStr);
          }
          return response;
        });
      };

      // 拦截 XMLHttpRequest 中匹配 resolve-play-url 的 API / m3u8
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        this._requestUrl = url;
        return origOpen.apply(this, arguments);
      };
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function() {
        if (this._requestUrl && typeof this._requestUrl === 'string') {
          var u = this._requestUrl;
          if (u.indexOf('/api/videos/resolve-play-url') >= 0) {
            this.addEventListener('load', function() {
              try {
                var data = JSON.parse(this.responseText);
                if (data && data.data && data.data.url) {
                  var ru = '' + data.data.url;
                  if (!isAdUrl(ru)) window._resolvedVideoUrl = ru;
                }
              } catch(e) {}
            });
          } else if (isPlayable(u)) {
            mark(u);
          }
        }
        return origSend.apply(this, arguments);
      };
    })();
  ''';

  /// 在 WebView 页面加载前注入 JavaScript，拦截 resolve-play-url API 请求。
  ///
  /// 部分视频源（如 TvTFun）的播放页通过调用 `/api/videos/resolve-play-url?episodeId=xxx`
  /// 获取视频直链，然后交给 ArtPlayer 播放。该 API 返回的 URL 是 m3u8/mp4 直链，
  /// 捕获后可直接交给 NativePlayer（media_kit）原生播放，无需 WebView 中转。
  Future<void> _injectApiInterceptor() => _runJs(_apiInterceptorJs);

  /// 在 WebView 里 hook Hls.loadSource，捕获 WASM 解密后的 http m3u8 直链。
  ///
  /// AGE 类源的播放页用 WASM 在页面内解密出真实 m3u8，再交给 Hls.js
  /// 播放（<video> 实际拿到的是 blob: MSE 流）。原生播放器取不到 blob
  /// 字节，但 m3u8 直链本身是 http URL——hook 住 Hls.loadSource 即可
  /// 在真机上捕获直链切 mpv（Anime4K 超分）。桌面端已通过
  /// injectOnDocumentCreated 预注入，此方法供移动端 onPageStarted /
  /// onPageFinished 补注入。
  Future<void> _injectHlsHook() => _runJs(_hlsHookJs);

  void _enableWebViewMediaPlayback() {
    try {
      final and = _controller.platform as AndroidWebViewController;
      // 自动播放声音/视频，不需要用户手势
      and.setMediaPlaybackRequiresUserGesture(false);
    } catch (_) {}
    // 拦截网页内部 video 全屏请求，转发给 app 级横屏全屏，
    // 避免出现"网页内竖屏全屏"与 app 全屏互相冲突。
    _runJs('''
      (function(){
        var hijack = function(){
          var v = document.querySelector('video');
          if(v){
            v.webkitEnterFullscreen = null;
            if(v.requestFullscreen){ v.requestFullscreen = null; }
          }
          if(document.documentElement.requestFullscreen){
            document.documentElement.requestFullscreen = function(){
              try{ window.flutter_inappwebview.callHandler('enterFullscreen'); }catch(e){}
              return Promise.resolve();
            };
          }
        };
        hijack();
        var t = setInterval(function(){
          var v = document.querySelector('video');
          if(v && (v.webkitEnterFullscreen || v.requestFullscreen)){
            hijack();
            clearInterval(t);
          }
        }, 800);
        setTimeout(function(){ clearInterval(t); }, 20000);
      })();
    ''');
  }

  /// 真实屏幕是否为横屏（宽 > 高）。
  bool get _isLandscape {
    final size = MediaQuery.of(context).size;
    return size.width > size.height;
  }

  /// 跟随系统方向变化：全屏状态由按钮驱动，这里不再反向改写 _fullscreen，
  /// 仅在全屏中但被物理转到竖屏时强制回到横屏，避免「竖屏全屏 / 退出后被拉回」。
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    if (_fullscreen && !_isLandscape) {
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
  }

  bool _played = false;
  int _srLevel = 0; // 0=关, 1=性能, 2=质量

  /// 硬销毁网页媒体的统一 JS：pause + muted + 清 srcObject + 清空 src +
  /// 从 DOM 摘除 <video>/<audio>；同域 iframe 递归处理，跨域 iframe 取不到
  /// document 时把 iframe 本身从父文档摘掉，其媒体随之失效。
  ///
  /// 旧实现只 `querySelector('video')` 单个元素且 `kill(iframe.contentDocument)`
  /// 抛 SecurityError 被吞，跨域 iframe 里的播放器全程既不 pause 也不 mute，
  /// 是「网页播放器 + 原生播放器双音轨」的根因。这里用 `querySelectorAll`
  /// 处理多元素，并用 `srcObject = null` 掐断 MSE/blob 流（只 pause 不够）。
  ///
  /// 跨域 iframe 无法读 contentDocument，音频轨道线程在 iframe 内仍存活：
  /// 摘掉 iframe 节点只能断渲染，不能保证停声。因此：
  /// 1) 对所有 iframe 先整体 `pause = true` 强行走到 document 的
  ///    visibilitychange 隐藏分支,由各媒体元素自身的 volumechange/pause 事件
  ///    触发（而非依赖读跨域 DOM）;
  /// 2) 接管 document 的 appendChild/insertBefore，拦截后续由站点脚本
  ///    重建的 <video>/<audio>（深色模式/播放器库重挂载时常见）;
  /// 3) 用 MutationObserver 兜底观察同域文档，交叉覆盖动态插入的媒体。
  static const String _destroyWebMediaJs = '''
    (function(){
      var kill = function(doc){
        if(!doc || !doc.querySelectorAll) return;
        var nodes = doc.querySelectorAll('video,audio');
        for(var i=0;i<nodes.length;i++){
          var m = nodes[i];
          try{ m.muted = true; }catch(e){}
          try{ m.pause(); }catch(e){}
          try{ if(m.srcObject !== undefined){ m.srcObject = null; } }catch(e){}
          try{ if(m.removeAttribute) m.removeAttribute('src'); }catch(e){}
          try{ if(m.load) m.load(); }catch(e){}
          try{ if(m.parentNode){ m.parentNode.removeChild(m); } }catch(e){}
        }
      };
      var ts = (typeof document.hidden !== 'undefined') && document.hidden;
      // 修改 visibilityState：document.hidden 只读，直接替换整个属性描述符
      try{
        Object.defineProperty(document, 'hidden', {get: function(){ return true; }, configurable: true});
        Object.defineProperty(document, 'visibilityState', {get: function(){ return 'hidden'; }, configurable: true});
      }catch(e){}
      try{ document.dispatchEvent(new Event('visibilitychange')); }catch(e){}
      kill(document);
      var fs = document.querySelectorAll ? document.querySelectorAll('iframe') : [];
      for(var j=0;j<fs.length;j++){
        try{ var fd = fs[j].contentDocument; if(fd){ kill(fd); continue; } }catch(e){}
        try{ kill(fs[j].contentWindow.document); }catch(e){}
        try{ if(fs[j].parentNode){ fs[j].parentNode.removeChild(fs[j]); } }catch(e){}
      }
      // 站点播放器库在事件队列尾部常会重挂媒体元素（隐藏节流播放器），
      // 接管注入点：拦截 appendChild/insertBefore 重建的媒体并立即销毁。
      var detach = function (m){
        try{ m.muted = true; }catch(e){}
        try{ if(m.pause) m.pause(); }catch(e){}
        try{ if(m.srcObject !== undefined){ m.srcObject = null; } }catch(e){}
        try{ if(m.parentNode){ m.parentNode.removeChild(m); } }catch(e){}
        return m;
      };
      try{
        var _append = Element.prototype.appendChild;
        Element.prototype.appendChild = function(child){
          if(child && (child.tagName === 'VIDEO' || child.tagName === 'AUDIO')){ detach(child); return child; }
          return _append.apply(this, arguments);
        };
        var _insert = Element.prototype.insertBefore;
        Element.prototype.insertBefore = function(child, ref){
          if(child && (child.tagName === 'VIDEO' || child.tagName === 'AUDIO')){ detach(child); return child; }
          return _insert.apply(this, arguments);
        };
      }catch(e){}
      // MutationObserver 兜底：同域文档里动态插入的媒体也会被销毁
      try{
        var _kill = function(){ kill(document); };
        var mo = new MutationObserver(_kill);
        mo.observe(document, {childList: true, subtree: true});
        setTimeout(function(){ try{ mo.disconnect(); }catch(e){} }, 5000);
      }catch(e){}
      return ts;
    })();
  ''';

  /// 解析期静音脚本：只 `muted` + `pause`，**不摘除**媒体元素与 iframe。
  ///
  /// 摘除会让「直链未捕获 → 超时降级网页播放」的站点播放器 iframe 从页面消失，
  /// 降级后直接黑屏，故解析期只压音量、保持播放器在位。跨域 iframe 取不到
  /// document 时无法静音（SecurityError），属平台限制，可接受——真正的双音轨
  /// 发生在切原生播放器时，由 [_destroyWebMediaJs] 硬销毁兜住。
  static const String _muteWebMediaJs = '''
    (function(){
      var mute = function(doc){
        if(!doc || !doc.querySelectorAll) return;
        var nodes = doc.querySelectorAll('video,audio');
        for(var i=0;i<nodes.length;i++){
          var m = nodes[i];
          try{ m.muted = true; }catch(e){}
          try{ m.pause(); }catch(e){}
        }
      };
      mute(document);
      var fs = document.querySelectorAll ? document.querySelectorAll('iframe') : [];
      for(var j=0;j<fs.length;j++){
        try{ var fd = fs[j].contentDocument; if(fd){ mute(fd); } }catch(e){}
      }
    })();
  ''';

  /// 解析直链期间压制网页播放器音量，防止直链未捕获前网页抢先出声（双音轨）。
  Future<void> _muteWebMedia() async {
    await _runJs(_muteWebMediaJs);
  }

  /// 空格播放/暂停：遍历顶层 + 同域 iframe 的全部 video/audio。
  /// 只停 `querySelector('video')` 第一个元素会漏掉多播放器/跨域 iframe
  /// 里的媒体——暂停后仍有声音的典型根因。跨域 iframe 取不到 document
  /// （SecurityError）无法控制，属平台限制。
  static const String _toggleWebMediaJs = '''
    (function(){
      var collect = function(doc){
        var list = [];
        if(!doc || !doc.querySelectorAll) return list;
        list.push.apply(list, doc.querySelectorAll('video,audio'));
        var fs = doc.querySelectorAll('iframe');
        for(var i=0;i<fs.length;i++){
          try{ var fd = fs[i].contentDocument; if(fd){ list = list.concat(collect(fd)); } }catch(e){}
        }
        return list;
      };
      var nodes = collect(document);
      var anyPlaying = false;
      for(var i=0;i<nodes.length;i++){
        try{ if(!nodes[i].paused){ anyPlaying = true; break; } }catch(e){}
      }
      for(var j=0;j<nodes.length;j++){
        try{
          if(anyPlaying){ nodes[j].pause(); } else { var pr = nodes[j].play(); if(pr && pr.catch){ pr.catch(function(){}); } }
        }catch(e){}
      }
    })();
  ''';

  /// 切原生播放器/退出页前杀掉网页媒体：先跑 [_destroyWebMediaJs] 硬销毁
  /// 顶层与同域 iframe 的媒体元素并把跨域 iframe 摘除，再停 WebView2、
  /// 导航到 about:blank 卸载整个文档树，最后同步把 WebView 从视图树移除。
  ///
  /// 导航前创建 [_pendingBlank]，onPageFinished 触发时 complete，
  /// 调用方可等文档树真正卸载完成再推原生播放器。
  Future<void> _killWebMedia() async {
    final d = _desktop;
    // 统一硬销毁脚本：顶层 + 同域 iframe 摘元素，跨域 iframe 摘 iframe。
    await _runJs(_destroyWebMediaJs);
    if (d != null) {
      try {
        await d.stop(); // WebView2 立即停止页面活动（含音频）
      } catch (_) {}
      // about:blank 连带卸载整个文档树（含跨域 iframe 里的 <video>），
      // 导航完成前网页音频仍可能出声，故在此登记等待对象。
      if (_pendingBlank == null || _pendingBlank!.isCompleted) {
        _pendingBlank = Completer<void>();
      }
      try {
        await d.loadUrl('about:blank');
      } catch (_) {}
    } else {
      if (_pendingBlank == null || _pendingBlank!.isCompleted) {
        _pendingBlank = Completer<void>();
      }
      try {
        await _controller.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
    }
    // 兜底：导航 API 不保证等文档真正卸载，给 onPageFinished 一个短暂窗口，
    // 仍未到达则强制 complete，避免 Completer 永久悬挂。
    final pending = _pendingBlank;
    if (pending != null) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!pending.isCompleted) pending.complete();
      });
    }
    // 同步物理移除 WebView：此后不再渲染、不再出声。
    if (mounted && !_webViewRemoved) {
      setState(() => _webViewRemoved = true);
    }
  }

  /// 网页通道集内续播：从 LocalStore 读取本页上次进度，页面就绪后
  /// 恢复到该秒数（mpv 通道由 NativePlayerPage._prepareResume 处理）。
  /// 恢复的进度与 mpv 通道共用同一 key（historyKey 同构），双通道互通。
  Future<void> _restoreProgress() async {
    if ((widget.sourceId?.isNotEmpty ?? false) == false ||
        widget.videoId == null) {
      return;
    }
    try {
      final key =
          '${widget.sourceId}/${widget.videoId}/$_curSeason-$_curEpisode';
      final sec = await LocalStore.videoProgressOf(key);
      if (sec <= 20 || !mounted) return;
      // 页面就绪但 <video> 可能还没创建/加载：延迟并等 readyState 达标再 seek，
      // 过早 seek 会失效（浏览器重置 currentTime）。有进度才 seek，避免回到 0。
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (!mounted) return;
      await _runJs('''
        (function(){
          var v = document.querySelector('video');
          if(!v) return 'novideo';
          var wait = function(attempt){
            if(attempt > 25) return 'timeout';
            try{
              if(v.readyState >= 2 && v.duration > 0 && v.duration !== Infinity){
                v.currentTime = $sec;
                return 'seek';
              }
            }catch(e){ return 'err'; }
            setTimeout(function(){ wait(attempt + 1); }, 200);
            return 'waiting';
          };
          return wait(0);
        })();
      ''');
    } catch (_) {}
  }

  /// 自动播放网页播放器：
  /// * 解析直链中（_resolving）：强制静音预载，画面仍被黑屏遮住，
  ///   出声只在原生播放器，杜绝"两个播放器叠音"。
  /// * 解析超时降级为网页播放（_resolving 已为 false）：解除静音出声，
  ///   并收起播放/暂停的按钮遮挡。
  void _triggerAutoPlay() async {
    if (_played) return;
    _played = true;
    await Future.delayed(const Duration(seconds: 2));
    await _applyWebViewSR();
    final muted = _resolving;
    await _runJs('''
      (function(){
        var v = document.querySelector('video');
        if(v){ v.muted = ${muted ? 'true' : 'false'}; v.play().catch(function(){}); return 'video'; }
        var b = document.querySelector('.artplayer-app video,.art-video video,[class*="play"],[id*="play"],.play-btn,button');
        if(b){ b.click(); return 'click'; }
        return 'none';
      })();
    ''');
  }

  /// 把画质增强(滤镜) CSS 应用到所有可见的 <video>（含跨域 iframe 内）。
  /// 注意：这仅是 CSS 对比度/饱和度滤镜，并非真实超分辨率；跨域 iframe 内的
  /// <video> 通常无法被父页样式触及，故多数情况下不生效。
  /// 跨域 iframe 无法直接改内部样式，这里通过给页面根元素加
  /// CSS 规则强制作用于最深层的 video 元素。
  Future<void> _applyWebViewSR() async {
    final css = _srLevel == 2
        ? 'contrast(1.18) saturate(1.25) brightness(1.06)'
        : _srLevel == 1
            ? 'contrast(1.06) saturate(1.08)'
        : '';
    await _runJs('''
      (function(){
        var id = 'sr-style';
        var old = document.getElementById(id);
        if(old) old.remove();
        if('$css' === '') return;
        var s = document.createElement('style');
        s.id = id;
        s.innerHTML = 'video { filter: $css !important; image-rendering: crisp-edges !important; -webkit-filter: $css !important; }';
        document.documentElement.appendChild(s);
      })();
    ''');
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _runJs('''
      (function(){
        var v = document.querySelector('video');
        if(v) v.muted = ${_muted ? 'true' : 'false'};
      })();
    ''');
  }

  // ── 移动端手势：左半屏亮度、右半屏音量 ────────────────────────────
  void _initBrightness() async {
    try {
      final v = await ScreenBrightness.instance.application;
      if (v >= 0 && v <= 1.0) {
        _brightnessNative = true;
        _brightness = v;
      }
    } catch (_) {
      _brightnessNative = false;
    }
    if (mounted) setState(() {});
  }

  void _onGestureDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch &&
        e.kind != PointerDeviceKind.stylus) {
      return;
    }
    if (_gestureActive) return;
    final w = MediaQuery.sizeOf(context).width;
    _gestureActive = true;
    _gesturePointer = e.pointer;
    // 全屏/小窗：以屏宽二分左右半屏
    _gestureVolume = e.localPosition.dx >= w / 2;
    _gestureStartValue = _gestureVolume ? _volume : _brightness;
    _gestureAccum = 0;
  }

  void _onGestureMove(PointerMoveEvent e) {
    if (!_gestureActive || e.pointer != _gesturePointer) return;
    _gestureAccum += e.delta.dy;
    if (_gestureAccum.abs() < _gestureSlop) return;
    final delta = -_gestureAccum / _gestureRef;
    if (_gestureVolume) {
      final nv = (_gestureStartValue + delta).clamp(0.0, 1.0);
      setState(() => _volume = nv);
      _applyVolume(nv);
      _showHud(volume: true, value: nv);
    } else {
      final nv = (_gestureStartValue + delta).clamp(0.0, 1.0);
      setState(() => _brightness = nv);
      _applyBrightness(nv);
      _showHud(volume: false, value: nv);
    }
  }

  void _onGestureUp(PointerEvent e) {
    if (!_gestureActive || e.pointer != _gesturePointer) return;
    _gestureActive = false;
    _gesturePointer = null;
    _gestureAccum = 0;
    _hideHud();
  }

  void _applyVolume(double v) {
    _runJs('''
      (function(){
        var vid = document.querySelector('video');
        if(vid) vid.volume = $v;
      })();
    ''');
    // 同步系统媒体音量（走音量键/系统 UI 时保持一致）
    try {
      VolumeController.instance.setVolume(v * 100);
    } catch (_) {}
  }

  void _applyBrightness(double v) {
    if (_brightnessNative) {
      try {
        ScreenBrightness.instance.setApplicationScreenBrightness(v);
      } catch (_) {
        _brightnessNative = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _showHud({required bool volume, required double value}) {
    if (!mounted) return;
    setState(() {
      _hudVisible = true;
      _hudVolume = volume;
      _hudValue = value;
    });
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  void _hideHud() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  Widget _gestureHud() {
    if (!_hudVisible) return const SizedBox.shrink();
    return SideLevelHud(
      left: !_hudVolume,
      icon: _hudVolume
          ? (_hudValue <= 0.001
              ? Icons.volume_off_rounded
              : (_hudValue < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded))
          : (_hudValue > 0.6
              ? Icons.brightness_high_rounded
              : (_hudValue > 0.25
                  ? Icons.brightness_medium_rounded
                  : Icons.brightness_low_rounded)),
      value: _hudValue,
      tint: _hudVolume ? Colors.white : const Color(0xFFFFD54F),
    );
  }

  /// 桌面端播放快捷键（WebView 层通过 JS 控制 video 元素）：
  /// 空格 播放/暂停、←/→ ±10s、M 静音、F 全屏、Esc 返回。
  bool _keyHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // 数字键：按百分比跳转（网页 video 无精确时长时用 0/50/100 三档，
    // 有 duration 时按 10% 步进）。
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
      _runJs('''
        (function(){
          var v = document.querySelector('video');
          if(!v) return;
          var dur = v.duration || 0;
          v.currentTime = dur > 0 ? dur * $d / 10 : 0;
        })();
      ''');
      return true;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _runJs(_toggleWebMediaJs);
        return true;
      // TV 遥控器媒体键：D-pad 中心键与播放/暂停、快进/快退、上下集映射到等价操作。
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.mediaPlayPause:
        _runJs(_toggleWebMediaJs);
        return true;
      case LogicalKeyboardKey.mediaFastForward:
      case LogicalKeyboardKey.arrowRight:
        _runJs('''
          (function(){
            var v = document.querySelector('video');
            if(v) v.currentTime = (v.currentTime||0) + 10;
          })();
        ''');
        return true;
      case LogicalKeyboardKey.mediaRewind:
      case LogicalKeyboardKey.arrowLeft:
        _runJs('''
          (function(){
            var v = document.querySelector('video');
            if(v) v.currentTime = Math.max(0, (v.currentTime||0) - 10);
          })();
        ''');
        return true;
      case LogicalKeyboardKey.mediaTrackNext:
        if (_hasNext) _goToAdjacent(1);
        return true;
      case LogicalKeyboardKey.mediaTrackPrevious:
        if (_hasPrev) _goToAdjacent(-1);
        return true;
      case LogicalKeyboardKey.arrowUp:
        _runJs('''
          (function(){
            var v = document.querySelector('video');
            if(v) v.volume = Math.min(1, (v.volume||0) + 0.1);
          })();
        ''');
        return true;
      case LogicalKeyboardKey.arrowDown:
        _runJs('''
          (function(){
            var v = document.querySelector('video');
            if(v) v.volume = Math.max(0, (v.volume||0) - 0.1);
          })();
        ''');
        return true;
      case LogicalKeyboardKey.keyM:
        _toggleMute();
        return true;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        return true;
      case LogicalKeyboardKey.keyN:
        if (_hasNext) _goToAdjacent(1);
        return true;
      case LogicalKeyboardKey.keyP:
        if (_hasPrev) _goToAdjacent(-1);
        return true;
      case LogicalKeyboardKey.bracketLeft:
        _setSpeed((_speed - 0.25).clamp(0.25, 4.0));
        return true;
      case LogicalKeyboardKey.bracketRight:
        _setSpeed((_speed + 0.25).clamp(0.25, 4.0));
        return true;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).maybePop();
        return true;
      default:
        return false;
    }
  }

  bool _tvKeysRegistered = false;

  /// Android TV 遥控器媒体键（网页通道）：播放/暂停、快进/快退、上下集。
  /// 只认 media-* 键，不碰 select/方向键（那是焦点系统的领地）。
  bool _tvKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.mediaPlayPause:
        _runJs(_toggleWebMediaJs);
        return true;
      case LogicalKeyboardKey.mediaFastForward:
        _runJs('''
          (function(){
            var v = document.querySelector('video');
            if(v) v.currentTime = (v.currentTime||0) + 10;
          })();
        ''');
        return true;
      case LogicalKeyboardKey.mediaRewind:
        _runJs('''
          (function(){
            var v = document.querySelector('video');
            if(v) v.currentTime = Math.max(0, (v.currentTime||0) - 10);
          })();
        ''');
        return true;
      case LogicalKeyboardKey.mediaTrackNext:
        if (_hasNext) _goToAdjacent(1);
        return true;
      case LogicalKeyboardKey.mediaTrackPrevious:
        if (_hasPrev) _goToAdjacent(-1);
        return true;
      default:
        return false;
    }
  }

  void _toggleFullscreen() {
    if (_fullscreen) {
      _exitFullscreen();
    } else {
      _enterFullscreen();
    }
  }

  /// 「Web 调色」按钮切换时重新应用 CSS（不是真超分）。
  void _cycleSr() {
    setState(() => _srLevel = (_srLevel + 1) % 3);
    _applyWebViewSR();
  }

  /// 选集上/下一集切换：用 resolveUrl 重新加载该集网页。
  void _goToAdjacent(int delta) {
    final eps = widget.episodes;
    if (eps.isEmpty) return;
    final idx = _currentIndex;
    final target = (idx < 0 ? 0 : idx) + delta;
    if (target < 0 || target >= eps.length) return;
    final ep = eps[target];
    _switchToEpisode(ep.season, ep.episode);
  }

  /// 当前集在 [widget.episodes] 中的下标；找不到返回 -1。
  int get _currentIndex => widget.episodes.indexWhere(
      (e) => e.season == _curSeason && e.episode == _curEpisode);

  /// 下一集在 [widget.episodes] 中的下标；无下一集返回 -1。
  int get _nextIndex {
    final i = _currentIndex;
    return (i >= 0 && i < widget.episodes.length - 1) ? i + 1 : -1;
  }

  /// 后台预热下一集直链（连播零等待）。失败 30 秒后重试一次，防源站接口抖动。
  void _prefetchNext(String key) {
    final resolver = widget.resolveUrl;
    if (resolver == null) return;
    final idx = _nextIndex;
    if (idx < 0) return;
    final ep = widget.episodes[idx];
    if (ep.season == _curSeason && ep.episode == _curEpisode) return;
    _prefetchKey = key;
    _prefetchingNext = true;
    resolver(ep.season, ep.episode).then((url) {
      if (mounted && _prefetchKey == key) {
        _prefetchedNextUrl = url;
      }
    }).catchError((Object e) {
      // 预热失败不打断播放；30 秒后轮询会再试一次
      _prefetchRetryAt =
          DateTime.now().add(const Duration(seconds: 30));
    }).whenComplete(() {
      if (_prefetchKey == key) _prefetchingNext = false;
    });
  }

  /// 真正切集：更新当前集状态，并让 WebView 重新加载新一集的播放页。
  /// [_switchingEp]/[_switchGen] 防连点：旧请求在 await 后作废，不覆写新集状态。
  Future<void> _switchToEpisode(int season, int episode) async {
    if (!_webviewInit) return;
    final resolver = widget.resolveUrl;
    if (resolver == null) return;
    if (!mounted || _switchingEp) return;
    _switchingEp = true;
    final gen = ++_switchGen;
    _autoNextFired = false; // 新一集允许重新自动连播
    setState(() {
      _curSeason = season;
      _curEpisode = episode;
      _loading = true;
      _resolving = true; // 新一集重新进入"静音解析"状态，防止旧页残留出声
      _webError = null; // 切集开始即离开上次错误态，回到解析 loading
      _switchFail = false;
    });
    // _played 标记首屏自动播放已触发过；切集后必须复位，否则新一集重新
    // loadRequest + onPageFinished 再调 _triggerAutoPlay 时直接 return，
    // 新集既不做静音预载也不做播放点击兜底（对需手势的站点是唯一启动手段）。
    _played = false;
    // 新一集重新走捕获流程：清掉旧集直链缓存与接管标志，否则新集直链
    // 会被 _onVideoSrcCaptured 误判为「已接管后的换源」直接忽略，
    // 永远切不回原生播放器。
    _hookedVideoUrl = '';
    _handedOffToMpv = false;
    // 杀掉旧页媒体，避免加载新集期间旧集继续出声（双音轨）
    await _killWebMedia();
    if (!mounted || gen != _switchGen) {
      _switchingEp = false;
      return;
    }
    // 复位 WebView 挂载：新集要重新用 WebView 解析直链，
    // 否则上一步的物理移除会让新集一直黑屏。
    if (_webViewRemoved) setState(() => _webViewRemoved = false);
    final prefetchKey = '$season-$episode';
    final cached = _prefetchedNextUrl;
    String url;
    try {
      url = (prefetchKey == _prefetchKey && cached != null)
          ? cached
          : await _resolveWithRetry(resolver, season, episode);
    } catch (e) {
      // 直链解析二次失败：持久错误态（替代黑屏卡死），重试入口 = 错误态重试按钮。
      if (mounted && gen == _switchGen) {
        setState(() {
          _loading = false;
          _resolving = false;
          _switchFail = true;
          _webError ??= '切集失败，请检查网络后重试';
        });
      }
      _switchingEp = false;
      return;
    }
    // 已消费的预热缓存作废，防止手动切回旧集误用过期直链
    if (prefetchKey == _prefetchKey) {
      _prefetchedNextUrl = null;
      _prefetchKey = '';
    }
    if (!mounted || gen != _switchGen) {
      _switchingEp = false;
      return;
    }
    final d = _desktop;
    try {
      if (d != null) {
        await d.loadUrl(url);
      } else {
        await _controller.loadRequest(Uri.parse(url),
            headers: _hostHeader(url));
      }
    } catch (e) {
      if (mounted && gen == _switchGen) {
        setState(() {
          _loading = false;
          _switchFail = true;
          _webError ??= '切集失败，请检查网络后重试';
        });
      }
    }
    // 装载成功：复位切集失败标记（_webError 由加载状态回调清空）。
    if (_switchFail && mounted && gen == _switchGen) {
      setState(() => _switchFail = false);
    }
    // ⚠️ _resolving 自本次切换起为 true，且 initState 里的 8 秒 _resolveTimer
    // 早已触发过：不重建的话（目标集走 blob/MSE 或捕获失败时）_resolving
    // 永远为 true，黑幕"解析直链中…"永挂 + 轮询每 900ms 强杀网页音频，
    // 用户既看不到画面也听不到声音。这里重新武装一次超时放弃计时器。
    if (mounted && gen == _switchGen) {
      _resolveTimer?.cancel();
      _resolveTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _resolving) {
          setState(() => _resolving = false);
          _resolveFault = true;
        }
      });
    }
    _switchingEp = false;
  }

  /// 解析直链：直接失败时静默重试一次（源站解析接口偶发 5xx/超时）。
  Future<String> _resolveWithRetry(
      Future<String> Function(int season, int episode) resolver,
      int season,
      int episode) async {
    try {
      return await resolver(season, episode);
    } catch (e) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return resolver(season, episode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 降级页跟随应用主题；WebView 播放器保持纯黑影院底。
      backgroundColor:
          _webviewInit ? Colors.black : Theme.of(context).colorScheme.surface,
      body: !_webviewInit
          // WebView2 异步初始化期间显示加载态；真正不可用才显示降级页。
          ? (_desktop != null && !_desktopInitFailed
              ? const Center(
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              : _desktopFallbackBody())
          : _fullscreen
              ? _fullBody()
              : _normalBody(),
    );
  }

  /// 无内嵌 WebView（Linux）或 WebView2 初始化失败时的降级页：
  /// 用系统浏览器打开原网页播放，并提示切换到 App 内原生播放的线路。
  Widget _desktopFallbackBody() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.desktop_windows_outlined,
                    size: 34, color: scheme.primary),
              ),
              const SizedBox(height: 18),
              Text(_desktopInitFailed ? '网页播放器不可用' : '该线路需要网页播放',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              const SizedBox(height: 10),
              Text(
                _desktopInitFailed
                    ? '系统缺少 WebView2 运行时，无法内嵌网页解析直链。'
                        '请安装 Microsoft Edge WebView2 Runtime 后重试，'
                        '或先用系统浏览器观看。'
                    : '此线路的播放地址由站点网页加密提供，当前平台暂不支持内嵌'
                        '网页播放器。你可以用系统浏览器打开继续观看，'
                        '或在下方切到支持 App 内原生播放的线路。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('用系统浏览器播放'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('返回切换线路'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                ),
              ),
              if (_desktopInitFailed) ...[
                const SizedBox(height: 12),
                // 重试内嵌播放：初始化失败不再永久锁死本页，
                // 用户可在装好 WebView2 运行时后当场重试，无需退出重进。
                OutlinedButton.icon(
                  onPressed: _desktopRetry ? null : _retryDesktopInit,
                  icon: _desktopRetry
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(_desktopRetry ? '正在重试…' : '重试内嵌播放'),
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                  ),
                ),
              ],
              if (widget.episodes.length > 1) ...[
                const SizedBox(height: 28),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('本集其它线路',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
                const SizedBox(height: 10),
                _fallbackSourceChips(scheme),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  /// 降级页里的切集按钮：解析目标集地址，直链则进原生播放器，
  /// 否则仍走本降级页（用 pushReplacement 保持返回栈干净）。
  Widget _fallbackSourceChips(ColorScheme scheme) {
    final eps = widget.episodes;
    final resolver = widget.resolveUrl;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final ep in eps.take(30))
          OutlinedButton(
            onPressed: resolver == null
                ? null
                : () => _fallbackSwitch(ep.season, ep.episode),
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              foregroundColor:
                  ep.episode == _curEpisode ? scheme.primary : null,
            ),
            child: Text(ep.title.isEmpty ? '第${ep.episode}集' : ep.title,
                style: const TextStyle(fontSize: 12.5)),
          ),
      ],
    );
  }

  Future<void> _fallbackSwitch(int season, int episode) async {
    final resolver = widget.resolveUrl;
    if (resolver == null) return;
    try {
      final url = await resolver(season, episode);
      if (!mounted) return;
      if (isDirectMediaUrl(url)) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => NativePlayerPage(
              url: url,
              title: widget.title,
              cover: widget.cover,
              episodes: widget.episodes,
              season: season,
              episode: episode,
              resolveUrl: widget.resolveUrl,
              sourceNames: widget.sourceNames,
              sourceId: widget.sourceId,
              videoId: widget.videoId,
              webChannelBuilder: animePlayerWebChannel,
            ),
            transitionDuration: context.uiStyle == UIStyle.minimalist
                ? const Duration(milliseconds: 260)
                : StyleTokens.transitionDuration(context),
            transitionsBuilder: (_, anim, __, child) =>
                FadeTransition(opacity: anim, child: child),
          ),
        );
      } else {
        setState(() {
          _curSeason = season;
          _curEpisode = episode;
        });
        await _launchExternal(url);
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '切换失败，请重试');
        ErrorLogger.instance.warn('anime player switch failed: $e');
      }
    }
  }

  Future<void> _openInBrowser() => _launchExternal(_browserFriendlyUrl(widget.url));

  /// 打开系统浏览器前把地址修正为浏览器可访问的形态：
  /// * tvtfun 等源在 App 内走「优选 IP 直连」（Host 头由 WebView 附带），
  ///   系统浏览器无法设置 Host 头，直连 IP 必然证书/SNI 失败 → 改回真实域名。
  String _browserFriendlyUrl(String url) {
    try {
      final u = Uri.parse(url);
      final host = u.host;
      if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) &&
          Net.preferredHostIps.entries.any((e) => e.value.contains(host))) {
        // 找到该 IP 对应的真实域名并替换
        final realHost = Net.preferredHostIps.entries
            .firstWhere((e) => e.value.contains(host),
                orElse: () => const MapEntry('', []))
            .key;
        if (realHost.isNotEmpty) {
          return u.replace(host: realHost).toString();
        }
      }
    } catch (_) {}
    return url;
  }

  Future<void> _launchExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!await canLaunchUrl(uri)) {
        if (mounted) {
          AppToast.error(context, '无法打开系统浏览器');
        }
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '打开浏览器失败，请重试');
        ErrorLogger.instance.warn('anime browser launch failed: $e');
      }
    }
  }

  /// 全屏：WebView 铺满屏幕 + 原生风格控制浮层（返回/静音/超分/切集/退出）。
  Widget _fullBody() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _webView(),
        _fullscreenOverlay(),
      ],
    );
  }

  Widget _normalBody() {
    // 平板横屏：左视频(16:9 居中、纯黑底) + 右固定宽度竖控制面板，
    // 与手机端面板控件/顺序一致，仅布局从上下堆叠改为左右分栏。
    if (Responsive.isTablet(context)) {
      return Container(
        color: Colors.black,
        // SafeArea：横屏挖孔屏/刘海下 WebView 与面板不顶进系统区域（与 native_player 对齐）。
        child: SafeArea(
          bottom: false,
          child: Row(children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _webView(),
                ),
              ),
            ),
            Container(
              width: _panelWidth,
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Colors.white12, width: 0.8),
                ),
              ),
              child: _belowPanel(),
            ),
          ]),
        ),
      );
    }
    return Column(children: [
      AspectRatio(aspectRatio: 16 / 9, child: _webView()),
      Expanded(child: _belowPanel()),
    ]);
  }

  Widget _webView() {
    // 已物理移除（切原生播放器/退出页）：不再渲染 WebView，防止其
    // 在转场动画期间继续播放/出声（双播放器叠音）。
    if (_webViewRemoved) return const SizedBox.shrink();
    final d = _desktop;
    // 移动端：视频区外包 raw Listener 采集单指上下滑手势（亮度/音量），
    // 不参与手势竞技场，与 WebView 内部滚动/点击互不抢占。
    return Listener(
      onPointerDown: _onGestureDown,
      onPointerMove: _onGestureMove,
      onPointerUp: _onGestureUp,
      onPointerCancel: _onGestureUp,
      child: Stack(children: [
        d != null ? d.buildView() : WebViewWidget(controller: _controller),
        // 亮度降级遮罩（无系统亮度权限时模拟变暗）
        if (!_brightnessNative)
          IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: (1.0 - _brightness) * 0.75,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        // 手势 HUD（音量/亮度条）：放在视频区内部，随视频区域定位
        _gestureHud(),
        if (_webError != null)
          // 主框架加载失败：错误态 + 重试（替代黑屏/白屏）
          Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off_rounded,
                      color: Colors.white54, size: 34),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _webError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _retryError,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (_loading || _resolving)
          // 解析中或加载中：黑屏 + loading，隐藏网页内容防止"两层壳"闪烁
          Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _resolving ? '解析直链中…' : '加载中…',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ]),
    );
  }

  /// 错误态重试：切集失败时重跑切集到目标集；普通页面加载失败走 reload。
  void _retryError() {
    if (_switchFail) {
      _switchFail = false;
      _switchToEpisode(_curSeason, _curEpisode);
      return;
    }
    _reloadWebView();
  }

  /// 错误态重试：重置解析状态、重启直链捕获，重新加载当前播放页。
  void _reloadWebView() {
    setState(() {
      _webError = null;
      _loading = true;
      _resolving = true;
    });
    _played = false; // 重载后允许重新触发自动播放
    _resolveTimer?.cancel();
    _resolveTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _resolving) {
        setState(() => _resolving = false);
        // 真机 AGE 源直链捕获长期失败时开启 Hls 诊断（排查用）
        _resolveFault = true;
      }
    });
    // 重试是新一次捕获流程：清掉上次的直链缓存与「已接管」标志，
    // 否则广告→正片那次误接管会让重试也直接 return。
    _hookedVideoUrl = '';
    _handedOffToMpv = false;
    _hookVideoSource();
    _injectApiInterceptor();
    // 重试期间保持静音解析：先杀旧页媒体，再重新加载（防止旧页残留出声）
    _muteWebMedia();
    final d = _desktop;
    if (d != null) {
      d.reload();
    } else {
      _controller.reload();
    }
  }

  /// 巡逻已注入的 video 是否播完（ended 监听），播完且有下一集 → 切集。
  /// 放轮询里做：页面每次加载/重载后 JS 都会重挂，且不用等事件冒泡。
  static const String _autoNextJs = '''
    (function(){
      var v = (function(doc){
        var v = doc && doc.querySelector('video');
        if (v) return v;
        var f = doc && doc.querySelector('iframe');
        if (f) { try { return f.contentDocument ? f.contentDocument.querySelector('video') : null; } catch(e){} }
        return null;
      })(document);
      if (!v) return '';
      return v.ended ? 'ENDED' : '';
    })()
  ''';

  /// 巡逻 video 剩余时长（秒）。取不到或未播放返回空串；-1 表示未初始化。
  /// 放轮询里做：每 900ms 回答一次当前集是否临近结尾，供下一集直链预热。
  static const String _videoRemainJs = '''
    (function(){
      try {
        var v = (function(doc){
          var v = doc && doc.querySelector('video');
          if (v) return v;
          var f = doc && doc.querySelector('iframe');
          if (f) { try { return f.contentDocument ? f.contentDocument.querySelector('video') : null; } catch(e){} }
          return null;
        })(document);
        if (!v) return '';
        if (v.seekable && v.seekable.length > 0) {
          var d = v.seekable.end(v.seekable.length - 1);
          if (isFinite(d) && isFinite(v.currentTime)) {
            return Math.max(0, d - v.currentTime).toFixed(0);
          }
        }
        if (isFinite(v.duration) && isFinite(v.currentTime)) {
          return Math.max(0, v.duration - v.currentTime).toFixed(0);
        }
        return '';
      } catch(e) { return ''; }
    })()
  ''';

  /// 在轮询回调里检测播完状态；触发后去重，避免每秒重复切集。
  bool _autoNextFired = false;

  /// 下一集直链预热：剩余时长 ≤5 分钟时后台解析一次，连播/手动切集零等待。
  /// [resolveUrl] 命中源站解析接口，冷切换通常要等 1~3 秒，预热后直接加载。
  String? _prefetchedNextUrl;
  String _prefetchKey = ''; // 已预热的目标集，形如 'season-episode'
  bool _prefetchingNext = false;
  DateTime _prefetchRetryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 统一全屏入口：无论用户点击页面内任何位置进入全屏，
  /// 都转成 app 级横屏全屏（而非 WebView 自带的竖屏全屏），
  /// 退出时恢复竖屏，避免整个软件卡在横屏。
  void _enterFullscreen() {
    if (_fullscreen) return;
    setState(() => _fullscreen = true);
    _fsShowControls();
    _startFsPoll();
    // 桌面端把系统窗口本体切到真全屏（占满屏幕），移动端保持沉浸+横屏。
    PlayerFullscreen.enter();
  }

  void _exitFullscreen() {
    if (!_fullscreen) return;
    setState(() => _fullscreen = false);
    _fsHideTimer?.cancel();
    _fsPollTimer?.cancel();
    PlayerFullscreen.exit();
  }

  // ══ 竖屏下方面板（与原生播放器 _belowPanel 对齐） ══════════════
  Widget _belowPanel() {
    final base = Theme.of(context).colorScheme;
    // 平板分栏右侧面板使用深色配色，提升影音质感（避免纯白面板在看番时刺眼）
    final scheme = Responsive.isTablet(context)
        ? ColorScheme.fromSeed(
            seedColor: base.primary, brightness: Brightness.dark)
        : base;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    final eps = widget.episodes;
    final multi = eps.length > 1;
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
            if (eps.isNotEmpty) _metaChip(scheme, _epLabel()),
            if (_srLevel > 0)
              _metaChip(scheme, _srName,
                  icon: Icons.auto_awesome_rounded, highlight: true),
            if (_speed != 1.0)
              _metaChip(scheme, '${_trimSpeed(_speed)}x',
                  icon: Icons.speed_rounded),
          ]),
          if (multi) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _stepBtn(scheme, Icons.skip_previous_rounded, '上一集',
                    _hasPrev ? () => _goToAdjacent(-1) : null),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _stepBtn(scheme, Icons.skip_next_rounded, '下一集',
                    _hasNext ? () => _goToAdjacent(1) : null),
              ),
            ]),
          ],
          const SizedBox(height: 14),
          if (eps.isNotEmpty)
            Row(children: [
              Expanded(
                child: _stepBtn(scheme, Icons.fullscreen_rounded, '全屏播放',
                    _toggleFullscreen),
              ),
            ]),
          const SizedBox(height: 14),
          _srCardWeb(scheme),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _miniCardWeb(scheme, Icons.speed_rounded, '倍速',
                    '${_trimSpeed(_speed)}x', _showSpeedPanel)),
            const SizedBox(width: 10),
            Expanded(
                child: _miniCardWeb(scheme, Icons.auto_awesome_rounded, '画质增强(滤镜)',
                    _srName, _showSrPanel,
                    active: _srLevel > 0)),
            const SizedBox(width: 10),
            Expanded(
                child: _miniCardWeb(scheme, Icons.tune_rounded, '快速增强',
                    _srLevel > 0 ? '已开启' : '已关闭', () => _cycleSr(),
                    active: _srLevel > 0)),
          ]),
          if (widget.description != null && widget.description!.isNotEmpty) ...[
            const SizedBox(height: 14),
            _descCard(scheme),
          ],
          if (eps.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(children: [
              Text('选集',
                  style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text(_episodeCountLabel(),
                  style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.5),
                      fontSize: 12)),
              const Spacer(),
              if (eps.length > _gridLimit)
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

  String get _srName => ['关', '滤镜·性能', '滤镜·质量'][_srLevel];

  String _epLabel() {
    final eps = widget.episodes;
    final i =
        eps.indexWhere((e) => e.season == _curSeason && e.episode == _curEpisode);
    if (i >= 0) {
      final t = eps[i].title;
      return t.isEmpty ? '第 $_curEpisode 集' : t;
    }
    return '第 $_curEpisode 集';
  }

  /// 集数标签：委托 [episodeCountLabelFor]，多线路绝不把各渠道剧集相加。
  String _episodeCountLabel() => episodeCountLabelFor(
        widget.episodes,
        widget.sourceNames,
        currentSeason: _curSeason,
        currentEpisode: _curEpisode,
      );

  static const int _gridLimit = 40;

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
                color: scheme.onSurface.withValues(alpha: 0.5), fontSize: 11.5)),
      ]),
    );
  }

  Widget _episodeTile(ColorScheme scheme, VideoEpisode e) {
    final cur = e.season == _curSeason && e.episode == _curEpisode;
    return KeyedSubtree(
      // 当前集方块挂定位锚点：选集面板打开时滚进视口。
      key: cur ? _curEpKey : null,
      child: InkWell(
        onTap: () => _switchToEpisode(e.season, e.episode),
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

  Widget _episodeGrid(ColorScheme scheme) {
    final flat = widget.episodes;
    final bySeason = <int, List<VideoEpisode>>{};
    for (final e in flat) {
      (bySeason[e.season] ??= []).add(e);
    }
    final keys = bySeason.keys.toList()..sort();
    final groups = [
      for (final k in keys)
        (name: widget.sourceNames?[k] ?? '线路 $k', eps: bySeason[k]!),
    ];
    final multi = groups.length > 1;
    final children = <Widget>[];
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      if (multi) children.add(_groupHeader(scheme, g.name, g.eps.length));
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: g.eps.map((e) => _episodeTile(scheme, e)).toList(),
      ));
      if (gi < groups.length - 1) children.add(const SizedBox(height: 12));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _descCard(ColorScheme scheme) {
    return InkWell(
      onTap: () => setState(() => _descExpanded = !_descExpanded),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.description!,
              maxLines: _descExpanded ? null : 3,
              overflow: _descExpanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: scheme.onSurface.withValues(alpha: 0.85))),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Text(_descExpanded ? '收起' : '展开',
                style: TextStyle(
                    fontSize: 12,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600)),
            Icon(_descExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: scheme.primary),
          ]),
        ]),
      ),
    );
  }

  Widget _srCardWeb(ColorScheme scheme) {
    final on = _srLevel > 0;
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
                    Flexible(
                      child: Text('网页画质增强(滤镜)',
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
                        child: Text(_srName,
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
                  Text('基于 CSS 滤镜，开销极小；卡顿请关闭',
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

  Widget _miniCardWeb(ColorScheme scheme, IconData icon, String label,
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

  Widget _stepBtn(ColorScheme scheme, IconData icon, String label,
      VoidCallback? onTap) {
    final on = onTap != null;
    final fg = on ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.3);
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
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg)),
          ]),
        ),
      ),
    );
  }

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

  // ══ 全屏控制浮层（与原生播放器控制条风格一致） ══════════════
  Widget _fullscreenOverlay() {
    final pad = MediaQuery.of(context).viewPadding;
    final sideL = pad.left > 0 ? pad.left + 4 : 16.0;
    final sideR = pad.right > 0 ? pad.right + 4 : 16.0;
    final bottom = pad.bottom > 0 ? 12.0 : 8.0;
    final top = pad.top > 0 ? pad.top + 4 : 8.0;
    final visible = _fsControlsVisible;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (!visible) {
          _fsShowControls();
        } else {
          setState(() => _fsControlsVisible = false);
        }
      },
      // 轻点控制浮层内的按钮不触发隐藏切换（按钮自身处理）。
      child: Stack(fit: StackFit.expand, children: [
        AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: IgnorePointer(
            ignoring: !visible,
            child: _fullscreenControlLayer(sideL, sideR, top, bottom),
          ),
        ),
      ]),
    );
  }

  Widget _fullscreenControlLayer(
      double sideL, double sideR, double top, double bottom) {
    final progress = _fsDur > 0 ? (_fsPos / _fsDur).clamp(0.0, 1.0) : 0.0;
    return Stack(fit: StackFit.expand, children: [
      Align(
        alignment: Alignment.topCenter,
        child: Container(
          padding: EdgeInsets.fromLTRB(sideL, top, sideR, 26),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.0, 0.65, 1.0],
              colors: [
                Color(0xCC000000),
                Color(0x59000000),
                Color(0x00000000)
              ],
            ),
          ),
          child: Row(children: [
            _barBtn(Icons.arrow_back_ios_new_rounded, _exitFullscreen),
            const SizedBox(width: 4),
            Expanded(
              child: Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
            _barBtn(_muted ? Icons.volume_off : Icons.volume_up, _toggleMute),
            _barBtn(
                _srLevel > 0
                    ? Icons.auto_awesome_rounded
                    : Icons.auto_awesome_outlined,
                _cycleSr,
                active: _srLevel > 0),
          ]),
        ),
      ),
      Align(
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
              ],
            ),
          ),
          child: SizedBox(
            height: 40,
            child: Row(children: [
              _barBtn(_fsPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  _fsTogglePlay),
              _barBtn(Icons.skip_previous_rounded,
                  _hasPrev ? () => _goToAdjacent(-1) : null),
              _barBtn(Icons.skip_next_rounded,
                  _hasNext ? () => _goToAdjacent(1) : null),
              const SizedBox(width: 8),
              Text(_formatDuration(_fsPos),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11.5)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 13),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white30,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                    ),
                    child: Slider(
                      value: progress,
                      onChanged: (v) {
                        setState(() {
                          _fsSeeking = true;
                          _fsPos = v * _fsDur;
                          _fsControlsVisible = true;
                        });
                      },
                      onChangeEnd: (v) {
                        _fsSeekTo(v * _fsDur);
                        setState(() => _fsSeeking = false);
                        _fsShowControls();
                      },
                    ),
                  ),
                ),
              ),
              Text(_formatDuration(_fsDur),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11.5)),
              const Spacer(),
              _textBtn('${_trimSpeed(_speed)}x', _showSpeedPanel,
                  icon: Icons.speed_rounded),
              _textBtn('画质增强', _showSrPanel,
                  icon: Icons.auto_awesome_rounded, active: _srLevel > 0),
              _textBtn('选集', _showEpisodePanel,
                  icon: Icons.playlist_play_rounded),
              _barBtn(Icons.fullscreen_exit_rounded, _exitFullscreen),
            ]),
          ),
        ),
      ),
    ]);
  }

  bool get _hasPrev {
    final eps = widget.episodes;
    if (eps.isEmpty) return false;
    final idx =
        eps.indexWhere((e) => e.season == _curSeason && e.episode == _curEpisode);
    return hasPrevEpisode(idx);
  }

  bool get _hasNext {
    final eps = widget.episodes;
    if (eps.isEmpty) return false;
    return hasNextEpisode(_currentIndex, eps.length);
  }

  /// 全屏控制浮层：缺进度条/时间/播放暂停控件，且永不自动隐藏遮挡画面。
  /// 本页补齐：播放/暂停 + 可拖进度条 + 当前时间/总时长 + 3 秒无操作自动淡出
  /// （点按/触摸画面唤回）。播放状态与进度来自对 WebView 内 <video> 的 JS 轮询
  /// （每 1 秒取 paused/currentTime/duration），仅在 WebView 通道残留时有效。
  bool _fsPlaying = true;
  double _fsPos = 0;
  double _fsDur = 0;
  bool _fsSeeking = false;
  Timer? _fsHideTimer;
  bool _fsControlsVisible = true;
  static const int _fsHideDelayMs = 3000;

  /// 全屏控制层显示状态更新：延后 [ _fsHideDelayMs] 自动隐藏。
  void _fsShowControls() {
    setState(() => _fsControlsVisible = true);
    _fsHideTimer?.cancel();
    _fsHideTimer = Timer(const Duration(milliseconds: _fsHideDelayMs), () {
      if (mounted && !_fsSeeking) setState(() => _fsControlsVisible = false);
    });
  }

  String _formatDuration(double sec) {
    if (!sec.isFinite || sec < 0) return '00:00';
    final s = sec.round();
    final m = s ~/ 60;
    final r = s % 60;
    final mm = (m % 60).toString().padLeft(2, '0');
    if (m >= 60) {
      final h = m ~/ 60;
      final hh = h.toString().padLeft(2, '0');
      return '$hh:$mm:${r.toString().padLeft(2, '0')}';
    }
    return '$mm:${r.toString().padLeft(2, '0')}';
  }

  static String _trimSpeed(double s) =>
      s == s.roundToDouble() ? s.toStringAsFixed(1) : s.toString();

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

  // ══ 面板 ══════════════════════════════════════════════════
  void _showSpeedPanel() {
    showPlayerPanel(
      context: context,
      title: '播放速度',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 3.5, 4.0];
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
          ]),
        );
      }),
    );
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _applySpeed();
  }

  void _applySpeed() {
    _runJs('''
      (function(){
        var v = document.querySelector('video');
        if(v) v.playbackRate = $_speed;
      })();
    ''');
  }

  void _showSrPanel() {
    showPlayerPanel(
      context: context,
      title: '网页画质增强(滤镜)',
      fromRight: _fullscreen,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            PanelOptionTile(
              title: '关',
              subtitle: '原画输出，不做任何处理',
              selected: _srLevel == 0,
              onTap: () {
                setState(() => _srLevel = 0);
                _applyWebViewSR();
                setSheet(() {});
              },
            ),
            PanelOptionTile(
              title: '性能',
              subtitle: '轻度对比/饱和提升，开销极小',
              selected: _srLevel == 1,
              onTap: () {
                setState(() => _srLevel = 1);
                _applyWebViewSR();
                setSheet(() {});
              },
            ),
            PanelOptionTile(
              title: '质量',
              subtitle: '更强对比/饱和，画质更锐',
              selected: _srLevel == 2,
              onTap: () {
                setState(() => _srLevel = 2);
                _applyWebViewSR();
                setSheet(() {});
              },
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '提示：网页端仅为 CSS 滤镜增强，并非真实超分辨率；跨域播放器内的视频可能无法生效。\n'
                '需要真正超分请使用「App 内原生播放器」（捕获直链后自动进入，'
                'Anime4K CNN 超分）。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.55),
                ),
              ),
            ),
          ]),
        );
      }),
    );
  }

  void _showEpisodePanel() {
    if (widget.episodes.isEmpty) return;
    final flat = widget.episodes;
    final bySeason = <int, List<VideoEpisode>>{};
    for (final e in flat) {
      (bySeason[e.season] ??= []).add(e);
    }
    final keys = bySeason.keys.toList()..sort();
    final groups = [
      for (final k in keys)
        (name: widget.sourceNames?[k] ?? '线路 $k', eps: bySeason[k]!),
    ];
    final multi = groups.length > 1;
    showPlayerPanel(
      context: context,
      title: '选集 · ${_episodeCountLabel()}',
      fromRight: _fullscreen,
      width: 360,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        _scrollCurrentEpisodeIntoView(); // 打开即把当前集滚进视口
        final children = <Widget>[];
        for (final g in groups) {
          if (multi) {
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
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (!cur) _switchToEpisode(e.season, e.episode);
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
    );
  }

  /// 把当前集方块滚进视口（选集面板打开时）。
  void _scrollCurrentEpisodeIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _curEpKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
    });
  }

}

/// 截断长 URL 用于日志（超过 80 字符保留前后各 40）。
String _trimUrl(String url) {
  if (url.length <= 80) return url;
  return '${url.substring(0, 40)}…${url.substring(url.length - 40)}';
}
