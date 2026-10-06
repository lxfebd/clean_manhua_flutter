import 'package:flutter/material.dart';

import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/video_download_manager.dart';
import '../sources/video_source.dart';
import 'anime_player_page.dart' show animePlayerWebChannel;
import 'episode_batch_download_sheet.dart';
import 'episode_grouping.dart';
import 'native_player_page.dart';
import 'responsive.dart';
import 'widgets/app_toast.dart';

/// 选集过滤纯函数（选集搜索框用；独立便于单元测试）。
/// [filter] 按剧集标题模糊匹配，也支持直接输集数（如「12」匹配第 12 集）；
/// 空 = 原列表原样。
List<VideoEpisode> filterVideoEpisodes(
  List<VideoEpisode> eps,
  String filter,
) {
  final f = filter.trim().toLowerCase();
  if (f.isEmpty) return eps;
  return [
    for (final e in eps)
      if (e.title.toLowerCase().contains(f) ||
          e.episode.toString().contains(f))
        e,
  ];
}

/// B站风格视频详情页：大封面 + 元信息 + 选集网格。
class EpisodeListPage extends StatefulWidget {
  final VideoSource source;
  final VideoDetail detail;
  const EpisodeListPage({super.key, required this.source, required this.detail});

  @override
  State<EpisodeListPage> createState() => _EpisodeListPageState();

  /// 集数展示数字：委托 [episodeCountFor]，多线路报每线路集数而非相加。
  static int _epCount(VideoDetail d) =>
      episodeCountFor(d.episodes, d.sourceNames);

  /// 集数展示文案：委托 [episodeCountLabelFor]。
  static String _epCountLabel(VideoDetail d) =>
      episodeCountLabelFor(d.episodes, d.sourceNames);
}

