part of 'home_page.dart';

class _SourceSwitchButton extends StatelessWidget {
  final String sourceName;
  final VoidCallback onTap;
  const _SourceSwitchButton({required this.sourceName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return HoverEffect(
      onTap: onTap,
      opacity: 0.92,
      child: PressableScale(
        onTap: onTap,
        scale: 0.95,
        // 命中区 ≥44×44：内容高度约 36，TapTargetMin 放手势组件内部，
        // 把手势盒子撑到 44（HoverEffect 热区跟随 child）。
        child: TapTargetMin(
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(R.pill),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.22),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(R.control),
                  ),
                  child: Icon(Icons.public_rounded,
                      size: 14, color: scheme.onPrimary),
                ),
                const SizedBox(width: 6),
                Text(
                  sourceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.keyboard_arrow_down_rounded,
                    size: 16, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSubmit;

  /// 跨源全量搜索（suffixIcon 入口）。
  final ValueChanged<String>? onSearchAll;
  const _SearchBar({required this.controller, required this.onSubmit, this.onSearchAll});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 风格化：搜索框圆角走 controlRadius 语义槽；极简锁原 R.card=12（回归面为零）。
    final searchRadius = context.uiStyle == UIStyle.minimalist
        ? R.card
        : R.of(R.control, style: context.uiStyle);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(searchRadius),
        border: Border.all(
          color: _focused
              ? T.color(scheme.onSurface, TextTier.low,
                  brightness: scheme.brightness)
              : scheme.outline,
          width: 1,
        ),
      ),
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        child: TextField(
          controller: widget.controller,
          textInputAction: TextInputAction.search,
          onSubmitted: widget.onSubmit,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
              ),
          decoration: InputDecoration(
            hintText: '搜索漫画、动漫、小说…',
            hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 20,
              color: _focused
                  ? scheme.primary
                  : T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
            ),
            suffixIcon: widget.controller.text.isNotEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onSearchAll != null)
                        IconButton(
                          tooltip: '全源搜索',
                          icon: Icon(Icons.public_rounded, size: 17, color: scheme.primary),
                          onPressed: () {
                            final kw = widget.controller.text.trim();
                            if (kw.isNotEmpty) widget.onSearchAll!(kw);
                          },
                        ),
                      IconButton(
                        tooltip: '清空',
                        icon: Icon(Icons.close_rounded,
                            size: 18,
                            color: T.color(scheme.onSurface, TextTier.low,
                                brightness: scheme.brightness)),
                        onPressed: () {
                          widget.controller.clear();
                          setState(() {});
                        },
                      ),
                    ],
                  )
                : null,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 分类胶囊
