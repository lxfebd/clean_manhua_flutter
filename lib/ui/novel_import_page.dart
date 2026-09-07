import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/local_novel_source.dart';
import 'novel_reader_page.dart';

/// 本地小说导入页：选择 TXT/EPUB 文件 → 解析（isolate）→ 入库 → 进入阅读。
class NovelImportPage extends StatefulWidget {
  const NovelImportPage({super.key});

  @override
  State<NovelImportPage> createState() => _NovelImportPageState();
}

class _NovelImportPageState extends State<NovelImportPage> {
  bool _busy = false;

  Future<void> _pickAndImport() async {
    if (_busy) return;
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择本地小说（TXT / EPUB）',
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final f = result.files.single;
      final name = f.name.toLowerCase();
      final isEpub = name.endsWith('.epub');
      final isTxt = name.endsWith('.txt');
      if (!isEpub && !isTxt) {
        _toast('仅支持 TXT / EPUB 文件');
        return;
      }
      setState(() => _busy = true);
      final raw = f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (raw == null) {
        _toast('读取文件失败');
        return;
      }
      final bytes = Uint8List.fromList(raw);
      // 书名可编辑：默认剥扩展名的文件名（EPUB 可用元数据书名）。
      final title = await _askTitle(f.name, isEpub);
      if (title == null) return; // 用户取消
      final bookId = isEpub
          ? await LocalNovelSource.importEpubBytes(bytes,
              overrideTitle: title)
          : await LocalNovelSource.importTxtBytes(bytes, f.name,
              overrideTitle: title);
      if (!mounted) return;
      _toast('导入成功');
      // 替换当前页，避免返回栈叠两层导入页。
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => NovelDetailPageLocal(bookId: bookId),
        ),
      );
    } catch (e) {
      if (mounted) _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  final TextEditingController _titleCtrl = TextEditingController();

  Future<String?> _askTitle(String fileName, bool isEpub) async {
    final defaultTitle = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    _titleCtrl.text = defaultTitle;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入本地小说'),
        content: TextField(
          controller: _titleCtrl,
          autofocus: true,
          maxLines: 1,
          decoration: InputDecoration(
            labelText: '书名',
            hintText: isEpub ? 'EPUB 元数据里的书名' : 'TXT 文件名',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _titleCtrl.text.trim()),
            child: const Text('开始导入'),
          ),
        ],
      ),
    );
    return result;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        title: const Text('本地导入', style: TextStyle(fontSize: 16)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.local_library_outlined,
                      size: 40, color: scheme.primary),
                ),
                const SizedBox(height: 18),
                Text('把本地小说导入书架',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
                const SizedBox(height: 10),
                Text(
                  '支持 TXT 与 EPUB 格式。'
                  'TXT 自动识别编码与章节标题（第X章/序章/楔子）；'
                  'EPUB 按目录（spine）顺序导入。解析在后台完成，大文件不卡界面。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: scheme.onSurface.withValues(alpha: 0.65)),
                ),
                const SizedBox(height: 26),
                FilledButton.icon(
                  onPressed: _busy ? null : _pickAndImport,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.file_open_outlined, size: 20),
                  label: Text(_busy ? '正在解析…' : '选择 TXT / EPUB 文件'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('返回'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
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

/// 本地书详情页：目录 + 删除（数据来自 LocalNovelStore）。
class NovelDetailPageLocal extends StatefulWidget {
  final String bookId;
  const NovelDetailPageLocal({super.key, required this.bookId});

  @override
  State<NovelDetailPageLocal> createState() => _NovelDetailPageLocalState();
}

class _NovelDetailPageLocalState extends State<NovelDetailPageLocal> {
  Map<String, dynamic>? _meta;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _meta = LocalNovelSource.store.metaOf(widget.bookId);
  }

  Future<void> _delete() async {
    if (_deleting) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除本地书'),
        content: const Text('删除后无法恢复，确定删除这本书吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _deleting = true);
    try {
      await LocalNovelSource.store.remove(widget.bookId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除'), duration: Duration(seconds: 1)));
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('删除失败：$e'), duration: Duration(seconds: 2)));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  void _openChapter(int seq) {
    final meta = _meta;
    if (meta == null) return;
    HapticFeedback.selectionClick();
    final chapters = (meta['chapters'] as List? ?? []);
    final title = seq < chapters.length
        ? ((chapters[seq] as Map)['title'] as String?) ?? ''
        : '';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NovelReaderPage(
          // 本地源已注册：阅读器完整复用（阅读设置/上下章/键盘翻页/历史）。
          sourceId: LocalNovelSource.sourceId,
          novelId: widget.bookId,
          chapterId: '${widget.bookId}|$seq',
          title: title,
          novelName: (meta['name'] as String?) ?? '',
          novelPic: '',
          novelAuthor: (meta['author'] as String?) ?? '',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = _meta;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        title: Text(meta?['name'] as String? ?? '本地书',
            style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: '删除本地书',
            icon: Icon(_deleting ? Icons.hourglass_empty : Icons.delete_outline,
                size: 20),
            onPressed: _deleting ? null : _delete,
          ),
        ],
      ),
      body: meta == null
          ? Center(
              child: Text('书已不存在',
                  style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.6))))
          : _body(scheme, meta),
    );
  }

  Widget _body(ColorScheme scheme, Map<String, dynamic> meta) {
    final chapters = (meta['chapters'] as List? ?? []);
    final author = (meta['author'] as String?) ?? '';
    final sourceName = (meta['sourceName'] as String?) ?? '本地';
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 96,
                height: 132,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.menu_book_rounded,
                    size: 40, color: scheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(meta['name'] as String? ?? '',
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('作者：${author.isEmpty ? '未知' : author}',
                        style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface.withValues(alpha: 0.6))),
                    const SizedBox(height: 4),
                    Text('来源：$sourceName · ${chapters.length} 章',
                        style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface.withValues(alpha: 0.6))),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('目录（${chapters.length} 章）',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface)),
        ),
        for (var i = 0; i < chapters.length; i++)
          ListTile(
            dense: true,
            title: Text(
                ((chapters[i] as Map)['title'] as String?) ?? '第 ${i + 1} 章',
                style: TextStyle(fontSize: 14, color: scheme.onSurface)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 18),
            onTap: () => _openChapter(i),
          ),
      ],
    );
  }
}