class _EpisodeListPageState extends State<EpisodeListPage> {
  String? _openingMsg;
  int? _openingIndex;
  bool _expanded = false;
  int _curSeason = 0;
  int _curEpisode = 0;
  List<VideoRecord> _videoRecords = [];
  final Map<int, int> _linePages = {};
  static const int _epsPerPage = 12;
  final TextEditingController _filterCtrl = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final records = await LocalStore.videoRecords();
    if (!mounted) return;
    final match = records
        .where((r) =>
            r.sourceId == widget.source.id &&
            r.videoId == widget.detail.video.id)
        .toList();
    setState(() => _videoRecords = match);
  }

  /// 给播放器内部切集用：解析任意一集的播放地址。
  Future<String> _resolveEpisodeUrl(int season, int episode) =>
      widget.source.playUrl(widget.detail.video.id, season, episode);

  Future<void> _play(int season, int episode, int idx) async {
    if (_openingMsg != null) return;
    setState(() {
      _curSeason = season;
      _curEpisode = episode;
    });
    setState(() {
      _openingMsg = '加载中…';
      _openingIndex = idx;
    });
    try {
      final url = await widget.source.playUrl(
          widget.detail.video.id, season, episode);
      if (!mounted) return;
      // 统一入口：无论直链还是网页地址都进 NativePlayerPage（单一播放器）。
      // 直链走 mpv 通道；网页地址由页面内嵌 WebView 通道处理，不再双页互跳。
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NativePlayerPage(
            url: url,
            title: widget.detail.video.name,
            cover: widget.detail.cover,
            description: widget.detail.description,
            episodes: widget.detail.episodes,
            season: season,
            episode: episode,
            resolveUrl: _resolveEpisodeUrl,
            sourceNames: widget.detail.sourceNames,
            sourceId: widget.source.id,
            videoId: widget.detail.video.id,
            historyKey:
                '${widget.source.id}/${widget.detail.video.id}/$season-$episode',
            webChannelBuilder: animePlayerWebChannel,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '播放失败，请重试');
        ErrorLogger.instance.warn('anime play failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _openingMsg = null;
          _openingIndex = null;
        });
      }
    }
  }

  /// 计算立即播放应跳转的集：优先用户手动选中 → 历史记录 → 第一集。
  (int, int, int) _playTarget() {
    final flat = widget.detail.episodes;
    if (flat.isEmpty) return (0, 0, 0);
    final sel = flat.indexWhere(
        (e) => e.season == _curSeason && e.episode == _curEpisode);
    if (sel >= 0) return (_curSeason, _curEpisode, sel);
    if (_videoRecords.isNotEmpty) {
      final r = _videoRecords.first;
      final hi = flat.indexWhere(
          (e) => e.season == r.season && e.episode == r.episode);
      if (hi >= 0) return (r.season, r.episode, hi);
    }
    return (flat.first.season, flat.first.episode, 0);
  }

  /// 立即播放按钮文案，体现与当前选中/历史集数的联动关系。
  String _playLabel() {
    final flat = widget.detail.episodes;
    if (flat.isEmpty) return '立即播放';
    final sel = flat.indexWhere(
        (e) => e.season == _curSeason && e.episode == _curEpisode);
    if (sel >= 0) {
      final t = flat[sel].title;
      return t.isEmpty ? '播放 第$_curEpisode集' : '播放 $t';
    }
    if (_videoRecords.isNotEmpty) {
      final r = _videoRecords.first;
      return '继续观看 第${r.episode}集';
    }
    return '立即播放';
  }

  /// 封面加载失败/无封面时的兜底：使用本地占位封面图 + 柔和品牌色叠加，
  /// 避免"空蓝块"的空洞感（贴合"放封面"的预期）。
  Widget _coverFallback(ThemeData theme) {
    return Stack(fit: StackFit.expand, children: [
      Image.asset('assets/placeholder_cover.webp',
          fit: BoxFit.cover, gaplessPlayback: true),
      Container(
          color: theme.colorScheme.primary.withValues(alpha: 0.18)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = widget.detail;
    if (Responsive.isTablet(context)) {
      return _buildTablet(theme, d);
    }
    return _buildPhone(theme, d);
  }

  Widget _buildTablet(ThemeData theme, VideoDetail d) {
    final topPad = MediaQuery.of(context).padding.top;
    final pad = Responsive.pagePadding(context);
    
    // 桌面端使用更大的左侧面板
    final leftPanelWidth = Responsive.isLarge(context)
        ? kPanelWidth + 80
        : _leftPanelWidth;
    
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 左侧：封面 + 信息（固定宽度） ──────────────────
          Container(
            width: leftPanelWidth,
            padding: EdgeInsets.fromLTRB(pad, topPad + 10, 8, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _BackButton(),
                const SizedBox(height: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: double.infinity,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: (d.cover == null || d.cover!.isEmpty)
                          ? _coverFallback(theme)
                          : Image.network(d.cover!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _coverFallback(theme)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(d.video.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface)),
                const SizedBox(height: 6),
                Text(
                  [
                    if (d.area != null) d.area!,
                    if (d.lang != null) d.lang!,
                    if (d.year != null) d.year!,
                    if (d.type != null) d.type!,
                    if (d.video.score != null &&
                        d.video.score!.isNotEmpty &&
                        d.video.score != '0')
                      '评分 ${d.video.score}',
                    if (d.video.remarks != null &&
                        d.video.remarks!.isNotEmpty)
                      d.video.remarks!,
                    if (d.episodes.isNotEmpty) EpisodeListPage._epCountLabel(d),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                if (d.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in d.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(alpha: 0.25),
                              width: 0.6,
                            ),
                          ),
                          child: Text(t,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: theme.colorScheme.primary)),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: d.episodes.isEmpty || _openingMsg != null
                      ? null
                      : () {
                          final t = _playTarget();
                          _play(t.$1, t.$2, t.$3);
                        },
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(_playLabel()),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
          // ── 右侧：剧集列表（可滚动） ─────────────────────
          Expanded(
            child: _episodePanel(theme, d),
          ),
        ],
      ),
    );
  }

  static const double _leftPanelWidth = kPanelWidth;

  Widget _episodePanel(ThemeData theme, VideoDetail d) {
    return CustomScrollView(slivers: [
      if (d.description != null && d.description!.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.description!,
                      maxLines: _expanded ? null : 4,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          _expanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: SectionHeader(
            icon: Icons.playlist_play_rounded,
            title: '全集',
            count: EpisodeListPage._epCount(d),
            trailing: _videoRecords.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      final r = _videoRecords.first;
                      final flat = d.episodes;
                      final hi = flat.indexWhere(
                          (e) => e.season == r.season && e.episode == r.episode);
                      if (hi >= 0) _play(r.season, r.episode, hi);
                    },
                    child: Row(children: [
                      Icon(Icons.history_rounded,
                          size: 15, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text('上次：第${_videoRecords.first.episode}集',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600)),
                    ]),
                  )
                : null,
          ),
        ),
      ),
      ..._buildEpisodeSlivers(theme, d),
    ]);
  }

  Widget _buildPhone(ThemeData theme, VideoDetail d) {
    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: 260,
          pinned: true,
          backgroundColor: theme.colorScheme.surface,
          foregroundColor: theme.colorScheme.onSurface,
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(fit: StackFit.expand, children: [
              if (d.cover != null && d.cover!.isNotEmpty)
                Image.network(d.cover!,
                    fit: BoxFit.cover,
                    cacheWidth:
                        (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).toInt(),
                    errorBuilder: (_, __, ___) => _coverFallback(theme),
                  )
              else
                _coverFallback(theme),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.88),
                    ],
                  ),
                ),
              ),
              // 角落标签
              if (d.type != null || d.video.remarks != null)
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (d.type != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 0.5),
                          ),
                          child: Text(d.type!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                      if (d.type != null && d.video.remarks != null) const SizedBox(width: 6),
                      if (d.video.remarks != null)
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(d.video.remarks!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                          ),
                        ),
                    ],
                  ),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      d.video.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (d.area != null) d.area!,
                        if (d.lang != null) d.lang!,
                        if (d.year != null) d.year!,
                        if (d.type != null) d.type!,
                        if (d.video.score != null &&
                            d.video.score!.isNotEmpty &&
                            d.video.score != '0')
                          '评分 ${d.video.score}',
                        if (d.video.remarks != null &&
                            d.video.remarks!.isNotEmpty)
                          d.video.remarks!,
                        if (d.episodes.isNotEmpty) EpisodeListPage._epCountLabel(d),
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    if (d.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in d.tags)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white
                                      .withValues(alpha: 0.22),
                                  width: 0.6,
                                ),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white
                                      .withValues(alpha: 0.92),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
        // 立即播放主按钮
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.icon(
              onPressed: d.episodes.isEmpty
                  ? null
                  : () {
                      final t = _playTarget();
                      _play(t.$1, t.$2, t.$3);
                    },
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(_playLabel()),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        if (d.description != null && d.description!.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.description!,
                        maxLines: _expanded ? null : 4,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            _expanded ? '收起' : '展开',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            _expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: SectionHeader(
              icon: Icons.playlist_play_rounded,
              title: '全集',
              count: EpisodeListPage._epCount(d),
              // 过滤态额外提示「匹配 N」，避免筛选后标题计数与可见集数不符。
              trailing: _filter.trim().isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '匹配 ${filterVideoEpisodes(d.episodes, _filter).length}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_videoRecords.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              final r = _videoRecords.first;
                              final flat = d.episodes;
                              final hi = flat.indexWhere((e) =>
                                  e.season == r.season &&
                                  e.episode == r.episode);
                              if (hi >= 0) _play(r.season, r.episode, hi);
                            },
                            child: Row(children: [
                              Icon(Icons.history_rounded,
                                  size: 15, color: theme.colorScheme.primary),
                              const SizedBox(width: 4),
                              Text('上次：第${_videoRecords.first.episode}集',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () async {
                            await showEpisodeBatchDownloadSheet(context,
                                source: widget.source, detail: d);
                            // sheet 关闭后刷新：新派发的下载任务要尽快反映
                            // 到选集网格「已下载/进行中」角标。
                            if (mounted) setState(() {});
                          },
                          child: Row(children: [
                            Icon(Icons.download_rounded,
                                size: 15, color: theme.colorScheme.primary),
                            const SizedBox(width: 4),
                            Text('批量下载',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        ..._buildEpisodeSlivers(theme, d),
      ]),
    );
  }

  /// 选集按播放源（season）分组渲染：每组一个源名 + 集数头，下面是该源的剧集网格。
  /// 仅当存在多个源时才显示分组头，单源时退化为原来的扁平网格。
  List<Widget> _buildEpisodeSlivers(ThemeData theme, VideoDetail d) {
    final scheme = theme.colorScheme;
    // 搜索过滤：标题/集数模糊匹配；过滤后重算分页（集数变少自动退化为单页）。
    final flat = filterVideoEpisodes(d.episodes, _filter);
    final out = <Widget>[
      // 选集搜索框：数百集番剧按标题/集数关键词定位（与章节搜索对齐）。
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: TextField(
            controller: _filterCtrl,
            onChanged: (v) => setState(() => _filter = v),
            style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索剧集（标题 / 集数）',
              hintStyle: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
              suffixIcon: _filter.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () {
                        _filterCtrl.clear();
                        setState(() => _filter = '');
                      },
                    ),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      ),
      if (flat.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                _filter.trim().isEmpty
                    ? '暂无剧集'
                    : '没有匹配「$_filter」的剧集',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
        ),
    ];
    final bySeason = <int, List<VideoEpisode>>{};
    for (final e in flat) {
      (bySeason[e.season] ??= []).add(e);
    }
    final keys = bySeason.keys.toList()..sort();
    final groups = [
      for (final k in keys)
        (
          season: k,
          name: widget.detail.sourceNames?[k] ?? '线路 $k',
          eps: bySeason[k]!,
        ),
    ];
    final multi = groups.length > 1;
    for (final g in groups) {
      final total = g.eps.length;
      final pageCount = (total + _epsPerPage - 1) ~/ _epsPerPage;
      final rawPage = _linePages[g.season] ?? 0;
      final page = rawPage < 0 ? 0 : (rawPage >= pageCount ? pageCount - 1 : rawPage);
      final start = page * _epsPerPage;
      final end = start + _epsPerPage < total ? start + _epsPerPage : total;
      final pageEps = g.eps.sublist(start, end);
      // 线路头：主色竖条 + 名称 + 本线路总集数
      out.add(SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, multi ? 18 : 6, 20, 10),
          child: Row(children: [
            Container(
              width: 4,
              height: 16,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(g.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
            ),
            Text('本线路共 $total 集',
                style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurface.withValues(alpha: 0.5))),
          ]),
        ),
      ));
      // 关键性能修复：用懒加载 SliverGrid 替代 shrinkWrap GridView，
      // 避免整组卡片全量构建导致滚动卡顿。
      out.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: Responsive.episodeGridColumns(context),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.55,
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final ep = pageEps[i];
              // 用原始全量列表找下标：过滤后列表位置 ≠ 播放器索引，
              // 切集/高亮须基于全量集序。
              final flatIdx = widget.detail.episodes.indexOf(ep);
              final isOpening = _openingIndex == flatIdx;
              final isCurrent =
                  ep.season == _curSeason && ep.episode == _curEpisode;
              final isHistory = _videoRecords.isNotEmpty &&
                  _videoRecords.first.season == ep.season &&
                  _videoRecords.first.episode == ep.episode &&
                  !isCurrent;
              // 已看标记：该集存在续播记录（看完即清除记录，故有记录=看过）。
              // 当前集/上次看的集已用强调色，不再叠勾避免视觉噪音。
              final isWatched = !isCurrent &&
                  !isHistory &&
                  _videoRecords.any((r) =>
                      r.season == ep.season && r.episode == ep.episode);
              // 已下载标记：该集本地已存（下载任务 done + 文件在）。
              // 与已看勾对称放右下，下载态一眼可辨（离线可看）。
              final dl = VideoDownloadManager.instance.taskOf(
                  '${widget.source.id}/${widget.detail.video.id}/${ep.season}-${ep.episode}');
              final isDownloaded = dl != null &&
                  dl.state == 'done' &&
                  dl.localPath != null;
              final showTitle =
                  ep.title.isNotEmpty && !ep.title.startsWith('第');
              return Material(
                color: isOpening
                    ? scheme.primary
                    : isCurrent
                        ? scheme.primary.withValues(alpha: 0.16)
                        : scheme.surfaceContainerHighest
                            .withValues(alpha: 0.55),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isCurrent ? scheme.primary : Colors.transparent,
                    width: 1.2,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _openingMsg == null
                      ? () => _play(ep.season, ep.episode, flatIdx)
                      : null,
                  child: Stack(children: [
                    if (isWatched)
                      Positioned(
                        top: 3,
                        right: 4,
                        child: Icon(
                          Icons.check_circle_rounded,
                          size: 11,
                          color: scheme.primary.withValues(alpha: 0.7),
                        ),
                      ),
                    if (isDownloaded)
                      Positioned(
                        bottom: 3,
                        right: 4,
                        child: Icon(
                          Icons.download_done_rounded,
                          size: 11,
                          color: Colors.green.withValues(alpha: 0.85),
                        ),
                      ),
                    Center(
                      child: isOpening
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '第${ep.episode}集',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isCurrent
                                          ? FontWeight.w800
                                          : FontWeight.w700,
                                      color: isCurrent
                                          ? scheme.primary
                                          : scheme.onSurface,
                                    ),
                                  ),
                                  if (showTitle) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      ep.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: isCurrent
                                            ? scheme.primary
                                                .withValues(alpha: 0.8)
                                            : scheme.onSurface
                                                .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                    ),
                    if (isHistory)
                      Positioned(
                        top: 5,
                        right: 5,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: scheme.primary
                                    .withValues(alpha: 0.4),
                                blurRadius: 3,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ]),
                ),
              );
            },
            childCount: pageEps.length,
          ),
        ),
      ));
      // 分页控件
      if (pageCount > 1) {
        out.add(SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _pageBtn(
                    theme,
                    Icons.chevron_left_rounded,
                    page > 0
                        ? () =>
                            setState(() => _linePages[g.season] = page - 1)
                        : null),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text('${page + 1} / $pageCount',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface.withValues(alpha: 0.6))),
                ),
                _pageBtn(
                    theme,
                    Icons.chevron_right_rounded,
                    page < pageCount - 1
                        ? () =>
                            setState(() => _linePages[g.season] = page + 1)
                        : null),
              ],
            ),
          ),
        ));
      }
    }
    out.add(const SliverToBoxAdapter(child: SizedBox(height: 70)));
    return out;
  }

  Widget _pageBtn(ThemeData theme, IconData icon, VoidCallback? onTap) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: disabled
              ? Colors.transparent
              : theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon,
            size: 20,
            color: disabled
                ? theme.colorScheme.onSurface.withValues(alpha: 0.25)
                : theme.colorScheme.onSurface),
      ),
    );
  }
}

/// 平板分栏左上角返回按钮。
class _BackButton extends StatelessWidget {
  const _BackButton();
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.maybePop(context),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.arrow_back_rounded,
            color: Colors.white, size: 20),
      ),
    );
  }
}