// ─────────────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      // 命中区 ≥44×44：胶囊视觉高度 32，TapTargetMin 放手势组件内部作 child，
      // 才能把手势盒子撑到 44（外层 Padding 只负责胶囊间横向间距）。
      child: PressableScale(
        onTap: onTap,
        scale: 0.94,
        focusable: true, // TV 遥控器 D-pad 焦点导航
        child: TapTargetMin(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // 选中态用 primary 底 + onPrimary 字：明暗两套主题都自动满足对比度。
              // （旧实现 onSurface 底 + 写死 Colors.white 字，暗色下对比度仅 1.20）
              // 分类胶囊圆角：极简锁原 R.pill（胶囊全圆），小米/苹果走风格档位。
              // 尺寸/padding 44dp 热区完全不动。
              color: active ? scheme.primary : scheme.surface,
              borderRadius: BorderRadius.circular(
                  context.uiStyle == UIStyle.minimalist
                      ? R.pill
                      : R.of(R.control, style: context.uiStyle)),
              border: Border.all(
                color: active
                    ? Colors.transparent
                    : scheme.onSurface.withValues(alpha: 0.12),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 13,
                    color: active
                        ? scheme.onPrimary
                        : T.color(scheme.onSurface, TextTier.low,
                            brightness: scheme.brightness),
                  ),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w500,
                        color: active
                            ? scheme.onPrimary
                            : T.color(scheme.onSurface, TextTier.mid,
                                brightness: scheme.brightness),
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 顶部精选横幅（横向轮播）
// ─────────────────────────────────────────────────────────────────────────────

class _FeaturedBanner extends StatefulWidget {
  final List<ComicItem> items;
  const _FeaturedBanner({required this.items});

  @override
  State<_FeaturedBanner> createState() => _FeaturedBannerState();
}

class _FeaturedBannerState extends State<_FeaturedBanner> {
  PageController? _ctrl;
  int _page = 0;
  /// 详情页 push 防连点锁（独立于网格卡的锁：Banner 无原生 Navigator 流程，
  /// 手推 MaterialPageRoute，返回后释放）。
  bool _openingDetail = false;

  @override
  void initState() {
    super.initState();
    // 注意：不能在 initState 里读 MediaQuery/Responsive（dependOnInheritedWidget
    // 在 initState 未完成前调用会抛异常 → 真机首页红屏）。在 didChangeDependencies
    // 里初始化并按尺寸类重建控制器。
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 平板视口更宽，横幅更大更有冲击力
    final fraction = Responsive.isTablet(context) ? 0.7 : 0.86;
    if (_ctrl == null) {
      _ctrl = PageController(viewportFraction: fraction);
    } else if (_ctrl!.viewportFraction != fraction) {
      // 尺寸类变化（如横屏/竖屏切换）时重建，避免 viewportFraction 失效
      _ctrl!.dispose();
      _ctrl = PageController(viewportFraction: fraction);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context), 6,
              Responsive.pagePadding(context), 10),
          child: SectionHeader(
            icon: Icons.auto_awesome_rounded,
            title: '本周精选',
            trailing: Text(
              '${_page + 1}/${widget.items.length}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: T.color(scheme.onSurface, TextTier.disabled,
                        brightness: scheme.brightness),
                  ),
            ),
          ),
        ),
        SizedBox(
          // 横幅高度随断点阶梯化：单张卡宽随 viewportFraction 放大后，
          // 若高度固定 240 会在 1600dp+ 屏上过于扁平、封面裁切严重。
          // 桌面端保持 240，不抢屏（浏览器首页横幅普遍 220~260）。
          height: DesktopUi.isDesktopPlatform
              ? 240
              : (Responsive.isLarge(context)
                  ? 300
                  : (Responsive.isExpanded(context)
                      ? 260
                      : (Responsive.isTablet(context) ? 240 : 176))),
          child: PageView.builder(
            controller: _ctrl!,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) {
              final it = widget.items[i];
              return AnimatedBuilder(
                animation: _ctrl!,
                builder: (c, child) {
                  double scale = 1.0;
                  double opacity = 1.0;
                  if (_ctrl!.position.haveDimensions) {
                    final cur = _ctrl!.page ?? 0;
                    final diff = (cur - i).abs();
                    scale = (1 - diff * 0.07).clamp(0.88, 1.0);
                    opacity = (1 - diff * 0.25).clamp(0.7, 1.0);
                  }
                  return Transform.scale(
                    scale: scale,
                    child: Opacity(opacity: opacity, child: child),
                  );
                },
                child: _FeaturedCard(
                  item: it,
                  sourceId: SourceManager.current.id,
                  onTap: () {
                    if (_openingDetail) return; // 防连点：push 动画期间忽略重复点击
                    _openingDetail = true;
                    HapticFeedback.selectionClick();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DetailPage(
                          sourceId: SourceManager.current.id,
                          comicId: it.id,
                          name: it.name,
                          pic: it.pic,
                        ),
                      ),
                    ).whenComplete(() {
                      _openingDetail = false; // 返回后释放锁
                    });
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // 分页指示
        Center(
          child: AnimatedSmoothIndicator(
            activeIndex: _page,
            count: widget.items.length,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  final ComicItem item;
  final String sourceId;
  final VoidCallback onTap;
  const _FeaturedCard({required this.item, required this.sourceId, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: PressableScale(
        onTap: onTap,
        scale: 0.98,
        focusable: true, // TV 遥控器 D-pad 焦点导航（轮播大卡）
        child: ClipRRect(
          // 全宽大图只改圆角（视觉风险小），渐变/Squircle 改造成本高不动。
          // 轮播是全宽大卡 → hero 槽位：极简锁原值 12，小米 28 / 苹果 16。
          borderRadius: BorderRadius.circular(StyleTokens.heroRadius(context, 12)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 轮播卡不用 Hero：同一作品也会出现在下方热榜网格里，
              // 共用 tag 会触发「multiple heroes share the same tag」。
              CachedImage(
                item.pic,
                fit: BoxFit.cover,
                radius: 0,
              ),
              // 暗色渐变：对角 + 底部两道，保证标题永远落在深色衬上，
              // 避免亮色封面把白字"吃掉"（底部渐变到 55% 处仍保留 0.72 黑度）。
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomLeft,
                      end: Alignment.topRight,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.6],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.78),
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.28, 0.55],
                    ),
                  ),
                ),
              ),
              // 信息
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.secondary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '精选',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 1,
                            ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            height: 1.25,
                            color: Colors.white,
                            shadows: const [
                              Shadow(blurRadius: 8, color: Colors.black54),
                            ],
                          ),
                    ),
                    if ((item.author ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.author!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: Colors.white70),
                        ),
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

/// 简洁分页指示器
class AnimatedSmoothIndicator extends StatelessWidget {
  final int activeIndex;
  final int count;
  final Color color;
  const AnimatedSmoothIndicator({
    super.key,
    required this.activeIndex,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            width: i == activeIndex ? 18 : 5,
            height: 5,
            decoration: BoxDecoration(
              color: i == activeIndex
                  ? color
                  : scheme.onSurface.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 漫画卡片（错峰入场）
// ─────────────────────────────────────────────────────────────────────────────

class _ComicCard extends StatefulWidget {
  final ComicItem item;
  final String sourceId;
  final VoidCallback onTap;
  const _ComicCard({required this.item, required this.sourceId, required this.onTap});

  @override
  State<_ComicCard> createState() => _ComicCardState();
}

class _ComicCardState extends State<_ComicCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    final cardR = R.of(R.card, style: context.uiStyle);
    // 三套风格差异化（仅在装饰层按风格分支，尺寸/padding/热区一律不动）：
    //   minimalist：与既有实现逐字节一致（surface 底 + 圆角 + 无阴影）。
    //   xiaomi：内容底改品牌渐变 + SquircleClipper 剪裁（HyperOS 特征）。
    //   apple：surface 底 + StyleTokens.cardBorder 细分隔线。
    // hover 位移 -4 三风格通用保留（交互语义，非风格视觉）。
    final Widget cardContent;
    if (style == UIStyle.xiaomi) {
      // 小米：内容底改品牌渐变 + SquircleClipper 剪裁（decoration.gradient
      // 承接 Gradient 类型；不用 color 走 Color 通道，避免类型冲突）。
      cardContent = ClipPath(
        clipper: SquircleClipper(radius: cardR),
        child: Container(
          color: scheme.surface,
          decoration: BoxDecoration(
            gradient: StyleTokens.cardGradient(context),
          ),
          child: _body(context),
        ),
      );
    } else if (style == UIStyle.apple) {
      cardContent = ClipRRect(
        borderRadius: BorderRadius.circular(cardR),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border.fromBorderSide(StyleTokens.cardBorder(context)!),
          ),
          child: _body(context),
        ),
      );
    } else {
      // minimalist：保持原实现（外层装饰圆角 + 内层 ClipRRect + surface 底）。
      cardContent = ClipRRect(
        borderRadius: BorderRadius.circular(cardR),
        child: Container(
          color: scheme.surface,
          child: _body(context),
        ),
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        focusable: true, // TV 遥控器 D-pad 焦点导航（热榜网格卡）
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(cardR),
            // Minimalist：卡片不使用投影，悬停仅以微位移反馈。
            boxShadow: const [],
          ),
          child: cardContent,
        ),
      ),
    );
  }

  /// 卡片内容体（封面 + 作者/更新角标 + 标题）：三风格共用，仅装饰层分支。
  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                // 网格卡不用 Hero：同一作品会出现在多个 tab 的同款列表中
                // （首页/漫画 tab 都是 HomePage 实例，IndexedStack 同时保活
                // 所有 tab），同 tag 会触发「multiple heroes share the same tag」。
                child: CachedImage(
                  widget.item.pic,
                  fit: BoxFit.cover,
                  radius: 0,
                ),
              ),
              if ((widget.item.author ?? '').isNotEmpty)
                Positioned(
                  top: 6,
                  left: 6,
                  right: 6,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 100),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.item.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              // 更新/完结状态角标（如"更新至第19集"/"全12集"）
              if ((widget.item.remarks ?? '').isNotEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 84),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.item.remarks!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 8.5,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: Text(
            widget.item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 数据源切换底部弹窗
// ─────────────────────────────────────────────────────────────────────────────

class _SourceSwitchSheet extends StatelessWidget {
  final List<ComicSource> sources;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  const _SourceSwitchSheet({
    required this.sources,
    required this.currentIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.sheet),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              '切换数据源',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
            ),
            const SizedBox(height: 10),
            Flexible(
              // 源数量多时在弹窗内滚动，保证底部源不被导航手势区裁剪。
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: sources.length,
                itemBuilder: (context, i) => FadeSlideIn(
                  delay: Duration(milliseconds: 40 * i),
                  offset: 8,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(
                        StyleTokens.cardRadiusOr(context, 12)),
                    onTap: () => onSelected(i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: i == currentIndex
                            ? scheme.primary.withValues(alpha: 0.10)
                            : scheme.surfaceContainerHighest
                                .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(
                            StyleTokens.cardRadiusOr(context, 12)),
                        border: Border.all(
                          color: i == currentIndex
                              ? scheme.primary.withValues(alpha: 0.5)
                              : T.color(scheme.onSurface, TextTier.hairline,
                                  brightness: scheme.brightness),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            i == currentIndex
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 18,
                            color: i == currentIndex
                                ? scheme.primary
                                : scheme.onSurface.withValues(alpha: 0.4),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              sources[i].name,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface,
                                  ),
                            ),
                          ),
                          Icon(
                            Icons.public_rounded,
                            size: 13,
                            color: scheme.onSurface.withValues(alpha: 0.3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                '可前往「工具 → 数据源管理」调整各源域名/启用状态',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: T.color(scheme.onSurface, TextTier.disabled,
                          brightness: scheme.brightness),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 首页滚动收起头部 delegate
// ─────────────────────────────────────────────────────────────────────────────

/// 首页头部的折叠委托已收敛为 shared [HomeHeaderDelegate]（widgets/home_header.dart），
/// anime_home_page 同用一份。

// ─────────────────────────────────────────────────────────────────────────────
// 加载 & 错误态
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return StateView(
      kind: StateViewKind.error,
      message: message,
      onRetry: onRetry,
      icon: Icons.cloud_off_outlined,
    );
  }
}

/// 无结果空态（搜索/分类无内容时展示，避免一直转圈）。
class _EmptyState extends StatelessWidget {
  final String mode;

  /// 本次搜索关键词：空态进入全源搜索时沿用（可为空则用原关键词）。
  final String keyword;

  /// 刷新回调（rank/分类空态的主行动按钮）。
  final VoidCallback onRefresh;

  /// 跨源全量搜索回调（仅搜索空态展示，为 null 时隐藏）。
  final ValueChanged<String>? onSearchAll;

  const _EmptyState({
    required this.mode,
    this.keyword = '',
    required this.onRefresh,
    this.onSearchAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSearch = mode == 'search';
    final isRank = mode == 'rank';
    final text = isSearch
        ? '没有找到相关结果'
        : isRank
            ? '排行榜暂无内容'
            : '该分类暂时没有内容';
    final subtitle = isSearch
        ? '换个关键词试试，也可以直接去全源搜索'
        : isRank
            ? '下拉刷新试试，精彩内容持续更新中'
            : '换个分类看看，精彩内容持续更新中';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.08),
            ),
            child: Icon(Icons.search_off_rounded, size: 44, color: scheme.primary),
          ),
          const SizedBox(height: 14),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: T.color(scheme.onSurface, TextTier.low,
                      brightness: scheme.brightness),
                ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: T.color(scheme.onSurface, TextTier.disabled,
                      brightness: scheme.brightness),
                ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              if (isSearch && onSearchAll != null) {
                onSearchAll!(keyword.trim());
              } else {
                onRefresh();
              }
            },
            icon: Icon(isSearch ? Icons.public_rounded : Icons.refresh_rounded,
                size: 18),
            label: Text(isSearch ? '全源搜索' : '刷新'),
          ),
        ],
      ),
    );
  }
}
// _TypeSegment 已移至 responsive.dart 作为共享组件 TypeSegment

