import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bookshelf_providers.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/update_checker.dart';
import '../services/player_registry.dart';
import 'widgets/update_download_dialog.dart';
import 'anime_home_page.dart';
import 'anime_player_page.dart' show animePlayerWebChannel;
import 'bookshelf_page.dart';
import 'home_page.dart';
import 'keyboard_shortcuts.dart';
import 'native_player_page.dart';
import 'novel_home_page.dart';
import 'profile_page.dart';
import 'responsive.dart';
import 'style_scope.dart';
import 'tokens.dart';
import 'toolbox_page.dart';
import 'unified_search_page.dart';
import 'widgets/frosted_glass.dart';
import 'widgets/mini_player.dart';
import 'widgets/motion.dart';
import 'widgets/tap_target.dart';

part 'main_shell_widgets.dart';

/// 主框架：底部 Tab 导航（首页 / 书架 / 工具 / 我的）。
///
/// 导航模式（遵循 Material Design 3 规范）：
/// - compact（手机）：BottomNavigationBar
/// - medium（小平板）：NavigationRail（图标模式）
/// - expanded（平板）：NavigationRail（图标+标签模式）
/// - large（桌面）：NavigationRail（图标+标签模式）+ 更宽内容区
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with TickerProviderStateMixin {
  int _index = 0;

  /// 首页 hub 内当前类型（0=漫画 1=动漫 2=小说）。
  /// 桌面/平板侧栏把 1/2/3 映射到这里，保证导航高亮与内容联动；
  /// 移动端仅 hub 可见（_index 只取 0/4/5/6），由 hub 内 TypeSegment 驱动。
  int _hubType = 0;

  final GlobalKey<ProfilePageState> _profileKey =
      GlobalKey<ProfilePageState>();
  final GlobalKey<ToolboxPageState> _toolboxKey =
      GlobalKey<ToolboxPageState>();
  final GlobalKey<MangaAnimeTabsState> _hubKey =
      GlobalKey<MangaAnimeTabsState>();

  /// 是否启用桌面快捷键：按窗口宽度（Material 3 Expanded 起，≥840dp）
  /// 而非平台类型判断。桌面窗口默认 1100dp 宽、平板横屏多 ≥840dp，
  /// 二者均为带物理键盘场景；手机/窄平板（<840dp）不启用，
  /// 避免与阅读器手势、单指操作冲突。
  bool _getEnableShortcuts(context) => Responsive.isExpanded(context);

  @override
  void initState() {
    super.initState();
    _autoCheckUpdate();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_shortcutHandler);
    super.dispose();
  }

  bool _shortcutHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // 桌面快捷键仅在符合窗口宽度条件时才生效（在 build 中注册）
    if (!_shortcutsEnabled) return false;

    // 只响应「主壳路由在栈顶」时的按键：阅读器/详情/搜索等推入页面后，
    // 全局键（Ctrl+← 后退、Ctrl+F 搜索、Ctrl+1…7 切 tab）不得抢占
    // 子页自己的处理，否则在阅读器里按 Ctrl+← 会把整个播放页 pop 掉。
    final nav = Navigator.of(context);
    if (nav.canPop()) return false;

    // Ctrl/Cmd + 数字键切换标签页
    // 用 defaultTargetPlatform 而非 dart:io Platform：widget 测试里
    // dart:io 恒报宿主平台，无法覆盖 macOS 分支。
    final isModifier = defaultTargetPlatform == TargetPlatform.macOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;

    if (isModifier) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.digit1:
          _onTab(0);
          return true;
        case LogicalKeyboardKey.digit2:
          _onTab(1);
          return true;
        case LogicalKeyboardKey.digit3:
          _onTab(2);
          return true;
        case LogicalKeyboardKey.digit4:
          _onTab(3);
          return true;
        case LogicalKeyboardKey.digit5:
          _onTab(4);
          return true;
        case LogicalKeyboardKey.digit6:
          _onTab(5);
          return true;
        case LogicalKeyboardKey.digit7:
          _onTab(6);
          return true;
        case LogicalKeyboardKey.keyF:
          _openGlobalSearch();
          return true;
        case LogicalKeyboardKey.keyR:
          _refreshCurrentTab();
          return true;
        case LogicalKeyboardKey.arrowLeft:
          // 后退
          if (Navigator.canPop(context)) Navigator.pop(context);
          return true;
        case LogicalKeyboardKey.arrowRight:
          // 前进（无前进栈，忽略）
          return true;
      }
    }

    // Alt + 左右箭头导航
    if (HardwareKeyboard.instance.isAltPressed) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          }
          return true;
        case LogicalKeyboardKey.arrowRight:
          // 可以添加前进逻辑
          return true;
      }
    }

    // `?` 打开快捷键面板
    if (event.logicalKey == LogicalKeyboardKey.slash &&
        HardwareKeyboard.instance.isShiftPressed) {
      _showShortcutHelp();
      return true;
    }

    return false;
  }

  /// 全局搜索：打开统一搜索页。
  void _openGlobalSearch() {
    // 统一搜索页未接入主壳 Tab，用路由推入，自然叠加在内容区之上。
    Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => const UnifiedSearchPage(keyword: '')),
    );
  }

  /// 刷新当前标签页内容（Ctrl+R）。
  void _refreshCurrentTab() {
    switch (_index) {
      case 0:
        // 首页 hub：按当前漫画/动漫/小说类型分发到对应页刷新。
        _hubKey.currentState?.refreshCurrent();
        break;
      case 4:
        // 书架数据源为 Riverpod provider：失效即重读（等同原 reload）。
        ref.invalidate(bookshelfDataProvider);
        break;
      case 5:
        _toolboxKey.currentState?.refresh();
        break;
      case 6:
        _profileKey.currentState?.refresh();
        break;
    }
  }

  /// 快捷键面板：半透明遮罩弹层。
  void _showShortcutHelp() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => const ShortcutHelpOverlay(),
      ),
    );
  }

  bool _shortcutsEnabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enable = _getEnableShortcuts(context);
    if (enable != _shortcutsEnabled) {
      _shortcutsEnabled = enable;
      if (enable) {
        HardwareKeyboard.instance.addHandler(_shortcutHandler);
      } else {
        HardwareKeyboard.instance.removeHandler(_shortcutHandler);
      }
    }
  }

  Future<void> _autoCheckUpdate() async {
    try {
      final last = await LocalStore.lastUpdateCheckTs();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 24).inMilliseconds) return;
      // 先联网检查、确认本次成功（无论有无新版本）再写时间戳：
      // 失败（弱网/离线）时不写，否则下一次启动被 24h 门闸直接抑制，
      // 更新检查会永远不再发生。
      final info =
          await UpdateChecker.checkLatest(timeout: const Duration(seconds: 10));
      if (!mounted) return;
      await LocalStore.setLastUpdateCheckTs(now);
      if (!mounted || info == null) return;
      _showUpdateDialog(info);
    } catch (e) {
      ErrorLogger.instance.warn('auto update check failed: $e');
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (info.notes != null && info.notes!.isNotEmpty) ...[
                Text(info.notes!, style: const TextStyle(fontSize: 12.5)),
                const SizedBox(height: 12),
              ],
              Text(
                '当前版本：v${UpdateChecker.currentVersion()}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(ctx)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('以后再说'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              showUpdateDownloadDialog(context, info.apkUrl,
                  assetName: info.assetName);
            },
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }

  void _onTab(int i) {
    // 侧栏/底栏导航：1/2/3 是 hub 内的漫画/动漫/小说（hub 在索引 0 可见）。
    if (i == 1 || i == 2 || i == 3) {
      setState(() {
        _index = 0;
        _hubType = i - 1;
      });
      return;
    }
    setState(() => _index = i);
    if (i == 4) {
      // 书架 provider 失效即重读（原 _shelfKey.currentState?.reload()）。
      ref.invalidate(bookshelfDataProvider);
    }
    if (i == 5) {
      // 切到工具页时刷新下载列表/缓存占用，避免下载完成后列表停留在旧进度
      _toolboxKey.currentState?.refresh();
    }
    if (i == 6) {
      _profileKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 单个 hub（内部保活漫画/动漫/小说三页）+ 书架/工具/我的。
    // 侧栏的漫画/动漫/小说入口（1/2/3）映射到 hub 的 _hubType，
    // 不再各建独立页——否则 IndexedStack 会同时 initState 两套三页
    // （冷启动 9 页同建树、同类页两份状态、数据重复拉取）。
    final tabs = [
      MangaAnimeTabs(
        key: _hubKey,
        type: _hubType,
        onTypeChanged: (v) => setState(() => _hubType = v),
      ),
      BookshelfPage(onGotoHome: () => _onTab(0)),
      ToolboxPage(key: _toolboxKey),
      ProfilePage(key: _profileKey, onSwitchTab: _onTab),
    ];
    // _index 是侧栏/底栏的原始导航索引（书架=4/工具=5/我的=6，1/2/3 在
    // _onTab 已归一到 hub 0），而 tabs 只有 4 页——必须映射后再喂
    // IndexedStack，否则 index=4 越界直接红屏断言崩溃。
    final stackIndex = switch (_index) {
      4 => 1,
      5 => 2,
      6 => 3,
      _ => 0,
    };
    final body = IndexedStack(
      index: stackIndex,
      children: tabs,
    );

    final screenSize = Responsive.screenSize(context);

    // 画中画底部浮层：全屏播放器最小化后在这里以小窗继续播放。
    final miniOverlay = _buildMiniOverlay();

    // compact（手机）：底部导航栏
    if (screenSize == ScreenSize.compact) {
      return Scaffold(
        extendBody: false,
        body: Stack(children: [body, miniOverlay]),
        bottomNavigationBar: _MinimalBottomBar(
          currentIndex: _index,
          onTap: _onTab,
          isDark: isDark,
        ),
      );
    }

    // medium / expanded / large：窄图标侧边栏（72dp，Discord/VS Code 式）。
    // 仅 4 个入口时用文字宽栏必然空旷，图标-only 让留白读作"有意为之"；
    // 标签通过悬停 tooltip / 长按提示提供。
    return Scaffold(
      body: Stack(children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AdaptiveNavigationRail(
              currentIndex: _index,
              onTap: _onTab,
              isDark: isDark,
            ),
            // 主内容区：大屏（≥1200dp）收到 1200/1400dp 并居中，
            // 避免列表与卡片被拉到屏幕边缘（M3 大屏准则 LS-U1）。
            Expanded(child: MaxWidthContainer(child: body)),
          ],
        ),
        miniOverlay,
      ]),
    );
  }

  /// 画中画浮层（Positioned 底部居中）。
  ///
  /// 状态来自 [PlayerRegistry]，Home 内直接以 ValueListenableBuilder 呈现，
  /// 无需单独状态管理：发布/取回/关闭都只是改 notifier.value。
  Widget _buildMiniOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ValueListenableBuilder<PlayerHandoff?>(
        valueListenable: PlayerRegistry.notifier,
        builder: (context, handoff, _) {
          if (handoff == null) return const SizedBox.shrink();
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlayer(
                  handoff: handoff,
                  onResume: () => _resumeFromMini(handoff),
                  onClose: () => PlayerRegistry.retire(),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 小窗 → 回到原生播放页：取回 Player 并复用它重建同一播放会话。
  void _resumeFromMini(PlayerHandoff handoff) {
    final taken = PlayerRegistry.resumePlayer();
    if (taken == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NativePlayerPage(
          url: taken.url,
          title: taken.title,
          cover: taken.cover,
          episodes: taken.episodes,
          season: taken.season,
          episode: taken.episode,
          resolveUrl: taken.resolveUrl,
          sourceNames: taken.sourceNames,
          sourceId: taken.sourceId,
          videoId: taken.videoId,
          historyKey: taken.historyKey,
          take: taken,
          webChannelBuilder: animePlayerWebChannel,
        ),
      ),
    );
  }
}
