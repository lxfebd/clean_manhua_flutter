import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/novel_source.dart';
import '../sources/source_manager.dart';
import '../ui/novel_reader_page.dart';
import '../ui/widgets/cached_image.dart';

/// 小说详情页：封面/元信息 + 章节目录。章节点击进入阅读器。
class NovelDetailPage extends StatefulWidget {
  final String sourceId;
  final String novelId;
  final String? name;
  final String? pic;
  const NovelDetailPage(
      {super.key,
      required this.sourceId,
      required this.novelId,
      this.name,
      this.pic});

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  NovelDetail? _detail;
  bool _loading = true;
  String? _error;
  bool _saved = false;

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
      final d = await s.detail(widget.novelId).timeout(const Duration(seconds: 15));
      if (mounted) {
        _detail = d;
        _error = null;
      }
    } catch (e) {
      if (mounted) _error = '加载失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleSave() async {
    final s = SourceManager.novelById(widget.sourceId);
    if (s == null || _detail == null) return;
    HapticFeedback.lightImpact();
    await s.toggleBookshelf(_detail!);
    if (mounted) {
      setState(() => _saved = !_saved);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_saved ? '已加入书架' : '已移出书架'),
        duration: const Duration(seconds: 1),
      ));
    }
  }

  void _openChapter(NovelChapter ch) {
    HapticFeedback.selectionClick();
    final d = _detail!;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NovelReaderPage(
          sourceId: widget.sourceId,
          novelId: widget.novelId,
          chapterId: ch.id,
          title: ch.title,
          novelName: d.name,
          novelPic: d.pic ?? '',
          novelAuthor: d.author ?? d.comic.author ?? '',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              icon: Icon(_saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded),
              onPressed: _toggleSave,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_error!,
                          style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.6))),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: () {
                        setState(() => _loading = true);
                        _load();
                      }, child: const Text('重试')),
                    ],
                  ),
                )
              : _body(scheme),
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
                  child: CachedImage(d.pic ?? '', width: 96, height: 132, radius: 10),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text('作者：${d.author ?? d.comic.author ?? '未知'}',
                          style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.6))),
                      if (d.status != null)
                        Text('状态：${d.status}',
                            style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurface.withValues(alpha: 0.6))),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _toggleSave,
                        icon: Icon(_saved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded),
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
              child: Text(d.description!,
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.6,
                      color: scheme.onSurface.withValues(alpha: 0.8))),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('目录（${d.chapters.length} 章）',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface)),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) {
              final ch = d.chapters[i];
              return ListTile(
                dense: true,
                title: Text(ch.title,
                    style: TextStyle(fontSize: 14, color: scheme.onSurface)),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => _openChapter(ch),
              );
            },
            childCount: d.chapters.length,
          ),
        ),
      ],
    );
  }
}
