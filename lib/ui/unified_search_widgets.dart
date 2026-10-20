part of 'unified_search_page.dart';

class _SourceResultGroup extends StatelessWidget {
  final SourceResult result;
  final ValueChanged<ComicItem> onTap;
  final ValueChanged<ComicItem> onHover;
  final ComicItem? selected;
  final String? selectedSourceId;
  final bool compact;
  const _SourceResultGroup({
    required this.result,
    required this.onTap,
    required this.onHover,
    this.selected,
    this.selectedSourceId,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: SectionHeader(
            icon: result.isNovel
                ? Icons.menu_book_rounded
                : Icons.public_rounded,
            title: result.sourceName,
            count: result.items.length,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children:
              result.items
                  .map(
                    (item) => _UnifiedCard(
                      item: item,
                      sourceId: result.sourceId,
                      compact: compact,
                      selected:
                          selected?.id == item.id &&
                          selectedSourceId == result.sourceId,
                      onTap: () => onTap(item),
                      onHover: () => onHover(item),
                    ),
                  )
                  .toList(),
        ),
      ],
    );
  }
}

class _UnifiedCard extends StatefulWidget {
  final ComicItem item;
  final String sourceId;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final bool compact;
  final bool selected;
  const _UnifiedCard({
    required this.item,
    required this.sourceId,
    required this.onTap,
    required this.onHover,
    this.compact = false,
    this.selected = false,
  });

  @override
  State<_UnifiedCard> createState() => _UnifiedCardState();
}

class _UnifiedCardState extends State<_UnifiedCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.compact ? 104.0 : 112.0;
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hover = true);
        if (!widget.compact) widget.onHover();
      },
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform:
              Matrix4.identity()
                ..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
          width: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(R.card),
            // Minimalist：卡片无投影，悬停仅微位移反馈。
            boxShadow: const [],
            // 双栏模式：选中项用主题色描边标明当前预览对象。
            border:
                widget.selected
                    ? Border.all(color: scheme.primary, width: 2)
                    : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(R.card),
            child: Container(
              color: scheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: size,
                    height: size * 1.42,
                    child: CachedImage(
                      widget.item.pic,
                      fit: BoxFit.cover,
                      radius: 0,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
                    child: Text(
                      widget.item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 结果类型过滤小按钮：选中态主题色高亮，无对应类型结果时禁用置灰。
class _FilterChipBtn extends StatelessWidget {
  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  const _FilterChipBtn({
    required this.label,
    required this.active,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(R.control),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? scheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(R.control),
          border: Border.all(
            color: active
                ? scheme.primary.withValues(alpha: 0.6)
                : scheme.onSurface.withValues(alpha: 0.15),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: !enabled
                ? scheme.onSurface.withValues(alpha: 0.3)
                : active
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.75),
            fontWeight: active ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }
}
