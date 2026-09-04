import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'net/bookshelf_store.dart';
import 'net/http_client.dart';
import 'net/local_store.dart';
import 'net/novel_shelf_store.dart';
import 'net/update_checker.dart';
import 'net/video_download_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'theme.dart';
import 'ui/main_shell.dart';

/// 桌面端窗口管理：限定最小尺寸、设置标题、记忆并恢复上次窗口尺寸/位置。
/// 不隐藏系统标题栏（避免改动 Windows 原生 runner 导致构建失败），保持稳妥。
Future<void> _initDesktopWindow() async {
  await windowManager.ensureInitialized();
  const minSize = Size(480, 640);
  await windowManager.setMinimumSize(minSize);
  await windowManager.setTitle('星漫匣');
  final geo = await LocalStore.windowGeometry();
  if (geo != null) {
    await windowManager.setSize(Size(geo['w']!, geo['h']!));
    // 坐标异常（如曾拖到副屏后该屏断开）时居中，避免窗口跑到屏幕外。
    if (geo['x']! >= 0 && geo['y']! >= 0) {
      await windowManager.setPosition(Offset(geo['x']!, geo['y']!));
    } else {
      await windowManager.center();
    }
  } else {
    await windowManager.setSize(const Size(1100, 720));
    await windowManager.center();
  }
  windowManager.addListener(_DesktopWindowListener());
}

/// 监听窗口尺寸/位置变化，落盘以便下次启动恢复。
class _DesktopWindowListener extends WindowListener {
  @override
  void onWindowResized() async {
    final size = await windowManager.getSize();
    final pos = await windowManager.getPosition();
    await LocalStore.setWindowGeometry(
        w: size.width, h: size.height, x: pos.dx, y: pos.dy);
  }

  @override
  void onWindowMoved() async {
    final pos = await windowManager.getPosition();
    await LocalStore.setWindowGeometry(x: pos.dx, y: pos.dy);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize = 20;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 30 * 1024 * 1024;
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('MediaKit init failed: $e');
  }
  // 立即渲染首帧，避免用户看到灰色空窗
  runApp(const YingManHeApp());
  _postFirstFrameInit();
}

Future<void> _postFirstFrameInit() async {
  await Future<void>.delayed(const Duration(milliseconds: 100));
  try {
    await LocalStore.init();
  } catch (e) {
    debugPrint('LocalStore init failed: $e');
  }
  try {
    await UpdateChecker.init();
  } catch (e) {
    debugPrint('UpdateChecker init failed: $e');
  }
  try {
    await VideoDownloadManager.instance.init();
  } catch (e) {
    debugPrint('VideoDownloadManager init failed: $e');
  }
  try {
    await Net.restorePreferredHostIps();
  } catch (e) {
    debugPrint('restorePreferredHostIps failed: $e');
  }
  // 桌面端（Windows/macOS/Linux）：初始化窗口管理（最小尺寸 / 标题 / 尺寸记忆）。
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    try {
      await _initDesktopWindow();
    } catch (e) {
      debugPrint('initDesktopWindow failed: $e');
    }
  }
  try {
    final dir = await getApplicationSupportDirectory();
    BookshelfStore.bindFile(File('${dir.path}/bookshelf.json'));
    NovelShelfStore.bindFile(File('${dir.path}/novel_shelf.json'));
  } catch (e) {
    debugPrint('shelf bind failed: $e');
  }
}

class YingManHeApp extends StatefulWidget {
  const YingManHeApp({super.key});

  /// 供设置页调用以立即生效主题。
  static YingManHeAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<YingManHeAppState>();

  @override
  State<YingManHeApp> createState() => YingManHeAppState();
}

