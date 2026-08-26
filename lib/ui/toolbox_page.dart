import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/download_manager.dart';
import '../net/image_cache.dart';
import '../net/local_store.dart';
import '../sources/source_manager.dart';
import 'responsive.dart';
import 'settings_page.dart';
import 'tools/device_tools_page.dart';
import 'tools/image_tools_page.dart';
import 'tools/network_tools_page.dart';
import 'tools/text_tools_page.dart';
import 'webview_page.dart';
import 'widgets/motion.dart';

/// 工具箱：本地实用工具集合。
/// - 下载管理：查看全部下载记录、删除单条、清理已完成/全部
/// - 缓存清理：清理图片缓存（封面/列表图）
/// - 图片工具：水印 / 模糊 / 九宫格切图 / 压缩 / 转换 / 缩放
/// - 文本工具：MD5 / SHA / Base64 / 摩斯密码 / 长度换算 / 二维码
/// - 网络工具：DNS / Ping / IP 归属地 / 天气
/// - 设备工具：设备信息 / 屏幕测试 / 秒表 / 指南针
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key});

  @override
  State<ToolboxPage> createState() => ToolboxPageState();
}

class ToolboxPageState extends State<ToolboxPage> {
  // 下载
  List<DownloadRecord> _downloads = [];
  bool _busyDownloads = false;

  // 缓存
  int _cacheBytes = 0;
  int _cacheCount = 0;
  bool _busyCache = false;

  static const String _nekogalUrl = 'https://xifan.moe/';

  @override
  void initState() {
    super.initState();
    _refreshDownloads();
    _refreshCacheSize();
  }

  /// 外部刷新入口（切到本 Tab 时调用），刷新下载列表与缓存占用。
  void refresh() {
    _refreshDownloads();
    _refreshCacheSize();
  }

  Future<void> _refreshDownloads() async {
    final list = await LocalStore.downloads();
    if (mounted) setState(() => _downloads = list);
  }

