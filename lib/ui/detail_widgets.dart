part of 'detail_page.dart';

// ─── 沉浸式 Hero ────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final String sourceId;
  final String comicId;
  final String name;
  final String? pic;
  final String? status;
  const _Hero({
    required this.sourceId,
    required this.comicId,
    required this.name,
    required this.pic,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = context.uiStyle;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 详情页头图不用 Hero：来源列表（首页/书架/搜索等多处同款列表并存）里
        // 同一 tag 会出现多次，Hero 动画反而会触发「multiple heroes」崩溃。
        if (pic != null && pic!.isNotEmpty)
          CachedImage(pic!, fit: BoxFit.cover, radius: 0)
        else
          Container(color: scheme.surfaceContainerHighest),
        // 三段式渐变蒙版
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.18),
                Colors.black.withValues(alpha: 0.38),
                theme.scaffoldBackgroundColor.withValues(alpha: 0.0),
                theme.scaffoldBackgroundColor,
              ],
              stops: const [0, 0.35, 0.78, 1.0],
            ),
          ),
        ),
        // 底部恒暗黑衬：标题区白字在浅色主题/浅封面上也不隐身
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.72),
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.0),
                ],
                stops: const [0, 0.3, 0.58],
              ),
            ),
          ),
        ),
        // 标题区
        Positioned(
          left: 18,
          right: 18,
          bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeSlideIn(
                delay: const Duration(milliseconds: 80),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.secondary,
                        // 极简锁原值 5（StyleTokens.controlRadius 极简=8，与现状不匹配）；
                        // 小米 14 / 苹果 10 走 token。
                        borderRadius: BorderRadius.circular(
                          style == UIStyle.minimalist
                              ? 5
                              : R.of(R.control, style: context.uiStyle),
                        ),
                        // Minimalist：徽标扁平，不使用辉光。
                        boxShadow: const [],
                      ),
                      child: Text(
                        (status?.isNotEmpty == true) ? status! : '连载中',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        // 极简锁原值 6（StyleTokens.controlRadius 极简=8，与现状不匹配）；
                        // 小米 14 / 苹果 10 走 token。
                        borderRadius: BorderRadius.circular(
                          style == UIStyle.minimalist
                              ? 6
                              : R.of(R.control, style: context.uiStyle),
                        ),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        'COMIC',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              FadeSlideIn(
                delay: const Duration(milliseconds: 160),
                offset: 16,
                child: ShaderMask(
                  shaderCallback:
                      (rect) => const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Colors.white, Color(0xFFE8EAF0)],
                      ).createShader(rect),
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      height: 1.18,
                      letterSpacing: 0.3,
                      shadows: [Shadow(blurRadius: 12, color: Colors.black54)],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── 元数据条 ────────────────────────────────────────────────────────────────

class _MetaSection extends StatelessWidget {
  final ComicDetail detail;
  final bool saved;
  final VoidCallback? onRead;
  final VoidCallback onShelf;

  /// 非空 = 有上次阅读记录（按钮显示「继续阅读」）；null = 从第 1 话开始。
  final Chapter? resumeChapter;
  const _MetaSection({
    required this.detail,
    required this.saved,
    this.onRead,
    required this.onShelf,
    this.resumeChapter,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = detail;
    final style = context.uiStyle;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        14,
        Responsive.pagePadding(context),
        6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                // 极简锁原值 10（StyleTokens.controlRadius 极简=8，与现状不匹配）；
                // 小米 14 / 苹果 10 走 token。
                borderRadius: BorderRadius.circular(
                  style == UIStyle.minimalist
                      ? 10
                      : R.of(R.control, style: context.uiStyle),
                ),
                child: Container(
                  width: 104,
                  height: 148,
                  color: scheme.surfaceContainerHighest,
                  child:
                      (d.pic == null || d.pic!.isEmpty)
                          ? Icon(
                            Icons.image_outlined,
                            size: 32,
                            color: scheme.onSurface.withValues(alpha: 0.2),
                          )
                          : CachedImage(d.pic!, fit: BoxFit.cover, radius: 0),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if ((d.status ?? '').isNotEmpty)
                          _StatusPill(label: d.status!),
                        _CountPill(label: '${d.chapters.length} 话'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onRead,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(resumeChapter != null ? '继续阅读' : '开始阅读'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onShelf,
                  icon: Icon(
                    saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_outline_rounded,
                    size: 18,
                  ),
                  label: Text(saved ? '已在书架' : '加入书架'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 状态徽章（墨蓝底白字，如"连载中"）。
class _StatusPill extends StatelessWidget {
  final String label;
  const _StatusPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final style = context.uiStyle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        // 极简锁原值 5（StyleTokens.controlRadius 极简=8，与现状不匹配）；
        // 小米 14 / 苹果 10 走 token。
        borderRadius: BorderRadius.circular(
          style == UIStyle.minimalist
              ? 5
              : R.of(R.control, style: context.uiStyle),
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 计数徽章（黑 6% 底，黑 60% 字）。
class _CountPill extends StatelessWidget {
  final String label;
  const _CountPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        // 极简锁原值 5（StyleTokens.controlRadius 极简=8，与现状不匹配）；
        // 小米 14 / 苹果 10 走 token。
        borderRadius: BorderRadius.circular(
          style == UIStyle.minimalist
              ? 5
              : R.of(R.control, style: context.uiStyle),
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: scheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

// ─── 信息卡 ──────────────────────────────────────────────────────────────────

/// 详情元信息卡：把作者/地区/类型/状态/年份/更新时间/人气等从「一行合并」
/// 改成独立 标签:值 网格展示，源站抓到的字段逐项可读（详情精细化）。
class _MetaCard extends StatelessWidget {
  final ComicDetail detail;
  const _MetaCard({required this.detail});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    final d = detail;

    // 仅展示非空字段（值缺失的项不占位，避免空标签行）。
    final author = d.author ?? d.comic.author ?? '';
    final rows = <(String, String)>[
      if (author.isNotEmpty) ('作者', author),
      if ((d.area ?? '').isNotEmpty) ('地区', d.area!),
      if ((d.type ?? '').isNotEmpty) ('类型', d.type!),
      if ((d.status ?? '').isNotEmpty) ('状态', d.status!),
      if ((d.year ?? '').isNotEmpty) ('年份', d.year!),
      if ((d.updatedAt ?? '').isNotEmpty) ('更新', d.updatedAt!),
      if ((d.hits ?? '').isNotEmpty) ('人气', d.hits!),
      if ((d.comic.score ?? '').isNotEmpty) ('评分', d.comic.score!),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        8,
        Responsive.pagePadding(context),
        0,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(
            style == UIStyle.minimalist
                ? 10
                : R.of(R.control, style: context.uiStyle),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rows.isNotEmpty)
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  for (final (k, v) in rows)
                    _metaItem(context, scheme, k, v),
                ],
              ),
            if (d.tags.isNotEmpty) ...[
              if (rows.isNotEmpty) const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in d.tags) _tagChip(context, scheme, style, t),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metaItem(BuildContext context, ColorScheme scheme, String k, String v) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$k：',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        Text(
          v,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: scheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }

  Widget _tagChip(
      BuildContext context, ColorScheme scheme, UIStyle style, String t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(
          style == UIStyle.minimalist ? 6 : 999,
        ),
      ),
      child: Text(
        t,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: scheme.primary,
        ),
      ),
    );
  }
}

// ─── 简介卡 ──────────────────────────────────────────────────────────────────

class _DescCard extends StatefulWidget {
  final ComicDetail detail;
  const _DescCard({required this.detail});

  @override
  State<_DescCard> createState() => _DescCardState();
}

class _DescCardState extends State<_DescCard> {
  /// 长简介折叠：默认收起（>4 行时截断 + 显示「展开」），避免长介绍
  /// 把封面/章节列表挤出首屏；手动展开后保留展开态。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desc = widget.detail.description ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        10,
        Responsive.pagePadding(context),
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            desc,
            maxLines: _expanded ? null : 4,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              height: 1.75,
              color: scheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          if (desc.length > 120)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _expanded ? '收起' : '展开',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── 章节标题 ────────────────────────────────────────────────────────────────

class _ChapterHeader extends StatelessWidget {
  final int count;
  final bool descending;
  final VoidCallback onToggleDescending;
  final VoidCallback onTapAll;
  const _ChapterHeader({
    required this.count,
    this.descending = false,
    required this.onToggleDescending,
    required this.onTapAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        16,
        Responsive.pagePadding(context),
        10,
      ),
      child: SectionHeader(
        icon: Icons.menu_book_rounded,
        title: '章节',
        count: count,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: onTapAll,
              behavior: HitTestBehavior.opaque,
              child: Text(
                '全部 $count',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 14),
            GestureDetector(
              onTap: onToggleDescending,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Text(
                    descending ? '倒序' : '正序',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.primary),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    descending
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    size: 14,
                    color: scheme.primary,
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

// ─── 章节项 ──────────────────────────────────────────────────────────────────

class _ChapterTile extends StatefulWidget {
  final int index;
  final Chapter chapter;

  /// 已读标记：历史里存在该章节（章节列表「已读 ✓」角标）。
  final bool read;

  /// 续读标记：该章节是「开始阅读」解析出的最近阅读章节。
  final bool current;
  final VoidCallback onTap;
  const _ChapterTile({
    required this.index,
    required this.chapter,
    required this.read,
    required this.current,
    required this.onTap,
  });

  @override
  State<_ChapterTile> createState() => _ChapterTileState();
}

class _ChapterTileState extends State<_ChapterTile> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            if (widget.read) ...[
              Icon(
                Icons.check_circle_rounded,
                size: 15,
                color: scheme.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                widget.chapter.title.isEmpty
                    ? '第${widget.index + 1}话'
                    : widget.chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight:
                      widget.current ? FontWeight.w700 : FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (widget.current) ...[
              Text(
                '续读',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 4),
            ],
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 加载 & 错误态 ───────────────────────────────────────────────────────────

class _LoadingView extends StatefulWidget {
  const _LoadingView();

  @override
  State<_LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<_LoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final t = ((_c.value + i / 3) % 1.0);
              final opacity = (1.0 - (t - 0.5).abs() * 2).clamp(0.2, 1.0);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: opacity),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}


