import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _autoCheckUpdate();
  }

  Future<void> _autoCheckUpdate() async {
    try {
      final last = await LocalStore.lastUpdateCheckTs();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 24).inMilliseconds) return;
      await LocalStore.setLastUpdateCheckTs(now);
      final info = await UpdateChecker.checkLatest(
          timeout: const Duration(seconds: 10));
      if (info == null || !mounted) return;
      if (mounted) _showUpdateDialog(info);
    } catch (_) {}
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
    if (i == 1) {
      _shelfKey.currentState?.reload();
    }
    if (i == 2) {
      // 切到工具页时刷新下载列表/缓存占用，避免下载完成后列表停留在旧进度
      _toolboxKey.currentState?.refresh();
    }
    if (i == 3) {
      _profileKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tabs = [
      const MangaAnimeTabs(),
      BookshelfPage(key: _shelfKey),
      ToolboxPage(key: _toolboxKey),
      ProfilePage(key: _profileKey, onSwitchTab: _onTab),
    ];
    final body = IndexedStack(
      index: _index,
      children: tabs,
    );

    // 平板/桌面：左侧 NavigationRail + 右侧内容
    if (Responsive.isTablet(context)) {
      return Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TabletSideNav(
              currentIndex: _index,
              onTap: _onTab,
              isDark: isDark,
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    // 手机：底部玻璃导航栏
    return Scaffold(
      extendBody: true,
      body: body,
      bottomNavigationBar: _GlassBottomBar(
        currentIndex: _index,
        onTap: _onTab,
        isDark: isDark,
      ),
    );
  }
}

/// 玻璃态底部导航栏
class _GlassBottomBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isDark;
  const _GlassBottomBar({
    required this.currentIndex,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: 0.06),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 18,
                spreadRadius: -2,
                offset: const Offset(0, 6),
              ),
            ],
          ),
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
                index: 1,
                current: currentIndex,
                onTap: onTap,
                isDark: isDark,
              ),
              _Item(
                icon: Icons.tune_outlined,
                active: Icons.tune,
                label: '工具',
                index: 2,
                current: currentIndex,
                onTap: onTap,
                isDark: isDark,
              ),
              _Item(
                icon: Icons.person_outline_rounded,
                active: Icons.person_rounded,
                label: '我的',
                index: 3,
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
    final softColor = fg.withValues(alpha: isDark ? 0.45 : 0.35);
    return Expanded(
      child: PressableScale(
        onTap: () => onTap(index),
        scale: 0.94,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(
                  horizontal: isOn ? 14 : 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: isOn ? fg.withValues(alpha: 0.08) : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  isOn ? active : icon,
                  size: 20,
                  color: isOn ? fg : softColor,
                ),
              ),
              const SizedBox(height: 1),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 240),
                style: TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: isOn ? FontWeight.w700 : FontWeight.w500,
                  color: isOn ? fg : softColor,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 平板/桌面侧边导航栏：替代底部导航，宽屏更高效。
class _TabletSideNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isDark;
  const _TabletSideNav({
    required this.currentIndex,
    required this.onTap,
    required this.isDark,
  });

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, '首页'),
    (Icons.bookmark_border_rounded, Icons.bookmark_rounded, '书架'),
    (Icons.tune_outlined, Icons.tune, '工具'),
    (Icons.person_outline_rounded, Icons.person_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 108,
      margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.06),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.07),
            blurRadius: 16,
            spreadRadius: -2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              // 顶部 Logo 独立小区域，不占 4 项均分高度
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('星漫匣',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: scheme.primary)),
              ),
              // 4 个导航项垂直均分剩余高度，整块可点 + 整块高亮
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 4, horizontal: 6),
                    child: _SideNavItem(
                      item: _items[i],
                      index: i,
                      current: currentIndex,
                      onTap: onTap,
                      isDark: isDark,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideNavItem extends StatelessWidget {
  final (IconData, IconData, String) item;
  final int index;
  final int current;
  final ValueChanged<int> onTap;
  final bool isDark;
  const _SideNavItem({
    required this.item,
    required this.index,
    required this.current,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final isOn = index == current;
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurface;
    final softColor = fg.withValues(alpha: isDark ? 0.45 : 0.35);
    return PressableScale(
      onTap: () => onTap(index),
      scale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: double.infinity,
        height: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isOn
              ? scheme.primary.withValues(alpha: isDark ? 0.28 : 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: isOn
              ? Border.all(
                  color: scheme.primary.withValues(alpha: 0.3), width: 1)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isOn ? item.$2 : item.$1,
                size: 28, color: isOn ? scheme.primary : softColor),
            const SizedBox(height: 7),
            Text(
              item.$3,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: isOn ? FontWeight.w700 : FontWeight.w500,
                color: isOn ? scheme.primary : softColor,
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
        ? HomePage(type: _type, onTypeChanged: (v) => setState(() => _type = v))
        : AnimeHomePage(
            type: _type, onTypeChanged: (v) => setState(() => _type = v));
  }
}
