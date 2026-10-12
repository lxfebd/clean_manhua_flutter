part of 'reader_page.dart';

class _ImageView extends StatefulWidget {
  final String url;
  final int pageIndex;
  final int totalPages;
  final int resLevel;
  final bool horizontal;
  final String sourceId;
  final bool trimBorder;

  /// 是否启用自动上色（本地 AI）。由外层按真实阅读模式计算：
  /// 纵向滚动模式可用；横向翻页（单页/双页 PageView）禁用避免卡顿。
  final bool colorize;

  /// 图片加载完成后回调实际高度（纵向模式用于精确跳页）。
  final ValueChanged<double?>? onLayout;
  const _ImageView(this.url,
      {required this.pageIndex, required this.totalPages, required this.resLevel,
      this.horizontal = false, this.sourceId = '', this.trimBorder = false,
      this.colorize = false, this.onLayout});

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView>
    with AutomaticKeepAliveClientMixin {
  bool _error = false;
  final GlobalKey _imgKey = GlobalKey();

  /// 图片子树重建序号：失败重试时递增，强制底层组件重建重新加载
  /// （didUpdateWidget 只在 url 等属性变化时重载，重试必须换 key）。
  int _imgGen = 0;

  /// 横向翻页：必须关闭 keepAlive——JM 长条图解码后单张可达数十 MB，
  /// PageView 若把已读页全部保留在 Element 树中，翻十几页就 OOM 闪退。
  /// 关闭后由 PageView 的 cacheExtent 保留前后有限页，翻走即销毁释放。
  /// 纵向滚动：保留 keepAlive 但同样要防止无限累积——ListView 的
  /// keepAlive 页面数受 cacheExtent(900px) 限制，超出即销毁，不会无限累积。
  @override
  bool get wantKeepAlive => !widget.horizontal;

  bool get _isJm => widget.sourceId == 'jm';

  /// 是否启用超分。规则：
  /// - 横向翻页禁用（每页提交到串行 Isolate 队列让低端机卡死，且 contain 视角放大有限）；
  /// - JM 源禁用（图床已压缩，Lanczos-3 放大纯增开销、无观感收益，居中文本/网点反而更糊）。
  bool get _superResEnabled =>
      !widget.horizontal && !_isJm && widget.resLevel >= 2;

  /// 是否启用自动上色。规则：
  /// - 仅桌面端启用（手机端不上色，256×256 本地推理耗时/卡顿不达标）；
  /// - 由外层 _ReaderPageState 按真实阅读模式计算并传入（纵向滚动可用，
  ///   横向翻页禁用）。此处不再使用 widget.horizontal——主页面横向 PageView
  ///   的图片一律 horizontal:true，但 model 推理只限制于横向翻页场景。
  bool get _colorizeEnabled =>
      DesktopUi.isDesktopPlatform &&
      widget.colorize &&
      !_isJm &&
      ColorizerManager.instance.enabled &&
      ColorizerManager.instance.isAvailable;

  FilterQuality _filterLevel() {
    switch (widget.resLevel) {
      case 0:
        return FilterQuality.none;
      case 1:
        return FilterQuality.low;
      case 2:
        return FilterQuality.medium;
      default:
        return FilterQuality.none;
    }
  }

  void _reportLayout() {
    if (widget.horizontal || widget.onLayout == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _imgKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        widget.onLayout!(box.size.height);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _reportLayout();
    // 懒探模型（幂等）：仅桌面端做。手机端不上色（256×256 本地推理耗时/
    // 卡顿不达标），不加载 225MB 模型，避免无谓 IO 与内存占用。
    // 模型加载完成后重建一次，让 colorize: _colorizeEnabled 重新求值——
    // 否则 225MB 模型加载慢于图片时，colorize 快照恒 false，上色永不触发。
    if (DesktopUi.isDesktopPlatform) {
      ColorizerManager.instance.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant _ImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _reportLayout();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error) {
      return SizedBox(
        width: double.infinity,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('图片加载失败', style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () => setState(() {
                  _error = false;
                  _imgGen++; // 换 key 强制重建底层图片组件重新加载
                }),
              ),
            ],
          ),
        ),
      );
    }

