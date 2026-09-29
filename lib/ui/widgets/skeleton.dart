import 'package:flutter/material.dart';

import '../responsive.dart';
import '../tokens.dart';

/// 骨架屏：首屏加载时占位最终内容的灰块 + 呼吸动画（不引入第三方包）。
///
/// - [SkeletonBox]：纯灰块，底色 onSurface 6%，圆角复用 [R.card]。
/// - [SkeletonPulse]：一个呼吸包装器驱动一个 [AnimationController]，
///   约 900ms 往返循环，透明度在 6% 与 11% 之间循环。
///
/// 两个组件都不含任何手势处理（骨架屏不应引入可点控件）。

/// 静态灰块：底色 `onSurface.withValues(alpha: 0.06)`，圆角 [R.card]。
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final double radius;

  const SkeletonBox({super.key, this.width, this.height, this.radius = R.card});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 呼吸包装器：一个 controller 驱动一份呼吸。
///
/// 灰块底色固定 onSurface 6%，呼吸表现为整体 Opacity 在 1.0 ↔ 0.45
/// 之间往返（峰值透明度 = base × 0.45 ≈ 0.027），只复用 [T] 档位
/// 计算峰值，不引入新的 alpha 字面量。
class SkeletonPulse extends StatefulWidget {
  final Widget child;
  final Duration period;

  const SkeletonPulse({
    super.key,
    required this.child,
    this.period = const Duration(milliseconds: 900),
  });

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat(reverse: true);

  @override
  void didUpdateWidget(covariant SkeletonPulse old) {
    super.didUpdateWidget(old);
    if (old.period != widget.period) {
      _c.duration = widget.period;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = T.alphaFor(TextTier.fill, scheme.brightness);
    final peak = T.alphaFor(TextTier.disabled, scheme.brightness) * base;
    final alpha = Tween<double>(begin: base, end: peak).evaluate(_c);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: alpha / base,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// 单张卡片骨架：封面灰块（Expanded）+ 标题灰块（等高），
/// 与 `_ComicCard` / `_AnimeCard` 的纵向结构同构。
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const SkeletonPulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: SkeletonBox()),
          Padding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, 10),
            child: SkeletonBox(height: 12, radius: R.control),
          ),
        ],
      ),
    );
  }
}

/// 首页网格骨架屏：与真实内容网格同构。
///
/// - 列数 [Responsive.comicGridColumns]、间距 [Responsive.gridSpacing]、
///   childAspectRatio 桌面 0.72 否则 0.62（与首页/动漫首页网格参数一致）。
/// - [showRankBanner] 为 true 时在网格前追加一个横幅灰块区，
///   模拟 rank 模式下顶部精选横幅。
/// - 网格用 [ClipRRect] 收口圆角，避免卡片间轻微重叠（与真实卡片
///   `ClipRRect(borderRadius: R.card)` 保持一致）。
class HomeGridSkeleton extends StatelessWidget {
  final bool showRankBanner;

  const HomeGridSkeleton({super.key, this.showRankBanner = false});

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: [
        if (showRankBanner) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  Responsive.pagePadding(context), 0,
                  Responsive.pagePadding(context), 16),
              child: const SizedBox(
                height: 200,
                child: SkeletonBox(radius: R.hero),
              ),
            ),
          ),
        ],
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            Responsive.pagePadding(context),
            6,
            Responsive.pagePadding(context),
            12,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: Responsive.comicGridColumns(context),
              mainAxisSpacing: Responsive.gridSpacing(context),
              crossAxisSpacing: Responsive.gridSpacing(context),
              childAspectRatio: isDesktop ? 0.72 : 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, __) => const ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(R.card)),
                child: SkeletonCard(),
              ),
              childCount: Responsive.comicGridColumns(context) * 2,
            ),
          ),
        ),
      ],
    );
  }
}