  Future<void> _refreshCacheSize() async {
    final files = await ImageCacheManager.diskFiles();
    var sum = 0;
    for (final f in files) {
      try {
        sum += await f.length();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _cacheBytes = sum;
        _cacheCount = files.length;
      });
    }
  }

  Future<void> _clearDownloads() async {
    setState(() => _busyDownloads = true);
    try {
      await LocalStore.clearDownloads();
      await _refreshDownloads();
    } finally {
      if (mounted) setState(() => _busyDownloads = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已清空全部下载')));
  }

  Future<void> _clearFinishedDownloads() async {
    setState(() => _busyDownloads = true);
    final n = await LocalStore.clearFinishedDownloads();
    await _refreshDownloads();
    if (mounted) setState(() => _busyDownloads = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已清理 $n 个已完成下载')));
  }

  Future<void> _removeDownload(DownloadRecord d) async {
    await LocalStore.removeDownloadFiles(d);
    await LocalStore.removeDownload(d.key);
    await _refreshDownloads();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已删除该下载记录')));
  }

  /// 重试失败的下载任务。
  Future<void> _retryDownload(DownloadRecord d) async {
    setState(() => _busyDownloads = true);
    try {
      // 从源头重新获取图片 URL 列表，避免传入空数组导致立即完成
      final source = SourceManager.byId(d.book.sourceId);
      final urls = await source.chapterPics(d.chapterId);
      await DownloadManager.retry(
        '${d.book.sourceId}::${d.book.comicId}',
        d.chapterId,
        d.chapterTitle,
        urls,
      );
      await _refreshDownloads();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重试失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busyDownloads = false);
    }
  }

  Future<void> _clearCache() async {
    setState(() => _busyCache = true);
    try {
      await ImageCacheManager.clear();
      try {
        PaintingBinding.instance.imageCache.clear();
      } catch (_) {}
      await _refreshCacheSize();
    } finally {
      if (mounted) setState(() => _busyCache = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('图片缓存已清理')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await _refreshDownloads();
            await _refreshCacheSize();
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                  child: Row(
                    children: [
                      Text(
                        '工具箱',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          color: scheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      PressableScale(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SettingsPage()),
                          );
                        },
                        scale: 0.92,
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: scheme.onSurface.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Icon(Icons.settings_outlined,
                              size: 20,
                              color:
                                  scheme.onSurface.withValues(alpha: 0.7)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
                  child: Column(
                    children: [
                      _card(scheme, Icons.download_done_rounded, '下载管理',
                          _buildDownloads(scheme)),
                      const SizedBox(height: 12),
                      _buildQuickGrid(scheme),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 快捷工具：缓存清理 + 四大分类工具入口
  Widget _buildQuickGrid(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryLabel(scheme, '实用工具'),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: Responsive.toolGridColumns(context),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.35,
          children: [
            _toolTile(
              scheme,
              icon: Icons.cleaning_services_outlined,
              title: '缓存清理',
              subtitle: _cacheCount > 0
                  ? '${_fmtSize(_cacheBytes)} · $_cacheCount 个文件'
                  : '暂无缓存',
              onTap: () => _openCachePanel(scheme),
            ),
            _toolTile(
              scheme,
              icon: Icons.image_outlined,
              title: '图片工具',
              subtitle: '水印 / 模糊 / 切图',
              onTap: () => _push(const ImageToolsPage()),
            ),
            _toolTile(
              scheme,
              icon: Icons.text_fields_rounded,
              title: '文本工具',
              subtitle: '加密 / 摩斯 / 二维码',
              onTap: () => _push(const TextToolsPage()),
            ),
            _toolTile(
              scheme,
              icon: Icons.public_rounded,
              title: '网络工具',
              subtitle: 'DNS / Ping / IP / 天气',
              onTap: () => _push(const NetworkToolsPage()),
            ),
            _toolTile(
              scheme,
              icon: Icons.phone_android_rounded,
              title: '设备工具',
              subtitle: '信息 / 屏幕 / 秒表',
              onTap: () => _push(const DeviceToolsPage()),
            ),
            _toolTile(
              scheme,
              icon: Icons.sports_esports_outlined,
              title: '站点入口',
              subtitle: 'NekoGAL',
              onTap: () => _openSitesPanel(scheme),
            ),
          ],
        ),
      ],
    );
  }

  Widget _categoryLabel(ColorScheme scheme, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface.withValues(alpha: 0.45),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  void _push(Widget page) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }

  String _fmtSize(int bytes) {
    final mb = bytes / 1024 / 1024;
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(bytes / 1024).round()} KB';
  }

  Widget _toolTile(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 20, color: scheme.primary),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurface.withValues(alpha: 0.5))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openCachePanel(ColorScheme scheme) {
    _showPanel(
      scheme,
      Icons.cleaning_services_outlined,
      '缓存清理',
      StatefulBuilder(
        builder: (context, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前图片缓存占用：${_fmtSize(_cacheBytes)}（$_cacheCount 个文件）',
              style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.6), fontSize: 13),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busyCache
                        ? null
                        : () async {
                            await _refreshCacheSize();
                            if (context.mounted) {
                              setSheetState(() {});
                            }
                          },
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('刷新'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busyCache || _cacheCount == 0
                        ? null
                        : () async {
                            await _confirmClearCache();
                            if (context.mounted) setSheetState(() {});
                          },
                    icon: _busyCache
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cleaning_services_outlined, size: 18),
                    label: const Text('清理图片缓存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openSitesPanel(ColorScheme scheme) {
    _showPanel(
      scheme,
      Icons.sports_esports_outlined,
      '站点入口',
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('仅作站点跳转入口，不解析/不托管第三方内容。',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.sports_esports_rounded, color: scheme.primary),
            title: const Text('NekoGAL'),
            subtitle: const Text('Galgame 平台（xifan.moe 入口）'),
            trailing: const Icon(Icons.open_in_new_rounded),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        WebviewPage(url: _nekogalUrl, title: 'NekoGAL')),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showPanel(ColorScheme scheme, IconData icon, String title, Widget body) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(icon, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 14),
              body,
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(ColorScheme scheme, IconData icon, String title, Widget body) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }

  Widget _buildDownloads(ColorScheme scheme) {
    final done = _downloads.where((d) => d.finished).length;
    final running = _downloads.length - done;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '共 ${_downloads.length} 个',
              style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(width: 12),
            Text('已完成 $done',
                style: TextStyle(
                    fontSize: 13, color: scheme.primary)),
            const SizedBox(width: 12),
            Text('进行中 $running',
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurface.withValues(alpha: 0.6))),
          ],
        ),
        const SizedBox(height: 10),
        if (_downloads.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('暂无下载记录', style: TextStyle(color: Colors.grey)),
          )
        else
          ..._downloads.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      d.finished
                          ? Icons.check_circle_outline
                          : Icons.downloading_rounded,
                      size: 16,
                      color: d.finished ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${d.book.name} · ${d.chapterTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!d.finished)
                      Text('${d.done}/${d.total}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    if (!d.finished)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 17,
                        icon: Icon(Icons.refresh_rounded,
                            color: scheme.primary.withValues(alpha: 0.8)),
                        tooltip: '重试',
                        onPressed: () => _retryDownload(d),
                      ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 17,
                      icon: Icon(Icons.close_rounded,
                          color: scheme.onSurface.withValues(alpha: 0.4)),
                      tooltip: '删除',
                      onPressed: () => _confirmRemoveDownload(d),
                    ),
                  ],
                ),
              )),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: (_busyDownloads || running == 0 && done == 0)
                    ? null
                    : _confirmClearFinished,
                icon: _busyDownloads
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cleaning_services_outlined, size: 18),
                label: const Text('清理已完成'),
              ),
              TextButton.icon(
                onPressed: _busyDownloads || _downloads.isEmpty
                    ? null
                    : _confirmClearAll,
                icon: _busyDownloads
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('清空全部'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmRemoveDownload(DownloadRecord d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('删除下载'),
        content: Text('确定删除「${d.book.name} · ${d.chapterTitle}」吗？\n本地文件将一并删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await _removeDownload(d);
  }

  Future<void> _confirmClearFinished() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('清理已完成'),
        content: const Text('将删除所有已完成下载的本地文件与记录，进行中的任务会保留。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清理')),
        ],
      ),
    );
    if (ok == true) await _clearFinishedDownloads();
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('清空全部下载'),
        content: const Text('将删除全部下载记录与本地文件（含进行中的任务）。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) await _clearDownloads();
  }

  Future<void> _confirmClearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('清理图片缓存'),
        content: const Text('将删除所有本地缓存的封面与列表图，下次浏览会重新加载。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清理')),
        ],
      ),
    );
    if (ok == true) await _clearCache();
  }
}
