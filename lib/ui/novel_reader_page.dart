import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/local_store.dart';
import '../sources/novel_source.dart';
import '../sources/source_manager.dart';

/// 小说阅读器：渲染章节正文（段落列表），支持上下章导航与阅读进度记录。
class NovelReaderPage extends StatefulWidget {
  final String sourceId;
  final String novelId;
  final String chapterId;
  final String title;
  final String novelName;
  final String novelPic;
  final String novelAuthor;
  const NovelReaderPage({
    super.key,
    required this.sourceId,
    required this.novelId,
    required this.chapterId,
    required this.title,
    required this.novelName,
    required this.novelPic,
    required this.novelAuthor,
  });

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  NovelContent? _content;
  bool _loading = true;
  String? _error;
  String _curChapterId;

  _NovelReaderPageState() : _curChapterId = '';

  @override
  void initState() {
    super.initState();
    _curChapterId = widget.chapterId;
    _load(widget.chapterId);
  }

  Future<void> _load(String chapterId) async {
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
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final c = await s.chapterContent(chapterId).timeout(const Duration(seconds: 15));
      if (mounted) {
        _content = c;
        _curChapterId = chapterId;
        _error = null;
        _recordHistory(c.title);
      }
    } catch (e) {
      if (mounted) _error = '加载失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _recordHistory(String chapterTitle) {
    LocalStore.recordHistory(HistoryEntry(
      book: Bookmark(
        sourceId: widget.sourceId,
        comicId: widget.novelId,
        name: widget.novelName,
        pic: widget.novelPic,
        author: widget.novelAuthor,
      ),
      chapterId: _curChapterId,
      chapterTitle: chapterTitle,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  void _go(String? chapterId) {
    if (chapterId == null) return;
    HapticFeedback.lightImpact();
    _load(chapterId);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        title: Text(_content?.title ?? widget.title,
            style: const TextStyle(fontSize: 15)),
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
                      FilledButton(
                          onPressed: () {
                            setState(() => _loading = true);
                            _load(_curChapterId);
                          },
                          child: const Text('重试')),
                    ],
                  ),
                )
              : _reader(scheme),
      bottomNavigationBar: _content == null
          ? null
          : SafeArea(
              child: Container(
                color: scheme.surface,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _go(_content!.prevChapterId),
                        child: const Text('上一章'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _go(_content!.nextChapterId),
                        child: const Text('下一章'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _reader(scheme) {
    final paras = _content!.paragraphs;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: paras.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (ctx, i) => Text(
        paras[i],
        textAlign: TextAlign.justify,
        style: TextStyle(
          fontSize: 16.5,
          height: 1.85,
          color: scheme.onSurface.withValues(alpha: 0.92),
        ),
      ),
    );
  }
}
