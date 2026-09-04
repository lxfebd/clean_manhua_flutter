import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/local_store.dart';
import '../net/update_checker.dart';
import 'widgets/update_download_dialog.dart';
import 'anime_home_page.dart';
import 'bookshelf_page.dart';
import 'home_page.dart';
import 'novel_home_page.dart';
import 'profile_page.dart';
import 'responsive.dart';
import 'toolbox_page.dart';
import 'widgets/motion.dart';

/// 主框架：底部 Tab 导航（首页 / 书架 / 工具 / 我的）。
///
/// 导航模式（遵循 Material Design 3 规范）：
/// - compact（手机）：BottomNavigationBar
/// - medium（小平板）：NavigationRail（图标模式）
/// - expanded（平板）：NavigationRail（图标+标签模式）
/// - large（桌面）：NavigationRail（图标+标签模式）+ 更宽内容区
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with TickerProviderStateMixin {
  int _index = 0;
  final GlobalKey<BookshelfPageState> _shelfKey =
      GlobalKey<BookshelfPageState>();
  final GlobalKey<ProfilePageState> _profileKey =
      GlobalKey<ProfilePageState>();
  final GlobalKey<ToolboxPageState> _toolboxKey =
      GlobalKey<ToolboxPageState>();

  // 键盘快捷键焦点节点
  final FocusNode _focusNode = FocusNode();

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
    _focusNode.dispose();
    HardwareKeyboard.instance.removeHandler(_shortcutHandler);
    super.dispose();
  }

  bool _shortcutHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // 桌面快捷键仅在符合窗口宽度条件时才生效（在 build 中注册）
    if (!_shortcutsEnabled) return false;

    // Ctrl/Cmd + 数字键切换标签页
    final isModifier = Platform.isMacOS
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

    return false;
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
      await LocalStore.setLastUpdateCheckTs(now);
      final info =
          await UpdateChecker.checkLatest(timeout: const Duration(seconds: 10));
      if (info == null || !mounted) return;
      _showUpdateDialog(info);
    } catch (e) {
      debugPrint('auto update check failed: $e');
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
              showUpdateDownloadDialog(context, info.apkUrl);
            },
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }

  void _onTab(int i) {
    setState(() => _index = i);
    if (i == 4) {
      _shelfKey.currentState?.reload();
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
    final tabs = [
      const MangaAnimeTabs(),
      HomePage(type: 0),
      AnimeHomePage(type: 1),
      NovelHomePage(type: 2),
      BookshelfPage(key: _shelfKey),
      ToolboxPage(key: _toolboxKey),
      ProfilePage(key: _profileKey, onSwitchTab: _onTab),
    ];
    final body = IndexedStack(
      index: _index,
      children: tabs,
    );

    final screenSize = Responsive.screenSize(context);

    // compact（手机）：底部导航栏
    if (screenSize == ScreenSize.compact) {
      return Scaffold(
        extendBody: false,
        body: body,
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
      body: Row(
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
    );
  }
}

/// 自适应 NavigationRail：遵循 Material Design 3 规范。
///
/// - medium 模式：可折叠（图标-only ↔ 图标+标签）
/// - expanded/large 模式：始终显示图标+标签
class _AdaptiveNavigationRail extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isDark;

  const _AdaptiveNavigationRail({
    required this.currentIndex,
    required this.onTap,
    required this.isDark,
  });

  static const _navItems = [
    (Icons.home_outlined, Icons.home_rounded, '首页'),
    (Icons.auto_stories_outlined, Icons.auto_stories_rounded, '漫画'),
    (Icons.movie_outlined, Icons.movie_rounded, '动漫'),
    (Icons.menu_book_outlined, Icons.menu_book_rounded, '小说'),
    (Icons.bookmark_border_rounded, Icons.bookmark_rounded, '书架'),
    (Icons.tune_outlined, Icons.tune, '工具'),
    (Icons.person_outline_rounded, Icons.person_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 桌面端（Windows/macOS/Linux）：宽侧栏 + 图标文字横排 + Logo 字标，
    // 与 VS Code / Discord / 网易云音乐 PC 端侧栏同构；
    // 平板仍用 88dp 竖排窄栏（移动端形态），不混用。
    final isDesktop = DesktopUi.isDesktopPlatform;

    // 极简侧栏：白底 + hairline 描边 + 12 圆角，零阴影。
    // 不固定宽度会收到 Row 的无界主轴约束，触发 non-zero flex unbounded 错误。
    return Container(
      width: isDesktop ? kRailDesktopWidth : kRailWidth,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          right: BorderSide(color: scheme.outline, width: 1),
        ),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            // 顶部：品牌区。桌面端为「Logo 块 + 星漫匣字标」横排，
            // 平板为纯 Logo 块居中。
            Padding(
              padding: EdgeInsets.fromLTRB(isDesktop ? 16 : 0, 16, isDesktop ? 16 : 0, 10),
              child: isDesktop
                  ? Row(
                      children: [
                        _RailLogo(isDark: isDark, size: 30, fontSize: 14),
                        const SizedBox(width: 10),
                        Text(
                          '星漫匣',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    )
                  : _RailLogo(isDark: isDark, size: 38, fontSize: 16),
            ),

            // 导航组：桌面端靠左上排列（列表式，符合桌面阅读顺序），
            // 平板端整体垂直居中（窄栏图标组）。
            Expanded(
              child: isDesktop
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                      // 矮窗口（横屏/半屏）下导航项多于可视高度时退化为滚动，
                      // 避免 Column 定高堆叠溢出黄条（960x540 复现）。
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < _navItems.length; i++) ...[
                              if (i > 0) const SizedBox(height: 4),
                              _NavigationRailItem(
                                icon: _navItems[i].$1,
                                activeIcon: _navItems[i].$2,
                                label: _navItems[i].$3,
                                isSelected: i == currentIndex,
                                showLabel: true,
                                horizontal: true,
                                onTap: () => onTap(i),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : Center(
                      // Center 传 loose 约束：内容不足时居中，超过可视高度
                      // （矮横屏 960x540 / 800x450）时由滚动视图兜底。
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < _navItems.length; i++) ...[
                                if (i > 0) const SizedBox(height: 12),
                                _NavigationRailItem(
                                  icon: _navItems[i].$1,
                                  activeIcon: _navItems[i].$2,
                                  label: _navItems[i].$3,
                                  isSelected: i == currentIndex,
                                  showLabel: true,
                                  onTap: () => onTap(i),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
            ),

            // 底部留白：保持导航组视觉居中
            const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }
}

/// Rail 顶部品牌 Logo：墨色填充块 + 反色"星"字标（Minimalist：无渐变、无辉光）。
class _RailLogo extends StatelessWidget {
  final bool isDark;
  final double size;
  final double fontSize;
  const _RailLogo({
    required this.isDark,
    required this.size,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(size * 0.30),
      ),
      child: Center(
        child: Text(
          '星',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: fontSize,
            height: 1.0,
            color: scheme.onPrimary,
          ),
        ),
      ),
    );
  }
}

/// Rail 导航项：
/// - 竖排（平板窄栏）：图标在上、标签在下，卡牌式垂直堆叠。
/// - 横排（桌面宽栏，[horizontal]=true）：图标在左、标签在右，
///   左对齐列表行，与桌面应用侧栏导航同构。
///
/// - 选中：整张主题色卡牌（桌面为整行圆角胶囊）
/// - 未选中：透明底 + 裸图标，hover 时浮现极浅底色
class _NavigationRailItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isSelected;
  final bool showLabel;
  final bool horizontal;
  final VoidCallback onTap;

  const _NavigationRailItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isSelected,
    required this.showLabel,
    required this.onTap,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (horizontal) {
      return HoverEffect(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isSelected ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? activeIcon : icon,
                size: 20,
                color: isSelected
                    ? scheme.onPrimary
                    : scheme.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.0,
                    letterSpacing: 0.2,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected
                        ? scheme.onPrimary
                        : scheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return HoverEffect(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        width: double.infinity,
        height: showLabel ? 62 : 52,
        decoration: BoxDecoration(
          color: isSelected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 图标：选中时白色坐在墨色胶囊上
            Icon(
              isSelected ? activeIcon : icon,
              size: 22,
              color: isSelected
                  ? scheme.onPrimary
                  : scheme.onSurface.withValues(alpha: 0.55),
            ),
            if (showLabel) ...[
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.0,
                  letterSpacing: 0.2,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? scheme.onPrimary
                      : scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 极简底部导航：白底 + 顶部 hairline 分割线，选中态用墨色 + 顶部短指示条。
class _MinimalBottomBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isDark;
  const _MinimalBottomBar({
    required this.currentIndex,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outline, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              _Item(
                icon: Icons.home_outlined,
                active: Icons.home_rounded,
                label: '首页',
                index: 0,
                current: currentIndex,
                onTap: onTap,
                isDark: isDark,
              ),
              _Item(
                icon: Icons.bookmark_border_rounded,
                active: Icons.bookmark_rounded,
                label: '书架',
                index: 4,
                current: currentIndex,
                onTap: onTap,
                isDark: isDark,
              ),
              _Item(
                icon: Icons.tune_outlined,
                active: Icons.tune,
                label: '工具',
                index: 5,
                current: currentIndex,
                onTap: onTap,
                isDark: isDark,
              ),
              _Item(
                icon: Icons.person_outline_rounded,
                active: Icons.person_rounded,
                label: '我的',
                index: 6,
                current: currentIndex,
                onTap: onTap,
                isDark: isDark,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final IconData icon;
  final IconData active;
  final String label;
  final int index;
  final int current;
  final ValueChanged<int> onTap;
  final bool isDark;
  const _Item({
    required this.icon,
    required this.active,
    required this.label,
    required this.index,
    required this.current,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final isOn = index == current;
    final fg = Theme.of(context).colorScheme.onSurface;
    final softColor = fg.withValues(alpha: isDark ? 0.45 : 0.4);
    return Expanded(
      child: PressableScale(
        onTap: () => onTap(index),
        scale: 0.95,
        child: Stack(
          children: [
            // 选中指示条：顶部居中的墨色短线（Minimalist 标志性细节）
            AnimatedPositioned(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  width: isOn ? 20 : 0,
                  height: 2,
                  color: fg,
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isOn ? active : icon,
                    size: 20,
                    color: isOn ? fg : softColor,
                  ),
                  const SizedBox(height: 2),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.1,
                      letterSpacing: 0.2,
                      fontWeight: isOn ? FontWeight.w600 : FontWeight.w500,
                      color: isOn ? fg : softColor,
                    ),
                    child: Text(label),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首页内：漫画 / 动漫 二选一（带切换动效）
class MangaAnimeTabs extends StatefulWidget {
  const MangaAnimeTabs({super.key});

  @override
  State<MangaAnimeTabs> createState() => _MangaAnimeTabsState();
}

class _MangaAnimeTabsState extends State<MangaAnimeTabs> {
  int _type = 0;

  @override
  Widget build(BuildContext context) {
    if (_type == 2) {
      return NovelHomePage(
          type: _type, onTypeChanged: (v) => setState(() => _type = v));
    }
    return _type == 0
        ? HomePage(
            type: _type, onTypeChanged: (v) => setState(() => _type = v))
        : AnimeHomePage(
            type: _type,
            onTypeChanged: (v) => setState(() => _type = v));
  }
}