    // 失败重试后 _imgGen++：整棵图片子树换 key 重建，强制重新加载
    // （子组件 didUpdateWidget 只在 url 等属性变化时重载，仅复位 _error
    // 不会重新请求图片）。
    final fit = widget.horizontal ? BoxFit.contain : BoxFit.fitWidth;
    Widget img;
    if (widget.url.startsWith('/') && !kIsWeb) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final cw = (MediaQuery.sizeOf(context).width * dpr).toInt();
      img = Image.file(
          File(widget.url),
          key: _imgKey,
          width: double.infinity,
          fit: fit,
          filterQuality: _filterLevel(),
          cacheWidth: cw,
          errorBuilder: (c, e, s) {
            Future.microtask(() {
              if (mounted) setState(() => _error = true);
            });
            return const SizedBox();
          },
        );
    } else if (kIsWeb && widget.url.startsWith('/')) {
      // Web 端无本地文件阅读（下载/本地导入在 web 为禁用态），占位避免崩溃。
      img = SizedBox(
        key: _imgKey,
        width: double.infinity,
        child: Center(
          child: Text(
            'Web 端不支持本地文件阅读',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      );
    } else if (widget.url.contains('@') || _isJm) {
      img = KeyedSubtree(
        key: _imgKey,
        child: JmScrambleImageWidget(
          url: widget.url,
          fit: fit,
          filterQuality: _filterLevel(),
          horizontal: widget.horizontal,
          sourceId: widget.sourceId,
        ),
      );
    } else {
      img = KeyedSubtree(
        key: _imgKey,
        child: _CachedReaderImage(
          url: widget.url,
          fit: fit,
          filterQuality: _filterLevel(),
          sourceId: widget.sourceId,
          superRes: _superResEnabled,
          colorize: _colorizeEnabled,
          horizontal: widget.horizontal,
          trimBorder: widget.trimBorder,
          onError: () {
            Future.microtask(() {
              if (mounted) setState(() => _error = true);
            });
          },
        ),
      );
    }

    // 失败重试后 _imgGen++：换 key 强制重建（见 retry 按钮）。
    img = KeyedSubtree(key: ValueKey<int>(_imgGen), child: img);

    // 横向翻页：用 Expanded 让图片填满整个页面
    if (widget.horizontal) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.totalPages > 1 && widget.pageIndex == 0)
            SizedBox(
              width: double.infinity,
              height: 40,
              child: Center(
                child: Text(
                  '共 ${widget.totalPages} 页',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          Expanded(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                panEnabled: true,
                scaleEnabled: true,
                // 放大后可在页面内平移查看细节；缩放小于 1 无意义（横向本来就是 contain 适配）。
                boundaryMargin: const EdgeInsets.all(80),
                child: img,
              ),
            ),
        ],
      );
    }

    // 纵向滚动：页码提示 + 图片
    // 注意：不能用 Column 包裹 img（Column 会把 img 约束到 intrinsic 尺寸，
    // 导致 图片在高 DPR 屏上显示极小）。页码提示单独渲染后，
    // img 作为 ListView item 直接展开，BoxFit.fitWidth 让宽度撑满、
    // 高度按图片比例自适应。
    if (widget.totalPages > 1 && widget.pageIndex == 0) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: 40,
            child: Center(
              child: Text(
                '共 ${widget.totalPages} 页',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          img,
        ],
      );
    }
    return img;
  }
}

/// 阅读页普通网络图：走 ImageCacheManager（内存+磁盘），带进度与错误回调。
class _CachedReaderImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final String sourceId;
  final bool superRes;
  final bool horizontal;

  /// 自动裁边去白边：开启后加载完成时在 Isolate 里扫描白边并裁剪，
  /// 裁剪结果按独立缓存 key 持久化，二次打开直接命中。
  final bool trimBorder;

  /// 自动上色（本地 AI）：开启后对显示字节做灰度→彩色推理并替换，
  /// 失败/超时降级原图（ColorizerManager.colorize 返回 null）。
  final bool colorize;
  final VoidCallback onError;
  const _CachedReaderImage({
    required this.url,
    required this.fit,
    required this.filterQuality,
    required this.sourceId,
    required this.superRes,
    this.horizontal = false,
    this.trimBorder = false,
    this.colorize = false,
    required this.onError,
  });

  @override
  State<_CachedReaderImage> createState() => _CachedReaderImageState();
}

