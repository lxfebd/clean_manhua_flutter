part of 'anime_home_page.dart';

class _AnimeCard extends StatefulWidget {
  final ComicItem item;
  final VoidCallback onTap;
  /// 详情请求期间置 true：卡片覆盖半透明 spinner，提供点击反馈。
  final bool loading;

  /// 该番剧已看集数（无观看记录为 null，不标角标）。
  final int? watchedEpisodes;
  const _AnimeCard({
    required this.item,
    required this.onTap,
    this.loading = false,
    this.watchedEpisodes,
  });

  @override
  State<_AnimeCard> createState() => _AnimeCardState();
}

class _AnimeCardState extends State<_AnimeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.uiStyle;
    final cardR = R.of(R.card, style: context.uiStyle);
    // 极简锁原值：原版本无描边；仅小米/苹果走 StyleTokens（小米无、苹果细分隔线）。
    final cardBorder = style == UIStyle.minimalist
        ? null
        : StyleTokens.cardBorder(context);
    final cardShadows = StyleTokens.cardShadow(context);
    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
      decoration: BoxDecoration(
        borderRadius: style == UIStyle.xiaomi ? null : BorderRadius.circular(cardR),
        // Minimalist：卡片无投影，悬停仅微位移反馈。
        border: cardBorder == null
            ? null
            : Border.all(color: cardBorder.color, width: cardBorder.width),
        boxShadow: cardShadows ?? const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cardR),
        child: Container(
          // 小米渐变底色由外层 ClipPath 包裹提供，此处透明以免盖住渐变。
          color: style == UIStyle.xiaomi ? Colors.transparent : scheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      // 无封面源（如 Anime1 纯文本站）用首字占位封面，避免千篇一律的空占位图
                      child: widget.item.pic.isEmpty
                          ? _LetterCover(
                              title: widget.item.name,
                              scheme: scheme,
                              remark: widget.item.remarks)
                          : CachedImage(widget.item.pic,
                              fit: BoxFit.cover,
                              radius: 0,
                              fallbackUrls: [
                                if (widget.item.picFallback?.isNotEmpty ?? false)
                                  widget.item.picFallback!,
                              ]),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 32,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.55),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.secondary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '动漫',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    if (widget.item.score != null &&
                        widget.item.score!.isNotEmpty &&
                        widget.item.score != '0')
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star_rounded,
                                  size: 10, color: Colors.amber),
                              const SizedBox(width: 2),
                              Text(
                                widget.item.score!,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.amber,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (widget.watchedEpisodes != null)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '已看 ${widget.watchedEpisodes} 集',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    if (widget.item.remarks != null &&
                        widget.item.remarks!.isNotEmpty)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.78),
                                Colors.transparent,
                              ],
                            ),
                          ),
                          child: Text(
                            widget.item.remarks!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: _hover ? 48 : 36,
                        height: _hover ? 48 : 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.secondary.withValues(alpha: _hover ? 0.9 : 0.7),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                    if (widget.loading)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.45),
                          child: const Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
                child: Text(
                  widget.item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 小米：超椭圆剪裁 + 品牌渐变底色包（渐变铺在底色之下，内容照常叠放）。
    if (style == UIStyle.xiaomi) {
      final gradient = StyleTokens.cardGradient(context);
      if (gradient != null) {
        card = ClipPath(
          clipper: SquircleClipper(radius: cardR),
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: gradient),
            child: card,
          ),
        );
      }
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        focusable: true, // TV 遥控器 D-pad 焦点导航（动漫网格卡）
        child: card,
      ),
    );
  }
}

class _LetterCover extends StatelessWidget {
  final String title;
  final ColorScheme scheme;
  /// 更新/完结状态提示（如"更新至第19集"），无封面时展示更友好
  final String? remark;
  const _LetterCover({required this.title, required this.scheme, this.remark});

  @override
  Widget build(BuildContext context) {
    final t = title.trim();
    final letter = t.isEmpty ? '?' : t.characters.first.toUpperCase();
    const palette = [
      Color(0xFF5B7FFF), Color(0xFF4FC3A1), Color(0xFFEF6C6C),
      Color(0xFFF2A65A), Color(0xFF8E7CF5), Color(0xFF3FA7D6),
      Color(0xFFE06FB4), Color(0xFF6FA86F),
    ];
    var hash = 0;
    for (final c in t.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    final bg = palette[hash % palette.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bg.withValues(alpha: 0.95), bg.withValues(alpha: 0.6)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 大首字水印（轻透明白）
          Positioned(
            top: 6,
            left: 10,
            child: Text(
              letter,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: 0.22),
              ),
            ),
          ),
          // 底部：完整标题 + 更新备注，让无封面卡片也有作品标识
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 6),
                    ],
                  ),
                ),
                if (remark != null && remark!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      remark!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 动漫页滚动收起头部：委托已收敛为 shared [HomeHeaderDelegate]
// （widgets/home_header.dart），与 home_page 同用一份。
