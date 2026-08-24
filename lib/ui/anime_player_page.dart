import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../sources/video_source.dart';
import 'native_player_page.dart';
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
  bool _loading = true;
  bool _muted = false;
  bool _fullscreen = false;
  int _curSeason = 1;
  int _curEpisode = 1;
  double _speed = 1.0;
  bool _descExpanded = false;

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

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(ua)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          setState(() => _loading = true);
          _injectApiInterceptor();
        },
        onPageFinished: (_) {
          setState(() => _loading = false);
          _triggerAutoPlay();
        },
      ))
      ..loadRequest(Uri.parse(widget.url), headers: _hostHeader(widget.url));
    _enableWebViewMediaPlayback();
    _hookVideoSource();
  }

  /// WebView 内 video 直链被捕获时，切到 mpv 原生播放器
  /// （Anime4K 超分 + 硬解），仅在拿到真实 m3u8/mp4 直链时生效。
  Future<void> _onVideoSrcCaptured(String src) async {
    if (src.isEmpty || !isDirectMediaUrl(src)) return;
    if (src == _hookedVideoUrl) return;
    _hookedVideoUrl = src;
    if (!mounted) return;
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

  void _hookVideoSource() {
    _videoPollTimer?.cancel();
    _videoPollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) async {
      if (!mounted) return;
      String? src;
      try {
        final r = await _controller.runJavaScriptReturningResult('''
          (function(){
            // ---- AGE 类（WASM 解密）拦截：覆写 Hls.prototype.loadSource ----
            // jx 播放器在 WASM 解密出真实 m3u8 后调用 new Hls().loadSource(url)，
            // 这里把解密后的真实直链截获到 window._resolvedVideoUrl（幂等注册）。
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

            // 优先检查 API / Hls 拦截到的视频直链
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
                // 检查 <source> 子元素
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
        ''');
        final js = r as String?;
        if (js != null && js.isNotEmpty) {
          final decoded = js.startsWith('"') && js.endsWith('"')
              ? (js.substring(1, js.length - 1))
              : js;
          if (decoded.isNotEmpty) src = decoded;
        }
      } catch (_) {}
      if (src != null) await _onVideoSrcCaptured(src);
    });
  }

  @override
  void dispose() {
    _videoPollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// 在 WebView 页面加载前注入 JavaScript，拦截 resolve-play-url API 请求。
  ///
  /// 部分视频源（如 TvTFun）的播放页通过调用 `/api/videos/resolve-play-url?episodeId=xxx`
  /// 获取视频直链，然后交给 ArtPlayer 播放。该 API 返回的 URL 是 m3u8/mp4 直链，
  /// 捕获后可直接交给 NativePlayer（media_kit）原生播放，无需 WebView 中转。
  Future<void> _injectApiInterceptor() async {
    try {
      await _controller.runJavaScript('''
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
      ''');
    } catch (_) {}
  }

  void _enableWebViewMediaPlayback() {
    try {
      final and = _controller.platform as AndroidWebViewController;
      // 自动播放声音/视频，不需要用户手势
      and.setMediaPlaybackRequiresUserGesture(false);
    } catch (_) {}
    // 拦截网页内部 video 全屏请求，转发给 app 级横屏全屏，
    // 避免出现"网页内竖屏全屏"与 app 全屏互相冲突。
    _controller.runJavaScript('''
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
    try {
      await _controller.runJavaScript('''
        (function(){
          var v = document.querySelector('video');
          if(v){ v.muted=false; v.play().catch(function(){}); return 'video'; }
          var b = document.querySelector('.artplayer-app video,.art-video video,[class*="play"],[id*="play"],.play-btn,button');
          if(b){ b.click(); return 'click'; }
          return 'none';
        })();
      ''');
    } catch (_) {}
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
    try {
      await _controller.runJavaScript('''
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
    } catch (_) {}
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _controller.runJavaScript('''
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
      await _controller.loadRequest(Uri.parse(url), headers: _hostHeader(url));
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _fullscreen ? _fullBody() : _normalBody(),
    );
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
    return Column(children: [
      AspectRatio(aspectRatio: 16 / 9, child: _webView()),
      Expanded(child: _belowPanel()),
    ]);
  }

  Widget _webView() {
    return Stack(children: [
      WebViewWidget(controller: _controller),
      if (_loading)
        Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          ),
        ),
    ]);
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
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  // ══ 竖屏下方面板（与原生播放器 _belowPanel 对齐） ══════════════
  Widget _belowPanel() {
    final scheme = Theme.of(context).colorScheme;
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
                    Text('网页画质增强(滤镜)',
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
                      child: Text(_srName,
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: on
                                  ? PlayerColors.sr
                                  : scheme.onSurface.withValues(alpha: 0.6))),
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
    _controller.runJavaScript('''
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = widget.detail;
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
                    errorBuilder: (_, __, ___) =>
                        Container(color: theme.colorScheme.primary)),
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
                        if (d.year != null) d.year!,
                        if (d.type != null) d.type!,
                        if (d.episodes.isNotEmpty) '共 ${d.episodes.length} 集',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
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
                  : () => _play(d.episodes.first.season,
                      d.episodes.first.episode, 0),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('立即播放'),
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
            child: Row(children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text('选集',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${d.episodes.length}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ]),
          ),
        ),
        ..._buildEpisodeSlivers(theme, d),
      ]),
    );
  }

  /// 选集按播放源（season）分组渲染：每组一个源名 + 集数头，下面是该源的剧集网格。
  /// 仅当存在多个源时才显示分组头，单源时退化为原来的扁平网格。
  List<Widget> _buildEpisodeSlivers(ThemeData theme, VideoDetail d) {
    final flat = d.episodes;
    final bySeason = <int, List<VideoEpisode>>{};
    for (final e in flat) {
      (bySeason[e.season] ??= []).add(e);
    }
    final keys = bySeason.keys.toList()..sort();
    final groups = [
      for (final k in keys)
        (
          name: widget.detail.sourceNames?[k] ?? '线路 $k',
          eps: bySeason[k]!,
        ),
    ];
    final multi = groups.length > 1;
    final out = <Widget>[];
    for (final g in groups) {
      if (multi) {
        out.add(SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [
              Icon(Icons.playlist_play_rounded,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(g.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface)),
              ),
              Text('${g.eps.length} 集',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.5))),
            ]),
          ),
        ));
      }
      out.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.4,
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final ep = g.eps[i];
              final flatIdx = flat.indexOf(ep);
              final isOpening = _openingIndex == flatIdx;
              final isCurrent =
                  ep.season == _curSeason && ep.episode == _curEpisode;
              return Material(
                color: isOpening
                    ? theme.colorScheme.primary
                    : isCurrent
                        ? theme.colorScheme.primary.withValues(alpha: 0.14)
                        : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _openingMsg == null
                      ? () => _play(ep.season, ep.episode, flatIdx)
                      : null,
                  child: Stack(children: [
                    Positioned(
                      top: 5,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? theme.colorScheme.primary
                              : Colors.black.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${ep.episode}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: isCurrent
                                ? Colors.white
                                : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: isOpening
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : Padding(
                              padding: const EdgeInsets.only(
                                  top: 8, left: 4, right: 4),
                              child: Text(
                                ep.title.isEmpty
                                    ? '第${ep.episode}集'
                                    : ep.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: isCurrent
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  color: isCurrent
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                    ),
                  ]),
                ),
              );
            },
            childCount: g.eps.length,
          ),
        ),
      ));
    }
    out.add(const SliverToBoxAdapter(child: SizedBox(height: 70)));
    return out;
  }
}