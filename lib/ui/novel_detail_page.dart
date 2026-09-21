import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../ui/novel_reader_page.dart';
import '../ui/responsive.dart';
import '../ui/widgets/app_toast.dart';
import '../ui/widgets/cached_image.dart';
import '../ui/widgets/motion.dart';
import 'keyboard_shortcuts.dart';

/// 小说详情页：封面/元信息 + 章节目录。章节点击进入阅读器。
class NovelDetailPage extends StatefulWidget {
  final String sourceId;
  final String novelId;
  final String? name;
  final String? pic;
  const NovelDetailPage({
    super.key,
    required this.sourceId,
    required this.novelId,
    this.name,
    this.pic,
  });

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  NovelDetail? _detail;
  bool _loading = true;
  String? _error;
  bool _saved = false;
  bool _descExpanded = false; // 平板左侧窄面板长简介折叠
  bool _openingChapter = false; // 防连点：进入阅读器期间忽略重复点击

  @override
  void initState() {
    super.initState();
    _checkSaved();
    _load();
  }

  Future<void> _checkSaved() async {
    final s = SourceManager.novelById(widget.sourceId);
    if (s == null) return;
    final inShelf = await s.isInBookshelf(widget.novelId);
    if (mounted) {
      setState(() => _saved = inShelf);
    }
  }

  Future<void> _load() async {
    final s = SourceManager.novelById(widget.sourceId);
    if (s == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '未找到小说源';
        });
      }
      return;
    }
    try {
      final d = await s
          .detail(widget.novelId)
          .timeout(const Duration(seconds: 15));
      if (mounted) {
        _detail = d;
        _error = null;
      }
    } catch (e) {
      ErrorLogger.instance.warn('novel detail load failed: $e');
      if (mounted) _error = '加载失败，请检查网络后重试';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleSave() async {
    final s = SourceManager.novelById(widget.sourceId);
    if (s == null || _detail == null) return;
    HapticFeedback.lightImpact();
    try {
      await s.toggleBookshelf(_detail!);
    } catch (e) {
      // 写书架失败不翻转状态（磁盘与 UI 不失步）。
      ErrorLogger.instance.warn('novel toggle bookshelf failed: $e');
      if (mounted) {
        AppToast.error(context, '书架操作失败，请重试');
      }
      return;
    }
    if (mounted) {
      setState(() => _saved = !_saved);
      AppToast.info(
        context,
        _saved ? '已加入书架' : '已移出书架',
        duration: const Duration(seconds: 1),
      );
    }
  }

  void _openChapter(NovelChapter ch) async {
    // 防连点：history() await 期间重复点击会 push 多个阅读器。
    if (_openingChapter) return;
    _openingChapter = true;
    HapticFeedback.selectionClick();
    try {
      final d = _detail!;
      final hist = await LocalStore.history();
      final key =
          Bookmark(
            sourceId: widget.sourceId,
            comicId: widget.novelId,
            name: '',
            pic: '',
          ).key;
      // 倒序找最新一条：同一章节被多次记录时取最近一次位置。
      var scrollOffset = 0.0;
      for (final h in hist.reversed) {
        if (h.book.key == key && h.chapterId == ch.id) {
          scrollOffset = h.scrollOffset;
          break;
        }
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => NovelReaderPage(
                sourceId: widget.sourceId,
                novelId: widget.novelId,
                chapterId: ch.id,
                title: ch.title,
                novelName: d.name,
                novelPic: d.pic ?? '',
                novelAuthor: d.author ?? d.comic.author ?? '',
                initialOffset: scrollOffset,
              ),
        ),
      );
    } finally {
      _openingChapter = false;
    }
  }

  @override
  Widget build(BuildContext context) => EscPopScope(child: _buildRoot(context));

  Widget _buildRoot(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        title: Text(widget.name ?? _detail?.name ?? '小说详情'),
        actions: [
          if (_detail != null)
            IconButton(
              tooltip: _saved ? '移出书架' : '加入书架',
              icon: Icon(
                _saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              ),
              onPressed: _toggleSave,
            ),
        ],
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _error != null
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _error!,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        setState(() => _loading = true);
                        _load();
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
              : Responsive.isExpanded(context)
              ? _bodyTablet(scheme)
              : _body(scheme),
    );
  }

  Widget _bodyTablet(scheme) {
    final d = _detail!;
    final pad = Responsive.pagePadding(context);

    // 使用响应式左侧面板宽度
    final leftPanelWidth = Responsive.detailLeftWidth(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 左侧：封面 + 元信息（固定宽度） ──────────────
        Container(
          width: leftPanelWidth,
          // body 已在 AppBar 之下，不再叠加状态栏高度，避免顶部空洞错位。
          padding: EdgeInsets.fromLTRB(pad, 14, 8, 16),
          // 长描述在矮屏/平板竖屏时左侧会超出视口：整列可滚动，杜绝溢出。
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                // 封面保持 2:3 比例：固定 height:200 在宽面板下会把封面压扁变形。
                Center(
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedImage(
                        d.pic ?? '',
                        width: double.infinity,
                        height: 200,
                        radius: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  d.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '作者：${d.author ?? d.comic.author ?? '未知'}',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                if (d.status != null)
                  Text(
                    '状态：${d.status}',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _toggleSave,
                  icon: Icon(
                    _saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                  ),
                  label: Text(_saved ? '已在书架' : '加入书架'),
                ),
                if (d.description != null && d.description!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    d.description!,
                    maxLines: _descExpanded ? null : 4,
                    overflow: _descExpanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: scheme.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                  if (d.description!.length > 100)
                    GestureDetector(
                      onTap:
                          () => setState(() => _descExpanded = !_descExpanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _descExpanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        // ── 右侧：章节目录（可滚动） ─────────────────────
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(pad, 16, pad, 8),
                child: Text(
                  '目录（${d.chapters.length} 章）',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
                  itemCount: d.chapters.length,
                  itemBuilder: (ctx, i) {
                    final ch = d.chapters[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        ch.title,
                        style: TextStyle(fontSize: 14, color: scheme.onSurface),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                      ),
                      onTap: () => _openChapter(ch),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(scheme) {
    final d = _detail!;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedImage(
                    d.pic ?? '',
                    width: 96,
                    height: 132,
                    radius: 10,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '作者：${d.author ?? d.comic.author ?? '未知'}',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      if (d.status != null)
                        Text(
                          '状态：${d.status}',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _toggleSave,
                        icon: Icon(
                          _saved
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                        ),
                        label: Text(_saved ? '已在书架' : '加入书架'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (d.description != null && d.description!.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.description!,
                    maxLines: _descExpanded ? null : 4,
                    overflow: _descExpanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.6,
                      color: scheme.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                  if (d.description!.length > 100)
                    GestureDetector(
                      onTap:
                          () => setState(() => _descExpanded = !_descExpanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _descExpanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: FadeSlideIn(
            delay: const Duration(milliseconds: 200),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '目录（${d.chapters.length} 章）',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate((ctx, i) {
            final ch = d.chapters[i];
            return FadeSlideIn(
              delay: Duration(milliseconds: 250 + 30 * (i % 20)),
              child: ListTile(
                dense: true,
                title: Text(
                  ch.title,
                  style: TextStyle(fontSize: 14, color: scheme.onSurface),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => _openChapter(ch),
              ),
            );
          }, childCount: d.chapters.length),
        ),
      ],
    );
  }
}
