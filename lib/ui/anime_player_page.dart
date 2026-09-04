import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../net/local_store.dart';
import '../sources/video_source.dart';
import 'desktop_webview.dart';
import 'native_player_page.dart';
import 'responsive.dart';
import 'widgets/player_widgets.dart';

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
  });

  @override
  State<AnimePlayerPage> createState() => _AnimePlayerPageState();
}

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
  double _speed = 1.0;
  bool _descExpanded = false;

  /// WebView 是否真的初始化完成。桌面端异步 initialize，完成前显示加载态。
  bool _webviewInit = false;

  /// 桌面 WebView2 初始化失败（缺运行时等）：显示系统浏览器降级页。
  bool _desktopInitFailed = false;

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
  Timer? _resolveTimer;
  // WebView 主页面加载失败（断网/超时/服务器错误）时记录，优先展示错误态而非黑屏。
  String? _webError;

  static const ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 若 URL 主机是 IP（Cloudflare 优选 IP 直连），返回正确的 Host 头，
  /// 否则返回空。WebView 直连 IP 仍需 CDN 证书覆盖该域名，否则会证书错误。
  static Map<String, String> _hostHeader(String url) {
    try {
      final host = Uri.parse(url).host;
      if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
        return {'Host': 'www.tvtfun.net'};
      }
    } catch (_) {}
    return const {};
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _curSeason = widget.initialSeason;
    _curEpisode = widget.initialEpisode;
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
        setState(() {
          _webError ??= '页面加载失败\n$e';
          _loading = false;
          _resolving = false;
        });
        _resolveTimer?.cancel();
        _videoPollTimer?.cancel();
      }));
      _desktopSubs.add(wv.loadingState.listen((loading) {
        if (!mounted) return;
        setState(() {
          _loading = loading;
          if (loading) {
            _webError = null;
          } else {
            _triggerAutoPlay();
          }
        });
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
        }
      });
    } catch (e) {
      debugPrint('WebView2 init failed: $e');
      if (!mounted) return;
      setState(() {
        _webError = '网页播放器初始化失败\n$e\n请检查系统是否安装了 WebView2 运行时';
        _webviewInit = false;
        _desktopInitFailed = true;
      });
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
          setState(() {
            _loading = true;
            _webError = null;
          });
          _injectApiInterceptor();
        },
        onPageFinished: (_) {
          setState(() => _loading = false);
          _triggerAutoPlay();
        },
        onWebResourceError: (err) {
          // 仅主框架加载失败（断网/超时/服务器错误）时展示错误态，
          // 子资源（图片/接口）失败不影响播放，避免误报。
          if (err.isForMainFrame != true || !mounted) return;
          final desc = err.description.trim();
          setState(() {
            _webError ??=
                '页面加载失败${desc.isNotEmpty ? '\n$desc' : ''}';
            // 主框架失败时停止隐藏覆盖层，避免卡在黑屏
            _resolving = false;
          });
          _resolveTimer?.cancel();
          _videoPollTimer?.cancel();
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
      }
    });
  }

  /// WebView 内 video 直链被捕获时，切到 mpv 原生播放器
  /// （Anime4K 超分 + 硬解），仅在拿到真实 m3u8/mp4 直链时生效。
  Future<void> _onVideoSrcCaptured(String src) async {
    if (src.isEmpty || !isDirectMediaUrl(src)) return;
    // Anime1 的 CDN 直链（.v.anime1.me）需携带签名 Cookie(h/p/e) 才能访问，
    // 原生播放器无法携带 Cookie，保留 WebView 由站点播放器播放（同域自动带）。
    if (widget.sourceId == 'anime1' && src.contains('anime1.me')) return;
    if (src == _hookedVideoUrl) return;
    _hookedVideoUrl = src;
    if (!mounted) return;
    // 取消解析定时器，防止 pushReplacement 后定时器触发 setState
    _resolveTimer?.cancel();
    _videoPollTimer?.cancel();
    // 用 pushReplacement 替换当前网页播放器，避免栈里叠两层播放器：
    // 选集页 → 网页播放器 → 原生播放器。返回时直接回到选集页。
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => NativePlayerPage(
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
            ? '${widget.sourceId}::$widget.videoId::$_curSeason-$_curEpisode'
            : '${widget.title}::${_curSeason}_$_curEpisode',
      ),
    ));
  }

  /// 监听 WebView 内 HTML5 video 的真实直链（m3u8/mp4/flv）。
  ///
  /// AGE 类站点把真实直链用 WASM 在网页内解密后交给 <video> 播放，
  /// 这里轮询捕获解密后的 src，交由 mpv（NativePlayer + Anime4K 超分）
  /// 接管播放，以获得原生硬解 + CNN 超分画质。
  String _hookedVideoUrl = '';
  Timer? _videoPollTimer;

  /// AGE 类（WASM 解密）Hls.loadSource 拦截：解密后的真实 m3u8
  /// 写入 window._resolvedVideoUrl，由轮询捕获后交原生播放器。
  static const String _hlsHookJs = '''
    (function(){
      var tryHook = function(){
        if (window.Hls && !window._hlsHooked) {
          var _proto = window.Hls.prototype;
          if (_proto && _proto.loadSource) {
            window._hlsHooked = true;
            var _ls = _proto.loadSource;
            _proto.loadSource = function(url){
              try {
                if (url && url.indexOf('http') === 0 &&
                    url.indexOf('blob:') !== 0) {
                  window._resolvedVideoUrl = url;
                }
              } catch(e){}
              return _ls.apply(this, arguments);
            };
          }
        }
      };
      tryHook();
      var t = setInterval(function(){
        tryHook();
        if (window._hlsHooked) clearInterval(t);
      }, 500);
      setTimeout(function(){ clearInterval(t); }, 30000);
    })();
  ''';

  /// 轮询捕获脚本：优先取拦截到的直链，其次扫描 DOM 里的 <video>。
  static const String _videoPollJs = '''
    (function(){
      var _hooked = window._resolvedVideoUrl || '';
      if (_hooked.indexOf('blob:') !== 0 && _hooked.indexOf('http') === 0) {
        return _hooked;
      }
      var find = function(doc){
        var v = doc.querySelector('video');
        if(v){
          var s = v.currentSrc || v.src || '';
          if(s.indexOf('blob:') === 0) return '';
          if(s) return s;
          var src = v.querySelector('source');
          if(src && src.src) return src.src;
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

  void _hookVideoSource() {
    _videoPollTimer?.cancel();
    _videoPollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) async {
      if (!mounted) return;
      String? src;
      try {
        final r = await _evalJs(_videoPollJs);
        if (r != null && r.isNotEmpty) {
          final decoded = r.startsWith('"') && r.endsWith('"')
              ? (r.substring(1, r.length - 1))
              : r;
          if (decoded.isNotEmpty) src = decoded;
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

  @override
  void dispose() {
    _videoPollTimer?.cancel();
    _resolveTimer?.cancel();
    for (final s in _desktopSubs) {
      s.cancel();
    }
    _desktopSubs.clear();
    _desktop?.dispose();
    _desktop = null;
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _unlockOrientation();
    super.dispose();
  }

  /// resolve-play-url API 拦截脚本（fetch + XHR 双拦截）。
  /// 幂等：重复执行自动跳过（window._videoUrlIntercepted 标记）。
  static const String _apiInterceptorJs = '''
    (function() {
      if (window._videoUrlIntercepted) return;
      window._videoUrlIntercepted = true;
      window._resolvedVideoUrl = '';

      // 拦截 fetch 请求中匹配 resolve-play-url 的 API
      var origFetch = window.fetch;
      window.fetch = function(url, opts) {
        return origFetch.apply(this, arguments).then(function(response) {
          var urlStr = (typeof url === 'string') ? url : (url ? url.url || '' : '');
          if (urlStr.indexOf('/api/videos/resolve-play-url') >= 0) {
            response.clone().json().then(function(data) {
              if (data && data.data && data.data.url) {
                window._resolvedVideoUrl = data.data.url;
              }
            }).catch(function(){});
          }
          return response;
        });
      };

      // 拦截 XMLHttpRequest 中匹配 resolve-play-url 的 API
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        this._requestUrl = url;
        return origOpen.apply(this, arguments);
      };
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function() {
        if (this._requestUrl && typeof this._requestUrl === 'string' &&
            this._requestUrl.indexOf('/api/videos/resolve-play-url') >= 0) {
          this.addEventListener('load', function() {
            try {
              var data = JSON.parse(this.responseText);
              if (data && data.data && data.data.url) {
                window._resolvedVideoUrl = data.data.url;
              }
            } catch(e) {}
          });
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

  void _triggerAutoPlay() async {
    if (_played) return;
    _played = true;
    await Future.delayed(const Duration(seconds: 2));
    await _applyWebViewSR();
    await _runJs('''
      (function(){
        var v = document.querySelector('video');
        if(v){ v.muted=false; v.play().catch(function(){}); return 'video'; }
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
    final idx =
        eps.indexWhere((e) => e.season == _curSeason && e.episode == _curEpisode);
    final target = (idx < 0 ? 0 : idx) + delta;
    if (target < 0 || target >= eps.length) return;
    final ep = eps[target];
    _switchToEpisode(ep.season, ep.episode);
  }

  /// 真正切集：更新当前集状态，并让 WebView 重新加载新一集的播放页。
  Future<void> _switchToEpisode(int season, int episode) async {
    if (!_webviewInit) return;
    final resolver = widget.resolveUrl;
    if (resolver == null) return;
    if (!mounted) return;
    setState(() {
      _curSeason = season;
      _curEpisode = episode;
      _loading = true;
    });
    try {
      final url = await resolver(season, episode);
      if (!mounted) return;
      final d = _desktop;
      if (d != null) {
        await d.loadUrl(url);
      } else {
        await _controller.loadRequest(Uri.parse(url),
            headers: _hostHeader(url));
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
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
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => NativePlayerPage(
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
          ),
        ));
      } else {
        setState(() {
          _curSeason = season;
          _curEpisode = episode;
        });
        await _launchExternal(url);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('切换失败：$e')),
        );
      }
    }
  }

  Future<void> _openInBrowser() => _launchExternal(widget.url);

  Future<void> _launchExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!await canLaunchUrl(uri)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法打开系统浏览器')),
          );
        }
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开浏览器失败：$e')),
        );
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
    final d = _desktop;
    return Stack(children: [
      d != null ? d.buildView() : WebViewWidget(controller: _controller),
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
                  onPressed: _reloadWebView,
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
    ]);
  }

  /// 错误态重试：重置解析状态、重启直链捕获，重新加载当前播放页。
  void _reloadWebView() {
    setState(() {
      _webError = null;
      _loading = true;
      _resolving = true;
    });
    _resolveTimer?.cancel();
    _resolveTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _resolving) {
        setState(() => _resolving = false);
      }
    });
    _hookVideoSource();
    _injectApiInterceptor();
    final d = _desktop;
    if (d != null) {
      d.reload();
    } else {
      _controller.reload();
    }
  }

  /// 统一全屏入口：无论用户点击页面内任何位置进入全屏，
  /// 都转成 app 级横屏全屏（而非 WebView 自带的竖屏全屏），
  /// 退出时恢复竖屏，避免整个软件卡在横屏。
  void _enterFullscreen() {
    if (_fullscreen) return;
    setState(() => _fullscreen = true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  void _exitFullscreen() {
    if (!_fullscreen) return;
    setState(() => _fullscreen = false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _unlockOrientation();
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
              Text('共 ${eps.length} 集',
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
    return InkWell(
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
              _barBtn(Icons.skip_previous_rounded,
                  _hasPrev ? () => _goToAdjacent(-1) : null),
              _barBtn(Icons.skip_next_rounded,
                  _hasNext ? () => _goToAdjacent(1) : null),
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
    return idx > 0;
  }

  bool get _hasNext {
    final eps = widget.episodes;
    if (eps.isEmpty) return false;
    final idx =
        eps.indexWhere((e) => e.season == _curSeason && e.episode == _curEpisode);
    return idx >= 0 && idx < eps.length - 1;
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
                '提示：网页端仅为 CSS 滤镜增强，并非真实超分辨率；跨域播放器内的视频可能无法生效。',
                style: TextStyle(
                  fontSize: 12,
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
      title: '选集（共 ${flat.length} 集）',
      fromRight: _fullscreen,
      width: 360,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
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

}

/// 判断 URL 是否为可以直接播放的视频媒体直链。
///
/// 支持常见的视频扩展名、HLS 路径，以及已知视频 CDN 域名（如 toutiao50.com）。
/// 从 resolve-play-url 等 API 拦截到的 URL 也会被放行（由调用方保证来源可靠）。
bool isDirectMediaUrl(String url) {
  if (url.isEmpty) return false;
  final u = url.toLowerCase();
  // 视频文件扩展名
  if (u.contains('.m3u8') || u.contains('.mp4') ||
      u.contains('.webm') || u.contains('.mkv') || u.contains('.flv')) {
    return true;
  }
  // HLS / TS 流路径
  if (u.contains('/hls/') || u.contains('.ts')) {
    return true;
  }
  // 字节跳动 TOS 对象存储视频路径（AGE 等源换域名但路径固定）
  if (u.contains('/video/tos/')) {
    return true;
  }
  // 已知视频 CDN 域名（头条/抖音/topbuzz/capcut/剪映等字节系）
  if (u.contains('toutiao50.com') || u.contains('toutiao') ||
      u.contains('pstatp.com') || u.contains('bytedance') ||
      u.contains('douyin') || u.contains('ixigua.com') ||
      u.contains('snssdk.com') || u.contains('topbuzzcdn.com') ||
      u.contains('topbuzz.com') || u.contains('capcutvod.com') ||
      u.contains('capcut.com')) {
    return true;
  }
  // blob URL（WASM 解密的 MSE 流）
  if (u.startsWith('blob:')) return true;
  return false;
}

/// B站风格视频详情页：大封面 + 元信息 + 选集网格。
class EpisodeListPage extends StatefulWidget {
  final VideoSource source;
  final VideoDetail detail;
  const EpisodeListPage({super.key, required this.source, required this.detail});

  @override
  State<EpisodeListPage> createState() => _EpisodeListPageState();
}

class _EpisodeListPageState extends State<EpisodeListPage> {
  String? _openingMsg;
  int? _openingIndex;
  bool _expanded = false;
  int _curSeason = 0;
  int _curEpisode = 0;
  List<VideoRecord> _videoRecords = [];
  final Map<int, int> _linePages = {};
  static const int _epsPerPage = 12;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final records = await LocalStore.videoRecords();
    if (!mounted) return;
    final match = records
        .where((r) =>
            r.sourceId == widget.source.id &&
            r.videoId == widget.detail.video.id)
        .toList();
    setState(() => _videoRecords = match);
  }

  /// 给播放器内部切集用：解析任意一集的播放地址。
  Future<String> _resolveEpisodeUrl(int season, int episode) =>
      widget.source.playUrl(widget.detail.video.id, season, episode);

  Future<void> _play(int season, int episode, int idx) async {
    setState(() {
      _curSeason = season;
      _curEpisode = episode;
    });
    setState(() {
      _openingMsg = '加载中…';
      _openingIndex = idx;
    });
    try {
      final url = await widget.source.playUrl(
          widget.detail.video.id, season, episode);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => isDirectMediaUrl(url)
              ? NativePlayerPage(
                  url: url,
                  title: widget.detail.video.name,
                  cover: widget.detail.cover,
                  episodes: widget.detail.episodes,
                  season: season,
                  episode: episode,
                  resolveUrl: _resolveEpisodeUrl,
                  sourceNames: widget.detail.sourceNames,
                  sourceId: widget.source.id,
                  videoId: widget.detail.video.id,
                  historyKey:
                      '${widget.source.id}::${widget.detail.video.id}::$season-$episode',
                )
              : AnimePlayerPage(
                  url: url,
                  title: widget.detail.video.name,
                  cover: widget.detail.cover,
                  description: widget.detail.description,
                  episodes: widget.detail.episodes,
                  initialSeason: season,
                  initialEpisode: episode,
                  resolveUrl: _resolveEpisodeUrl,
                  sourceNames: widget.detail.sourceNames,
                  sourceId: widget.source.id,
                  videoId: widget.detail.video.id,
                ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _openingMsg = null;
          _openingIndex = null;
        });
      }
    }
  }

  /// 计算立即播放应跳转的集：优先用户手动选中 → 历史记录 → 第一集。
  (int, int, int) _playTarget() {
    final flat = widget.detail.episodes;
    if (flat.isEmpty) return (0, 0, 0);
    final sel = flat.indexWhere(
        (e) => e.season == _curSeason && e.episode == _curEpisode);
    if (sel >= 0) return (_curSeason, _curEpisode, sel);
    if (_videoRecords.isNotEmpty) {
      final r = _videoRecords.first;
      final hi = flat.indexWhere(
          (e) => e.season == r.season && e.episode == r.episode);
      if (hi >= 0) return (r.season, r.episode, hi);
    }
    return (flat.first.season, flat.first.episode, 0);
  }

  /// 立即播放按钮文案，体现与当前选中/历史集数的联动关系。
  String _playLabel() {
    final flat = widget.detail.episodes;
    if (flat.isEmpty) return '立即播放';
    final sel = flat.indexWhere(
        (e) => e.season == _curSeason && e.episode == _curEpisode);
    if (sel >= 0) {
      final t = flat[sel].title;
      return t.isEmpty ? '播放 第$_curEpisode集' : '播放 $t';
    }
    if (_videoRecords.isNotEmpty) {
      final r = _videoRecords.first;
      return '继续观看 第${r.episode}集';
    }
    return '立即播放';
  }

  /// 封面加载失败/无封面时的兜底：使用本地占位封面图 + 柔和品牌色叠加，
  /// 避免"空蓝块"的空洞感（贴合"放封面"的预期）。
  Widget _coverFallback(ThemeData theme) {
    return Stack(fit: StackFit.expand, children: [
      Image.asset('assets/placeholder_cover.webp',
          fit: BoxFit.cover, gaplessPlayback: true),
      Container(
          color: theme.colorScheme.primary.withValues(alpha: 0.18)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = widget.detail;
    if (Responsive.isTablet(context)) {
      return _buildTablet(theme, d);
    }
    return _buildPhone(theme, d);
  }

  Widget _buildTablet(ThemeData theme, VideoDetail d) {
    final topPad = MediaQuery.of(context).padding.top;
    final pad = Responsive.pagePadding(context);
    
    // 桌面端使用更大的左侧面板
    final leftPanelWidth = Responsive.isLarge(context)
        ? kPanelWidth + 80
        : _leftPanelWidth;
    
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 左侧：封面 + 信息（固定宽度） ──────────────────
          Container(
            width: leftPanelWidth,
            padding: EdgeInsets.fromLTRB(pad, topPad + 10, 8, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _BackButton(),
                const SizedBox(height: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: double.infinity,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: (d.cover == null || d.cover!.isEmpty)
                          ? _coverFallback(theme)
                          : Image.network(d.cover!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _coverFallback(theme)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(d.video.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface)),
                const SizedBox(height: 6),
                Text(
                  [
                    if (d.area != null) d.area!,
                    if (d.lang != null) d.lang!,
                    if (d.year != null) d.year!,
                    if (d.type != null) d.type!,
                    if (d.video.score != null &&
                        d.video.score!.isNotEmpty &&
                        d.video.score != '0')
                      '评分 ${d.video.score}',
                    if (d.video.remarks != null &&
                        d.video.remarks!.isNotEmpty)
                      d.video.remarks!,
                    if (d.episodes.isNotEmpty) '共 ${d.episodes.length} 集',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                if (d.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in d.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(alpha: 0.25),
                              width: 0.6,
                            ),
                          ),
                          child: Text(t,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: theme.colorScheme.primary)),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: d.episodes.isEmpty
                      ? null
                      : () {
                          final t = _playTarget();
                          _play(t.$1, t.$2, t.$3);
                        },
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(_playLabel()),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
          // ── 右侧：剧集列表（可滚动） ─────────────────────
          Expanded(
            child: _episodePanel(theme, d),
          ),
        ],
      ),
    );
  }

  static const double _leftPanelWidth = kPanelWidth;

  Widget _episodePanel(ThemeData theme, VideoDetail d) {
    return CustomScrollView(slivers: [
      if (d.description != null && d.description!.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.description!,
                      maxLines: _expanded ? null : 4,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          _expanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: SectionHeader(
            icon: Icons.playlist_play_rounded,
            title: '全集',
            count: d.episodes.length,
            trailing: _videoRecords.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      final r = _videoRecords.first;
                      final flat = d.episodes;
                      final hi = flat.indexWhere(
                          (e) => e.season == r.season && e.episode == r.episode);
                      if (hi >= 0) _play(r.season, r.episode, hi);
                    },
                    child: Row(children: [
                      Icon(Icons.history_rounded,
                          size: 15, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text('上次：第${_videoRecords.first.episode}集',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600)),
                    ]),
                  )
                : null,
          ),
        ),
      ),
      ..._buildEpisodeSlivers(theme, d),
    ]);
  }

  Widget _buildPhone(ThemeData theme, VideoDetail d) {
    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: 260,
          pinned: true,
          backgroundColor: theme.colorScheme.surface,
          foregroundColor: theme.colorScheme.onSurface,
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(fit: StackFit.expand, children: [
              if (d.cover != null && d.cover!.isNotEmpty)
                Image.network(d.cover!,
                    fit: BoxFit.cover,
                    cacheWidth:
                        (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).toInt(),
                    errorBuilder: (_, __, ___) => _coverFallback(theme),
                  )
              else
                _coverFallback(theme),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.88),
                    ],
                  ),
                ),
              ),
              // 角落标签
              if (d.type != null || d.video.remarks != null)
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (d.type != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 0.5),
                          ),
                          child: Text(d.type!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                      if (d.type != null && d.video.remarks != null) const SizedBox(width: 6),
                      if (d.video.remarks != null)
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(d.video.remarks!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                          ),
                        ),
                    ],
                  ),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      d.video.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (d.area != null) d.area!,
                        if (d.lang != null) d.lang!,
                        if (d.year != null) d.year!,
                        if (d.type != null) d.type!,
                        if (d.video.score != null &&
                            d.video.score!.isNotEmpty &&
                            d.video.score != '0')
                          '评分 ${d.video.score}',
                        if (d.video.remarks != null &&
                            d.video.remarks!.isNotEmpty)
                          d.video.remarks!,
                        if (d.episodes.isNotEmpty) '共 ${d.episodes.length} 集',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    if (d.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in d.tags)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white
                                      .withValues(alpha: 0.22),
                                  width: 0.6,
                                ),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white
                                      .withValues(alpha: 0.92),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
        // 立即播放主按钮
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.icon(
              onPressed: d.episodes.isEmpty
                  ? null
                  : () {
                      final t = _playTarget();
                      _play(t.$1, t.$2, t.$3);
                    },
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(_playLabel()),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        if (d.description != null && d.description!.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.description!,
                        maxLines: _expanded ? null : 4,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            _expanded ? '收起' : '展开',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            _expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: SectionHeader(
              icon: Icons.playlist_play_rounded,
              title: '全集',
              count: d.episodes.length,
              trailing: _videoRecords.isNotEmpty
                  ? GestureDetector(
                      onTap: () {
                        final r = _videoRecords.first;
                        final flat = d.episodes;
                        final hi = flat.indexWhere(
                            (e) => e.season == r.season && e.episode == r.episode);
                        if (hi >= 0) _play(r.season, r.episode, hi);
                      },
                      child: Row(children: [
                        Icon(Icons.history_rounded,
                            size: 15, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('上次：第${_videoRecords.first.episode}集',
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600)),
                      ]),
                    )
                  : null,
            ),
          ),
        ),
        ..._buildEpisodeSlivers(theme, d),
      ]),
    );
  }

  /// 选集按播放源（season）分组渲染：每组一个源名 + 集数头，下面是该源的剧集网格。
  /// 仅当存在多个源时才显示分组头，单源时退化为原来的扁平网格。
  List<Widget> _buildEpisodeSlivers(ThemeData theme, VideoDetail d) {
    final scheme = theme.colorScheme;
    final flat = d.episodes;
    final bySeason = <int, List<VideoEpisode>>{};
    for (final e in flat) {
      (bySeason[e.season] ??= []).add(e);
    }
    final keys = bySeason.keys.toList()..sort();
    final groups = [
      for (final k in keys)
        (
          season: k,
          name: widget.detail.sourceNames?[k] ?? '线路 $k',
          eps: bySeason[k]!,
        ),
    ];
    final multi = groups.length > 1;
    final out = <Widget>[];
    for (final g in groups) {
      final total = g.eps.length;
      final pageCount = (total + _epsPerPage - 1) ~/ _epsPerPage;
      final rawPage = _linePages[g.season] ?? 0;
      final page = rawPage < 0 ? 0 : (rawPage >= pageCount ? pageCount - 1 : rawPage);
      final start = page * _epsPerPage;
      final end = start + _epsPerPage < total ? start + _epsPerPage : total;
      final pageEps = g.eps.sublist(start, end);
      // 线路头：主色竖条 + 名称 + 本线路总集数
      out.add(SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, multi ? 18 : 6, 20, 10),
          child: Row(children: [
            Container(
              width: 4,
              height: 16,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(g.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
            ),
            Text('本线路共 $total 集',
                style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurface.withValues(alpha: 0.5))),
          ]),
        ),
      ));
      // 关键性能修复：用懒加载 SliverGrid 替代 shrinkWrap GridView，
      // 避免整组卡片全量构建导致滚动卡顿。
      out.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: Responsive.episodeGridColumns(context),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.55,
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final ep = pageEps[i];
              final flatIdx = flat.indexOf(ep);
              final isOpening = _openingIndex == flatIdx;
              final isCurrent =
                  ep.season == _curSeason && ep.episode == _curEpisode;
              final isHistory = _videoRecords.isNotEmpty &&
                  _videoRecords.first.season == ep.season &&
                  _videoRecords.first.episode == ep.episode &&
                  !isCurrent;
              final showTitle =
                  ep.title.isNotEmpty && !ep.title.startsWith('第');
              return Material(
                color: isOpening
                    ? scheme.primary
                    : isCurrent
                        ? scheme.primary.withValues(alpha: 0.16)
                        : scheme.surfaceContainerHighest
                            .withValues(alpha: 0.55),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isCurrent ? scheme.primary : Colors.transparent,
                    width: 1.2,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _openingMsg == null
                      ? () => _play(ep.season, ep.episode, flatIdx)
                      : null,
                  child: Stack(children: [
                    Center(
                      child: isOpening
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '第${ep.episode}集',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isCurrent
                                          ? FontWeight.w800
                                          : FontWeight.w700,
                                      color: isCurrent
                                          ? scheme.primary
                                          : scheme.onSurface,
                                    ),
                                  ),
                                  if (showTitle) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      ep.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: isCurrent
                                            ? scheme.primary
                                                .withValues(alpha: 0.8)
                                            : scheme.onSurface
                                                .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                    ),
                    if (isHistory)
                      Positioned(
                        top: 5,
                        right: 5,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: scheme.primary
                                    .withValues(alpha: 0.4),
                                blurRadius: 3,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ]),
                ),
              );
            },
            childCount: pageEps.length,
          ),
        ),
      ));
      // 分页控件
      if (pageCount > 1) {
        out.add(SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _pageBtn(
                    theme,
                    Icons.chevron_left_rounded,
                    page > 0
                        ? () =>
                            setState(() => _linePages[g.season] = page - 1)
                        : null),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text('${page + 1} / $pageCount',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface.withValues(alpha: 0.6))),
                ),
                _pageBtn(
                    theme,
                    Icons.chevron_right_rounded,
                    page < pageCount - 1
                        ? () =>
                            setState(() => _linePages[g.season] = page + 1)
                        : null),
              ],
            ),
          ),
        ));
      }
    }
    out.add(const SliverToBoxAdapter(child: SizedBox(height: 70)));
    return out;
  }

  Widget _pageBtn(ThemeData theme, IconData icon, VoidCallback? onTap) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: disabled
              ? Colors.transparent
              : theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon,
            size: 20,
            color: disabled
                ? theme.colorScheme.onSurface.withValues(alpha: 0.25)
                : theme.colorScheme.onSurface),
      ),
    );
  }
}

/// 平板分栏左上角返回按钮。
class _BackButton extends StatelessWidget {
  const _BackButton();
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.maybePop(context),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.arrow_back_rounded,
            color: Colors.white, size: 20),
      ),
    );
  }
}