class _CachedReaderImageState extends State<_CachedReaderImage>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _bytes;
  bool _failed = false;
  bool _colorized = false; // 上色已执行（成功或降级都置位，避免重复推理）
  /// 自动重试次数：单张图最多自动重试 1 次，之后只保留手动点击重试，
  /// 避免对源站反复轰炸（防抖 + 有限次数）。
  int _autoRetries = 0;
  Timer? _retryTimer;

  /// 解码 provider 的记忆化槽（见 build）：按「同一字节对象 + 同一目标尺寸」
  /// 复用同一个实例，避免每次重建都新建 MemoryImage/ResizeImage。
  Uint8List? _providerBytes;
  int _providerW = -1;
  int _providerH = -1;
  ImageProvider<Object>? _provider;

  /// 当前源的 CustomSourceDef 缓存（picHeaders 读图用）。
  CustomSourceDef? _defCache;

  /// 与 _ImageView 一致：横向翻页关闭 keepAlive，翻走即销毁释放内存，
  /// 避免长条图在 PageView 中累积导致 OOM。
  @override
  bool get wantKeepAlive => !widget.horizontal;

  @override
  void initState() {
    super.initState();
    _loadDef();
    _load();
  }

  /// 预载源 def（picHeaders 读图头用），首次失败不阻塞图片加载。
  Future<void> _loadDef() async {
    try {
      final def = await CustomSourceStore.byId(widget.sourceId);
      if (mounted && def != null) setState(() => _defCache = def);
    } catch (_) {/* 忽略：无该源时读图走无头兜底 */}
  }

  @override
  void didUpdateWidget(covariant _CachedReaderImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.superRes != widget.superRes ||
        old.trimBorder != widget.trimBorder ||
        old.colorize != widget.colorize) {
      _load();
    }
  }

  /// 部分图源 CDN 需要 Referer 头才返回图片（如 dm5 的 cdndm5.com 或自定义
  /// DSL 源配置的 picHeaders），否则 403/404 导致「图片加载失败」。
  /// 与 `_prefetch` 保持一致的 headers；源级 picHeaders 优先于内置兜底。
  Map<String, String>? _headers() {
    final def = _defCache;
    if (def != null && def.picHeaders.isNotEmpty) {
      return Map<String, String>.from(def.picHeaders);
    }
    final host = Uri.tryParse(widget.url)?.host ?? '';
    if (host.contains('cdndm5.com')) {
      final cid = Uri.tryParse(widget.url)?.queryParameters['cid'] ?? '';
      return {
        'Referer': cid.isNotEmpty
            ? 'https://m.dm5.com/m$cid/'
            : 'https://m.dm5.com/'
      };
    }
    if (host.contains('doubaomanhua.com') || host.contains('bzcdn')) {
      return {'Referer': 'https://www.doubaomanhua.com/'};
    }
    return null;
  }

  /// 超分缓存主 key：基于归一化主 URL 构造（先剥 @jm: 解扰标记再拼变换标识）。
  /// 不能把 `|{algoVersion}` 直接拼在 widget.url 原文后——当 url 含 `@jm:`
  /// 中缀时，[ImageDeg.normalizeUrl] 会从 `@jm:` 截断，把尾部的 `|algoVersion`
  /// 一并剥掉，坍缩成与普通图完全相同的 md5 槽，超分/原图互相污染缓存。
  /// 这里先取主 URL 再拼尾，保证变换槽 = `主图|算法版本`，与普通图恒隔离。
  String _srKey() =>
      '${ImageDeg.normalizeUrl(widget.url)}|sr|${ImageSuperRes.algoVersion}';

  /// 自动上色：整图字节进 `Isolate.run` 解码/重编码（大图不阻塞 UI），
  /// 推理走 ColorizerManager 的互斥锁 + 超时降级。任何一步失败返回 null，
  /// 调用方保留原图（不打断阅读）。
  Future<Uint8List?> _tryColorize(Uint8List bytes) async {
    try {
      if (!ColorizerManager.instance.isAvailable) return null;
      final out = await ColorizerManager.instance.colorizeJpeg(bytes);
      if (out == null) {
        _colorized = true; // 推理失败/超时降级，同页不重试
        return null;
      }
      _colorized = true; // 成功也置位：同页不重复推理（模型就绪重建时重跑 _load 才能触发上色）
      return out;
    } catch (e) {
      ErrorLogger.instance.warn('Colorizer _tryColorize 异常: $e');
      return null;
    }
  }

  /// 先加载原图快速显示，滑动停止后再异步超分升级。
  /// 避免超分 Isolate 在滑动期间并发导致低端机卡死。
  Future<void> _load() async {
    // 保留已加载图片字节，避免占位高度(240)与实际高度来回跳变造成上翻抖动；
    // 仅在确实没有图片时才触发重建显示占位。
    if (_bytes == null) {
      setState(() => _failed = false);
    } else {
      _failed = false;
    }
    try {
      // 单源代理：阅读器图片与文本同源，走该源的代理配置（无则 null 走全局/直连）。
      // 代理解析整章一致且已由 state 级 future 缓存（_pendingProxy），
      // 不每页重复 await（源配置带 5min TTL，滚动建页时避免逐页查配置）。
      final proxy = await _ReaderPageState.proxyForSource(widget.sourceId);
      // 第一步：先加载原图（快速显示）。走多级降级链：
      // 原画失败自动尝试省空间压缩图（mangadex data-saver）与备用镜像（jm CDN），
      // 任一档位成功即显示；全部失败由 catch 落失败态。
      // 全部失败时 loadDegraded 已抛异常（由下方 catch 落失败态）；
      // 防御未来「直返 failed 不抛」的契约变化：bytes 为空显式抛出，
      // 走同一条失败/重试分支，不让 `!` 在 .then 里抛 TypeError。
      final r = await ImageCacheManager.loadDegraded(widget.url,
          headers: _headers(),
          proxy: proxy,
          engineId: widget.sourceId,
          useSaver: widget.sourceId == 'mangadex');
      if (!mounted) return;
      if (r.bytes == null) {
        throw Exception('图片降级链全部失败');
      }
      final raw = r.bytes!;
      if (!mounted) return;

      // 自动裁边去白边：裁边结果按独立缓存 key 持久化，
      // 只计算一次，二次打开直接命中磁盘缓存（与原图缓存同机制）。
      Uint8List display = raw;
      if (widget.trimBorder) {
        // 裁边 key 同样基于主 URL（见 _srKey 注释：不做就与普通图槽污染）
        final trimKey =
            '${ImageDeg.normalizeUrl(widget.url)}|trim|${ImageTrim.algoVersion}';
        display = await ImageCacheManager.load(trimKey,
            headers: _headers(),
            fetch: () async => trimAndCrop(raw),
            proxy: proxy);
        if (!mounted) return;
      }
      setState(() => _bytes = display);

      // 第二步：等滑动停止后做超分（防止滑动期间 Isolate 并发卡死）。
      // 上色与超分彼此独立：超分不开也能上色，上色失败降级原图不打断阅读。
      if (widget.superRes) {
        await _waitForScrollEnd();
        if (!mounted) return;

        // 超分缓存命中则秒换；未命中则排队做 Lanczos-3（全局互斥锁串行化）。
        // 开启裁边时超分作用在裁边结果上，缓存 key 也要带上裁边标识避免串缓存。
        final srKey = widget.trimBorder
            ? '${_srKey()}|trim|${ImageTrim.algoVersion}'
            : _srKey();
        final sr = await ImageCacheManager.load(srKey,
            headers: _headers(),
            fetch: () async => await ImageSuperRes.upscale2x(display),
            proxy: proxy);
        if (mounted) {
          setState(() {
            _bytes = sr;
          });
        }
      }

      // 自动上色：对最终显示字节做本地 AI 推理（失败降级原图，不打断阅读）。
      // 仅在未触发上色时执行一次，避免每次重建重复推理。
      if (widget.colorize && !_colorized) {
        final colored = await _tryColorize(_bytes ?? display);
        if (mounted && colored != null) {
          setState(() => _bytes = colored);
        }
      }
    } catch (e) {
      ErrorLogger.instance.warn('image load failed url=${widget.url} err=$e');
      if (mounted) {
        setState(() => _failed = true);
        widget.onError();
        // 单张图失败自动重试 1 次（延迟 1.5s），降低偶发网络抖动对阅读流
        // 的打断；仍失败则留在占位态，等待手动点击。
        if (_autoRetries < 1 && _retryTimer == null) {
          _autoRetries++;
          _retryTimer = Timer(const Duration(milliseconds: 1500), () {
            _retryTimer = null;
            if (mounted) _load();
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  /// 等待滑动停止（事件驱动，非轮询）。滑动中不启动超分。
  /// 使用 Completer：滑动停止时 notification 触发 complete，等待方立即恢复。
  Future<void> _waitForScrollEnd() async {
    final c = _ReaderPageState._currentScrollCompleter;
    if (c == null || c.isCompleted) return;
    await c.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_failed) {
      return SizedBox(
        width: double.infinity,
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset('assets/placeholder_cover.webp',
                fit: BoxFit.cover, gaplessPlayback: true),
            Center(
              child: GestureDetector(
                onTap: _load,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.refresh_rounded,
                      color: Colors.white70, size: 26),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(
        width: double.infinity,
        height: 240,
        child: Image.asset('assets/placeholder_cover.webp',
            fit: BoxFit.cover),
      );
    }
    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio;
    final cw = (mq.size.width * dpr).toInt();
    final ch = (mq.size.height * dpr).toInt();
    // provider 记忆化：阅读器任何一次 setState（翻页 / overlay / 放大镜 /
    // 键盘缩放 / 超分回填）都会重建所有已挂载页，此前每次都新建
    // MemoryImage + ResizeImage，Image.didUpdateWidget 见 provider 实例不同
    // 就重新 resolve —— MB 级章节图被反复重新解析。
    if (!identical(_providerBytes, bytes) ||
        _providerW != cw ||
        _providerH != ch) {
      _providerBytes = bytes;
      _providerW = cw;
      _providerH = ch;
      _provider = readerImageProvider(bytes,
          horizontal: widget.horizontal, width: cw, height: ch);
    }
    return Image(
      image: _provider!,
      width: double.infinity,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
      gaplessPlayback: true,
    );
  }
}

/// 阅读器图片的解码降采样 provider（单一入口）。
///
/// 只允许有一层 ResizeImage。`Image.memory(bytes, cacheWidth: n)` 会自动把
/// provider 包成 ResizeImage；若再取它的 `.image` 套一层 ResizeImage（纵向条漫
/// 曾这么写），Flutter 在**解码时**断言
///   "ResizeImage cannot be composed with another ImageProvider that applies
///    getTargetSize"
/// ——纵向每一张图都抛异常，整页变成红字错误墙，阅读器完全不可用。
///
/// 纵向按屏高等比限位：条漫原图常几千 px 高，全高解码徒耗内存与 UI 线程解码
/// 时间，滚动滑入即卡。`fit` 策略等比限制，不会像 `exact` 那样按两轴独立拉伸
/// 把图压变形。
@visibleForTesting
ImageProvider<Object> readerImageProvider(
  Uint8List bytes, {
  required bool horizontal,
  required int width,
  required int height,
}) {
  final provider = MemoryImage(bytes);
  return horizontal
      ? ResizeImage(provider, width: width, policy: ResizeImagePolicy.fit)
      : ResizeImage(
          provider, width: width, height: height, policy: ResizeImagePolicy.fit);
}

/// 顶部工具栏：返回 / 章节名 / 菜单（对齐 S5）。
class _ReaderTopBar extends StatelessWidget {
  final bool visible;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onMenu;
  const _ReaderTopBar({
    required this.visible,
    required this.title,
    required this.onBack,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -0.4),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: visible ? 1 : 0,
          child: Padding(
            padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 8, Responsive.pagePadding(context), 0),
            child: Row(
              children: [
                _GlassCircle(icon: Icons.arrow_back_rounded, onTap: onBack),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _GlassCircle(icon: Icons.more_vert_rounded, onTap: onMenu),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部居中页码（S5：`3 / 128`）。
class _ReaderPageIndicator extends StatelessWidget {
  final bool visible;
  final String label;
  const _ReaderPageIndicator({required this.visible, required this.label});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 102,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: visible ? 1 : 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部悬浮玻璃工具栏（S5：亮度 / 目录 / 翻页模式 / 下载 / 下一章）。
class _ReaderToolbar extends StatelessWidget {
  final bool visible;
  final bool downloaded;
  final bool horizontal;
  final bool doublePage;
  final VoidCallback? onBrightness;
  final VoidCallback onCatalog;
  final VoidCallback onLayout;
  final VoidCallback? onDownload;
  /// 上一章回调；null = 已到第一章（按钮置灰禁用）。
  final VoidCallback? onPrevChapter;
  /// 下一章回调；null = 已到最后一章（按钮置灰禁用）。
  final VoidCallback? onNextChapter;
  const _ReaderToolbar({
    required this.visible,
    required this.downloaded,
    required this.horizontal,
    required this.doublePage,
    this.onBrightness,
    required this.onCatalog,
    required this.onLayout,
    this.onDownload,
    this.onPrevChapter,
    this.onNextChapter,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(0, 0.5),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: visible ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 26),
              child: Center(
                child: Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ToolBtn(
                        icon: Icons.brightness_6_outlined,
                        onTap: onBrightness,
                      ),
                      _sep(),
                      _ToolBtn(
                        icon: Icons.list_alt_rounded,
                        onTap: onCatalog,
                      ),
                      _sep(),
                      _ToolBtn(
                        icon: doublePage
                            ? Icons.view_module_outlined
                            : (horizontal
                                ? Icons.view_carousel_outlined
                                : Icons.view_stream_outlined),
                        onTap: onLayout,
                      ),
                      _sep(),
                      _ToolBtn(
                        icon: downloaded
                            ? Icons.download_done_rounded
                            : Icons.download_outlined,
                        active: downloaded,
                        onTap: onDownload,
                      ),
                      if (onPrevChapter != null) ...[
                        _sep(),
                        _ToolBtn(
                          icon: Icons.skip_previous_rounded,
                          onTap: onPrevChapter,
                        ),
                      ],
                      if (onNextChapter != null) ...[
                        _sep(),
                        _ToolBtn(
                          icon: Icons.skip_next_rounded,
                          onTap: onNextChapter,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sep() => Container(
        width: 0.5,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: Colors.white.withValues(alpha: 0.18),
      );
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  const _ToolBtn({required this.icon, this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 20,
          color: active ? Colors.amber : Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// 页目录底部弹窗（点击跳页）。
class _CatalogSheet extends StatelessWidget {
  final List<String> urls;
  final int current;
  final bool horizontal;
  final ValueChanged<int> onSelect;
  const _CatalogSheet({
    required this.urls,
    required this.current,
    required this.horizontal,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 16, Responsive.pagePadding(context), 20),
        decoration: BoxDecoration(
          // 固定深色背景，避免浅色主题下白底白字（与设置弹窗一致）
        color: const Color(0xFF1C1B1F),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('本话目录 · 共 ${urls.length} 页',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 12),
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 目录弹窗被限宽（500dp）居中，网格列数不能按全屏宽算
                  // （全屏宽在桌面高达 14 列，500dp 内每格会被挤到 ~24dp）。
                  // 按容器实际宽度推导，每格约 44dp 起，最多 10 列。
                  final cols =
                      (constraints.maxWidth / 44).floor().clamp(4, 10);
                  return GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.1,
                    ),
                    itemCount: urls.length,
                    itemBuilder: (_, i) {
                      final active = i == current;
                      return InkWell(
                        onTap: () => onSelect(i),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          decoration: BoxDecoration(
                            color: active
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  active ? FontWeight.w700 : FontWeight.w500,
                              color: active
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 玻璃态圆形按钮。
class _GlassCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _GlassCircle({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }
}

/// 章末连读尾页：提示"下一话"并点击跳转。
class _NextChapterFooter extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  const _NextChapterFooter({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_downward_rounded,
                size: 28, color: Colors.white.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              '已到底部',
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.skip_next_rounded, size: 18),
              label: Text('下一话：$title'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
