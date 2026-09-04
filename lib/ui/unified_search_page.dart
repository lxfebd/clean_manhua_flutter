import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/comic_item.dart';
import '../sources/comic_source.dart';
import '../sources/source_manager.dart';
import 'detail_page.dart';
import 'responsive.dart';
import 'widgets/cached_image.dart';
import 'widgets/motion.dart';

/// 跨源统一搜索：输入关键词，并发搜索所有启用的漫画源，结果按源分组展示。
class UnifiedSearchPage extends StatefulWidget {
  final String keyword;
  const UnifiedSearchPage({super.key, required this.keyword});

  @override
  State<UnifiedSearchPage> createState() => _UnifiedSearchPageState();
}

class _UnifiedSearchPageState extends State<UnifiedSearchPage> {
  List<_SourceResult> _results = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.keyword;
    _search();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final kw = _searchCtrl.text.trim();
    if (kw.isEmpty) return;
    setState(() => _loading = true);
    try {
      final enabled = await SourceManager.enabledSources();
      final futures = <Future<List<ComicItem>>>[];
      for (final s in enabled) {
        futures.add(s.search(kw, 1).timeout(const Duration(seconds: 15)));
      }
      final all = await Future.wait(futures, eagerError: false);
      if (!mounted) return;
      final list = <_SourceResult>[];
      for (var i = 0; i < enabled.length; i++) {
        final items = all[i];
        if (items.isNotEmpty) {
          list.add(_SourceResult(source: enabled[i], items: items));
        }
      }
      setState(() {
        _results = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        // 整页限宽居中（M3 LS-U2）：搜索行与结果列表在桌面大屏不拉满全宽。
        // SizedBox.expand + Align 保证高度有界（Expanded 安全），宽度收口到 900dp。
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        Responsive.pagePadding(context), 10,
                        Responsive.pagePadding(context), 8),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.maybePop(context),
                          icon: Icon(
                              DesktopUi.isDesktopPlatform
                                  ? Icons.arrow_back_rounded
                                  : Icons.arrow_back_ios_new_rounded,
                              size: 18, color: scheme.onSurface),
                        ),
                        const SizedBox(width: 4),
                        // Flexible（loose）而非 Expanded（tight）：tight 约束会吞掉
                        // ConstrainedBox(maxWidth)，导致大屏搜索框仍被拉满全宽。
                        Flexible(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                                maxWidth: Responsive.fieldMaxWidth(context)),
                            child: SizedBox(
                              height: 40,
                              child: TextField(
                                controller: _searchCtrl,
                                textInputAction: TextInputAction.search,
                                onSubmitted: (_) => _search(),
                                style: TextStyle(
                                    fontSize: 14, color: scheme.onSurface),
                                decoration: InputDecoration(
                                  hintText: '搜索所有源…',
                                  hintStyle: TextStyle(
                                      fontSize: 13.5,
                                      color: scheme.onSurface
                                          .withValues(alpha: 0.4)),
                                  prefixIcon: Icon(Icons.search_rounded,
                                      size: 20,
                                      color: scheme.primary),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 10),
                                  border: InputBorder.none,
                                  filled: true,
                                  fillColor: scheme.surface,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _search,
                          child: const Text('搜索'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: _buildBody(scheme)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.08),
              ),
              child: Icon(Icons.search_off_rounded,
                  size: 40, color: scheme.primary),
            ),
            const SizedBox(height: 12),
            Text('没有找到相关结果',
                style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurface.withValues(alpha: 0.6))),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 4,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
      itemCount: _results.length,
      itemBuilder: (_, i) => _SourceResultGroup(
        result: _results[i],
        onTap: (item) => _openDetail(_results[i].source, item),
      ),
    );
  }

  void _openDetail(ComicSource source, ComicItem item) {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          sourceId: source.id,
          comicId: item.id,
          name: item.name,
          pic: item.pic,
        ),
      ),
    );
  }
}

class _SourceResult {
  final ComicSource source;
  final List<ComicItem> items;
  const _SourceResult({required this.source, required this.items});
}

class _SourceResultGroup extends StatelessWidget {
  final _SourceResult result;
  final ValueChanged<ComicItem> onTap;
  const _SourceResultGroup({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: SectionHeader(
            icon: Icons.public_rounded,
            title: result.source.name,
            count: result.items.length,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: result.items.map((item) => _UnifiedCard(
            item: item,
            sourceId: result.source.id,
            onTap: () => onTap(item),
          )).toList(),
        ),
      ],
    );
  }
}

class _UnifiedCard extends StatefulWidget {
  final ComicItem item;
  final String sourceId;
  final VoidCallback onTap;
  const _UnifiedCard({required this.item, required this.sourceId, required this.onTap});

  @override
  State<_UnifiedCard> createState() => _UnifiedCardState();
}

class _UnifiedCardState extends State<_UnifiedCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.97,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()..translateByDouble(0.0, _hover ? -4 : 0, 0.0, 1.0),
          width: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            // Minimalist：卡片无投影，悬停仅微位移反馈。
            boxShadow: const [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: scheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 104,
                    height: 148,
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
                      style: TextStyle(
                        fontSize: 11,
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