/// 猜你喜欢：横向滑动封面列表（自「我的」页迁移至首页推荐流）。
class _RecommendCard extends StatelessWidget {
  final List<RecommendItem> items;
  final ValueChanged<RecommendItem> onOpen;
  const _RecommendCard({required this.items, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) return const SizedBox.shrink();
    // 风格化（横向大卡内的小封面卡）：
    //   minimalist：直接 StyleTokens.cardRadius，无渐变无描边。
    //   xiaomi：SquircleClipper + 渐变底（超椭圆剪裁 + 品牌渐变）。
    //   apple：surface 底 + cardBorder 细分隔线。
    // 布局尺寸（96x128 封面、10 间距、156 行高）保持原值不变。
    final style = context.uiStyle;
    final cardR = R.of(R.card, style: context.uiStyle);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '猜你喜欢',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            '基于本地阅读历史的纯本地推荐，不上传任何数据',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
          ),
          const SizedBox(height: 10),
          // 128 封面 + 4 间距 + 1 行标题：156 在桌面真实字体（微软雅黑/Segoe UI）
          // 行高 ~24px 时恰好顶满，个别字号/缩放会溢出 2px 黄条；留足到 160。
          SizedBox(
            height: 160,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final r = items[i];
                final Widget coverImage;
                if (style == UIStyle.xiaomi) {
                  coverImage = ClipPath(
                    clipper: SquircleClipper(radius: cardR),
                    child: Container(
                      color: scheme.surface,
                      decoration: BoxDecoration(
                        gradient: StyleTokens.cardGradient(context),
                      ),
                      child: CachedImage(
                        r.item.pic,
                        width: 96,
                        height: 128,
                        fit: BoxFit.cover,
                        radius: 0,
                      ),
                    ),
                  );
                } else if (style == UIStyle.apple) {
                  coverImage = ClipRRect(
                    borderRadius: BorderRadius.circular(cardR),
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        border:
                            Border.fromBorderSide(StyleTokens.cardBorder(context)!),
                      ),
                      child: CachedImage(
                        r.item.pic,
                        width: 96,
                        height: 128,
                        fit: BoxFit.cover,
                        radius: 0,
                      ),
                    ),
                  );
                } else {
                  coverImage = ClipRRect(
                    borderRadius: BorderRadius.circular(cardR),
                    child: CachedImage(
                      r.item.pic,
                      width: 96,
                      height: 128,
                      fit: BoxFit.cover,
                      radius: 0,
                    ),
                  );
                }
                return SizedBox(
                  width: 96,
                  child: GestureDetector(
                    onTap: () => onOpen(r),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        coverImage,
                        const SizedBox(height: 4),
                        Text(
                          r.item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurface,
                              ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