class YingManHeAppState extends State<YingManHeApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  ThemeMode _themeMode = ThemeMode.light;
  int _themeId = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 首帧后校正方向策略，避免启动就处于"竖屏锁+横屏 letterbox"状态
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _allowTabletRotations());
    _loadTheme();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 回到前台时放行平板旋转，避免残留的竖屏锁导致横屏 letterbox。
    if (state == AppLifecycleState.resumed) {
      _allowTabletRotations();
    }
    // Wakelock：前台常亮，切到后台/ inactive 恢复系统默认熄屏。
    // 阅读/播放页内部会自己 enable/disable（幂等），此处是兜底，
    // 保证首页/书架/详情等页面也不会因系统默认 30 秒熄屏而中断浏览。
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      WakelockPlus.enable();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      WakelockPlus.disable();
    }
  }

  /// 平板始终允许"竖屏+横屏"，残留的竖屏方向锁不会再导致横屏 letterbox（居中留白）。
  /// 不触碰手机方向策略，避免影响手机端原有行为。
  void _allowTabletRotations() {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return;
      final view = views.first;
      final w = view.physicalSize.width / view.devicePixelRatio;
      // 阈值与 Responsive.tabletBreakpoint(600) / 主题 isTablet 保持一致，
      // 避免 440-600dp 的折叠屏/小屏平板既放行横屏又走手机布局、表现割裂。
      if (w >= 600) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    } catch (e, st) {
      // 平台异常（如 views 为空）不阻塞首帧；仅 debugPrint 便于排查。
      debugPrint('allowTabletRotations failed: $e\n$st');
    }
  }

  Future<void> _loadTheme() async {
    final d = await LocalStore.darkMode();
    final tid = await LocalStore.themeId();
    if (mounted) {
      setState(() {
        _themeMode = d ? ThemeMode.dark : ThemeMode.light;
        _themeId = tid;
        _loaded = true;
      });
    }
  }

  void setDark(bool v) {
    setState(() => _themeMode = v ? ThemeMode.dark : ThemeMode.light);
  }

  void setThemeId(int id) {
    setState(() => _themeId = id);
  }

  @override
  Widget build(BuildContext context) {
    // 主题在 MaterialApp 外构建，MediaQuery 尚不可用；用 View 直接读逻辑宽度，
    // 与 Responsive.isTablet 的 600dp 断点对齐：手机走手机档字号，平板/桌面走桌面档。
    final view = View.of(context);
    final isTablet =
        (view.physicalSize.width / view.devicePixelRatio) >= 600.0;
    final themeData = AppTheme.light(_themeId, isTablet);
    final darkThemeData = AppTheme.dark(_themeId, isTablet);
    final effectiveMode = _loaded ? _themeMode : ThemeMode.light;
    // 用 AnimatedTheme 包住 MaterialApp：用户在设置/我的页切换深色或种子色时，
    // 220ms 内完成明暗/色相过渡，避免主题瞬间切换的闪烁感。
    return AnimatedTheme(
      data: effectiveMode == ThemeMode.dark ? darkThemeData : themeData,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: MaterialApp(
        title: '星漫匣',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigatorKey,
        theme: themeData,
        darkTheme: darkThemeData,
        themeMode: effectiveMode,
        // 桌面端滚动条常显（Windows/macOS/Linux），手机保持原生不常显
        scrollBehavior: const _AppScrollBehavior(),
        // 用 builder 包住 Navigator，保证侧键返回在任意路由层都生效。
        //
        // 状态栏透明：首页等页面用自定义 SafeArea 头部（无 AppBar），
        // AppBarTheme.systemOverlayStyle 只对有 AppBar 的页面生效，状态栏仍是
        // 系统实心灰条（小米实测 (187,187,187)）。这里在 builder 里包一层
        // AnnotatedRegion 全应用统一 SystemUiOverlayStyle，让状态栏透明，
        // 内容直接顶到屏幕顶部，与有 AppBar 的页面表现一致。
        builder: (context, child) => MouseNavListener(
          onBack: _onMouseBack,
          child: AnnotatedRegion(
            value: SystemUiOverlayStyle(
              // 状态栏 + 导航栏全透明：首页等页面用自定义 SafeArea 头部（无 AppBar），
              // AppBarTheme.systemOverlayStyle 只对有 AppBar 的页面生效，
              // 否则状态栏仍是系统实心灰条（小米实测 (187,187,187)）。
              // 导航栏同样透明，让内容顶到屏幕底部，与 Minimalist 零留白一致。
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
              // 亮色主题：图标深色（浅底深图标）；
              // 暗色主题：图标浅色（深底浅图标）。
              statusBarIconBrightness: effectiveMode == ThemeMode.dark
                  ? Brightness.light
                  : Brightness.dark,
              systemNavigationBarIconBrightness: effectiveMode == ThemeMode.dark
                  ? Brightness.light
                  : Brightness.dark,
              // 关掉系统在透明状态栏/导航栏后自动加的半透明 scrim，
              // 避免白底上出现灰蒙、暗底上出现黑蒙。
              systemStatusBarContrastEnforced: false,
              systemNavigationBarContrastEnforced: false,
            ),
            // 字体缩放钳制：小米等系统字体放大（fontScale >1）时，
            // TypeScale 硬编码字号会被系统放大，导致网格卡片溢出/文字截断。
            // 这里用 MediaQuery 覆盖 textScaler 为 noScaling，
            // 保持设计稿字号不变（允许用户在系统设置里调小，但不允许调大）。
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.noScaling,
              ),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
        home: const MainShell(),
      ),
    );
  }

  /// 鼠标侧键（后退键）在任意页面触发系统返回。
  void _onMouseBack() {
    _navigatorKey.currentState?.maybePop();
  }
}

/// 鼠标侧键返回监听：桌面端把鼠标侧键（X1=后退）映射为系统返回。
/// 只拦截鼠标指针事件，触摸/触控板不会误触。
class MouseNavListener extends StatelessWidget {
  final VoidCallback onBack;
  final Widget child;
  const MouseNavListener({super.key, required this.onBack, required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        // 仅当按下的是鼠标侧键（X1=后退，位 0x08）时才响应，
        // 避免普通左键/右键、触摸、触控板误触。
        if (e.kind == PointerDeviceKind.mouse &&
            (e.buttons & kBackMouseButton) != 0) {
          onBack();
        }
      },
      child: child,
    );
  }
}

/// 桌面端滚动条策略：Windows/macOS/Linux 常显滚动条（P2），
/// 手机端（Android/iOS）保持默认（仅滚动时显示）。
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (!isDesktop) {
      return super.buildScrollbar(context, child, details);
    }
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: true,
      child: child,
    );
  }
}
