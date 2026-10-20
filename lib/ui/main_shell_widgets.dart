part of 'main_shell.dart';

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
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
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
    // 侧栏胶囊圆角：极简锁既有 10（回归面为零），小米/苹果走风格档位。
    final railRadius = context.uiStyle == UIStyle.minimalist
        ? 10.0
        : R.of(R.control, style: context.uiStyle);

    if (horizontal) {
      return HoverEffect(
        focusable: true, // TV 遥控器 D-pad 焦点导航
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isSelected ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(railRadius),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? activeIcon : icon,
                size: 20,
                color: isSelected
                    ? scheme.onPrimary
                    : T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
      focusable: true, // TV 遥控器 D-pad 焦点导航
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        width: double.infinity,
        height: showLabel ? 62 : 52,
        decoration: BoxDecoration(
          color: isSelected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(railRadius),
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
                  : T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
            ),
            if (showLabel) ...[
              const SizedBox(height: 5),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  height: 1.0,
                  letterSpacing: 0.2,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? scheme.onPrimary
                      : T.color(scheme.onSurface, TextTier.mid,
                          brightness: scheme.brightness),
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
///
/// 三套风格差异：
/// - [UIStyle.minimalist]：顶部墨色短指示条 + 无底块（现有实现）。
/// - [UIStyle.xiaomi]：选中项浮起**胶囊色块高亮**（品牌色渐变），HyperOS 观感。
/// - [UIStyle.apple]：系统蓝选中 + 顶部指示条收敛（iOS 简化）。
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
    final style = context.uiStyle;
    // 苹果底栏走 FrostedGlass 真毛玻璃（固定悬浮层，不随内容滚动，性能安全）；
    // 极简/小米走纯表面。
    final border = Border(
      top: BorderSide(color: scheme.outline, width: 1),
    );
    final bg = style == UIStyle.apple
        ? FrostedGlass(border: border, child: _bar(context, scheme, style))
        : Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              border: border,
            ),
            child: _bar(context, scheme, style),
          );
    return bg;
  }

  Widget _bar(
    BuildContext context,
    ColorScheme scheme,
    UIStyle style,
  ) {
    return SafeArea(
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
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurface;
    final style = context.uiStyle;
    // 选中色：极简/小米用主题前景（墨），苹果用系统蓝。
    final activeColor = style == UIStyle.apple
        ? Theme.of(context).colorScheme.primary
        : fg;
    final softColor = fg.withValues(alpha: isDark ? 0.45 : 0.4);
    // 小米选中胶囊高亮（品牌色 12% 底 + 主题色图标/文字）。
    final xiaomiHighlight = style == UIStyle.xiaomi && isOn;
    return Expanded(
      child: PressableScale(
        onTap: () => onTap(index),
        scale: 0.95,
        // 命中区 ≥44×44：PressableScale 不约束热区，图标+文字内容
        // 高度不足 44 时会缩成 ~33dp（8-31 门禁实测），TapTargetMin 放
        // 手势组件内部作 child 才能把手势盒子本身撑到 44。
        child: TapTargetMin(
          child: Stack(
            children: [
              // 极简/苹果：顶部选中指示条（苹果收敛为系统蓝短线）
              if (!xiaomiHighlight)
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
                      color: activeColor,
                    ),
                  ),
                ),
              // 小米：选中项胶囊色块（44 高、渐变品牌底）
              if (xiaomiHighlight)
                Positioned(
                  left: 8,
                  right: 8,
                  top: 4,
                  bottom: 4,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          scheme.primary.withValues(alpha: 0.16),
                          scheme.primary.withValues(alpha: 0.1),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(
                        StyleTokens.controlRadiusOr(context, 16),
                      ),
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
                      color: isOn ? activeColor : softColor,
                    ),
                    const SizedBox(height: 2),
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: Theme.of(context).textTheme.labelSmall!.copyWith(
                        height: 1.1,
                        letterSpacing: 0.2,
                        fontWeight: isOn ? FontWeight.w600 : FontWeight.w500,
                        color: isOn ? activeColor : softColor,
                      ),
                      child: Text(label),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页内：漫画 / 动漫 / 小说 三合一（保活常驻）。
///
/// 受控组件：type 由外部（主壳侧栏/底栏）驱动，本组件不持有 IndexedStack，
/// 三页保活交给外层 [IndexedStack]（main_shell 的 tabs 列表），避免两套实例。
class MangaAnimeTabs extends StatefulWidget {
  final int type;
  final ValueChanged<int> onTypeChanged;
  const MangaAnimeTabs({
    super.key,
    required this.type,
    required this.onTypeChanged,
  });

  @override
  State<MangaAnimeTabs> createState() => MangaAnimeTabsState();
}

class MangaAnimeTabsState extends State<MangaAnimeTabs>
    with SingleTickerProviderStateMixin {
  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();
  final GlobalKey<AnimeHomePageState> _animeKey = GlobalKey<AnimeHomePageState>();
  final GlobalKey<NovelHomePageState> _novelKey = GlobalKey<NovelHomePageState>();

  /// 切 tab 的淡入动画。初值 1.0：冷启动不该有一次「整个内容区淡入」。
  late final AnimationController _tabAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1.0,
  );

  @override
  void didUpdateWidget(covariant MangaAnimeTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type) _tabAnim.forward(from: 0.0);
  }

  @override
  void dispose() {
    _tabAnim.dispose();
    super.dispose();
  }

  /// 刷新当前可见页（主壳 Ctrl+R 入口）。
  void refreshCurrent() {
    switch (widget.type) {
      case 0:
        _homeKey.currentState?.refresh();
        break;
      case 1:
        _animeKey.currentState?.refresh();
        break;
      case 2:
        _novelKey.currentState?.refresh();
        break;
    }
  }

  /// 三个子页只创建一次、常驻内存（外层 IndexedStack 保活），
  /// 切换 type 仅改变可见页，滚动位置与已加载列表数据不丢失。
  /// 各页 type 恒为自身下标（0/1/2），仅用于顶部 TypeSegment 的高亮态：
  /// 该页可见时即当前选中项，无需随 type 变化而重建。
  late final List<Widget> _pages = [
    HomePage(
      key: _homeKey,
      type: 0,
      onTypeChanged: widget.onTypeChanged,
    ),
    AnimeHomePage(
      key: _animeKey,
      type: 1,
      onTypeChanged: widget.onTypeChanged,
    ),
    NovelHomePage(
      key: _novelKey,
      type: 2,
      onTypeChanged: widget.onTypeChanged,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final idx = widget.type.clamp(0, _pages.length - 1);
    // 切 tab 时新页淡入。刻意不用 AnimatedSwitcher：它会在过渡期间同时挂载
    // 新旧两页，改变这里「只挂载可见页」的语义（另两页的 GlobalKey 状态与
    // 网络加载时机都会变）。FadeTransition 只加一层过渡，child 实例不变，
    // 不触发任何重新挂载。
    return FadeTransition(
      opacity: CurvedAnimation(parent: _tabAnim, curve: Curves.easeOut),
      child: _pages[idx],
    );
  }
}
