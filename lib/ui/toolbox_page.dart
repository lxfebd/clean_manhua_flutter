import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/image_cache.dart';
import 'responsive.dart';
import 'settings_page.dart';
import 'tokens.dart';
import 'tools/device_tools_page.dart';
import 'tools/image_tools_page.dart';
import 'tools/network_tools_page.dart';
import 'tools/text_tools_page.dart';
import 'webview_page.dart';
import 'widgets/motion.dart';

/// 工具箱：本地实用工具集合。
///
/// 平板布局（≥600dp）：
/// - 左侧：工具分类导航
/// - 右侧：具体内容（下载管理/视频下载/实用工具）
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key});

  @override
  State<ToolboxPage> createState() => ToolboxPageState();
}

class ToolboxPageState extends State<ToolboxPage> {
  // 缓存
  int _cacheBytes = 0;
  int _cacheCount = 0;
  bool _busyCache = false;

  // 当前选中的工具分类（平板模式）
  int _selectedTool = 0;

  static const String _nekogalUrl = 'https://xifan.moe/';

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
  }

  /// 外部刷新入口（切到本 Tab 时调用），刷新缓存占用。
  void refresh() {
    _refreshCacheSize();
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
    // 与主框架断点统一：medium(600-839) 交给手机单列布局，
    // expanded/large(≥840) 才进入平板布局，避免 600-840 竖屏内容区被挤压。
    final isExpanded = Responsive.isExpanded(context);

    // 平板：顶部横向分类 Tab + 内容区（无二级侧栏，双导航已收敛）
    if (isExpanded) {
      return _buildTabletLayout(scheme);
    }

    // 手机：传统布局
    return _buildPhoneLayout(scheme);
  }

  /// 平板布局：顶部标题栏 + 横向分类 Tab + 内容区（无二级侧栏，双导航收敛）
  /// 桌面端头部升级为 Fluent 页头（26px 大标题 + 命令栏）。
  Widget _buildTabletLayout(ColorScheme scheme) {
    final isDesktop = DesktopUi.isDesktopPlatform;
    final settingsButton = PressableScale(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsPage()),
        );
      },
      scale: 0.92,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.control),
          border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness),
          ),
        ),
        child: Icon(Icons.settings_outlined,
            size: 20,
            color: T.color(scheme.onSurface, TextTier.mid,
                brightness: scheme.brightness)),
      ),
    );
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部页头
            if (isDesktop)
              DesktopPageHeader(
                title: '工具箱',
                subtitle: _getToolTitle(),
                actions: [settingsButton],
              )
            else
              Padding(
                padding: EdgeInsets.fromLTRB(
                  Responsive.pagePadding(context),
                  12,
                  Responsive.pagePadding(context),
                  4,
                ),
                child: Row(
                  children: [
                    Text(
                      '工具箱',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: scheme.onSurface,
                          ),
                    ),
                    const Spacer(),
                    settingsButton,
                  ],
                ),
              ),
            // 横向分类 Tab
            _buildToolTabs(scheme),
            // 内容区
            Expanded(child: _buildTabletContent(scheme)),
          ],
        ),
      ),
    );
  }

  /// 横向分类 Tab（替代原左侧二级导航栏）
  Widget _buildToolTabs(ColorScheme scheme) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: Responsive.pagePadding(context),
        ),
        children: [
          _tabletNavItem(
            scheme,
            icon: Icons.cleaning_services_outlined,
            label: '缓存清理',
            isSelected: _selectedTool == 0,
            onTap: () => setState(() => _selectedTool = 0),
            badge: _cacheCount > 0 ? '$_cacheCount' : null,
          ),
          _tabletNavItem(
            scheme,
            icon: Icons.image_outlined,
            label: '图片工具',
            isSelected: _selectedTool == 1,
            onTap: () => setState(() => _selectedTool = 1),
          ),
          _tabletNavItem(
            scheme,
            icon: Icons.text_fields_rounded,
            label: '文本工具',
            isSelected: _selectedTool == 2,
            onTap: () => setState(() => _selectedTool = 2),
          ),
          _tabletNavItem(
            scheme,
            icon: Icons.public_rounded,
            label: '网络工具',
            isSelected: _selectedTool == 3,
            onTap: () => setState(() => _selectedTool = 3),
          ),
          _tabletNavItem(
            scheme,
            icon: Icons.phone_android_rounded,
            label: '设备工具',
            isSelected: _selectedTool == 4,
            onTap: () => setState(() => _selectedTool = 4),
          ),
          _tabletNavItem(
            scheme,
            icon: Icons.sports_esports_outlined,
            label: '站点入口',
            isSelected: _selectedTool == 5,
            onTap: () => setState(() => _selectedTool = 5),
          ),
        ],
      ),
    );
  }

  /// 横向胶囊分类项
  Widget _tabletNavItem(
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    String? badge,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: HoverEffect(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(R.pill),
            border: Border.all(
              color: isSelected
                  ? scheme.primary.withValues(alpha: 0.35)
                  : T.color(scheme.onSurface, TextTier.hairline,
                      brightness: scheme.brightness),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected
                    ? scheme.primary
                    : T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected
                          ? scheme.primary
                          : T.color(scheme.onSurface, TextTier.mid,
                              brightness: scheme.brightness),
                    ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? scheme.primary.withValues(alpha: 0.2)
                        : scheme.onSurface.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(R.control),
                  ),
                  child: Text(
                    badge,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? scheme.primary
                              : T.color(scheme.onSurface, TextTier.low,
                                  brightness: scheme.brightness),
                        ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 平板右侧内容区
  Widget _buildTabletContent(ColorScheme scheme) {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context),
              16,
              Responsive.pagePadding(context),
              8,
            ),
            child: Text(
              _getToolTitle(),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context),
              8,
              Responsive.pagePadding(context),
              // 平板是 NavigationRail（无底部导航），110 是手机底部导航残留，
              // 桌面/平板会莫名多出一大块底部空白。
              24,
            ),
            child: _buildToolContent(scheme),
          ),
        ),
      ],
    );
  }

  String _getToolTitle() {
    switch (_selectedTool) {
      case 0:
        return '缓存清理';
      case 1:
        return '图片工具';
      case 2:
        return '文本工具';
      case 3:
        return '网络工具';
      case 4:
        return '设备工具';
      case 5:
        return '站点入口';
      default:
        return '工具箱';
    }
  }

  Widget _buildToolContent(ColorScheme scheme) {
    switch (_selectedTool) {
      case 0:
        return _buildCacheCleaner(scheme);
      case 1:
        return _buildToolEntry(
          scheme,
          icon: Icons.image_outlined,
          title: '图片工具',
          subtitle: '水印 / 模糊 / 切图 / 压缩',
          onTap: () => _push(const ImageToolsPage()),
        );
      case 2:
        return _buildToolEntry(
          scheme,
          icon: Icons.text_fields_rounded,
          title: '文本工具',
          subtitle: '加密 / 摩斯 / 二维码',
          onTap: () => _push(const TextToolsPage()),
        );
      case 3:
        return _buildToolEntry(
          scheme,
          icon: Icons.public_rounded,
          title: '网络工具',
          subtitle: 'DNS / Ping / IP / 天气',
          onTap: () => _push(const NetworkToolsPage()),
        );
      case 4:
        return _buildToolEntry(
          scheme,
          icon: Icons.phone_android_rounded,
          title: '设备工具',
          subtitle: '信息 / 屏幕 / 秒表',
          onTap: () => _push(const DeviceToolsPage()),
        );
      case 5:
        return _buildToolEntry(
          scheme,
          icon: Icons.sports_esports_outlined,
          title: '站点入口',
          subtitle: 'NekoGAL',
          onTap: () => _openSitesPanel(scheme),
        );
      default:
        return const SizedBox.shrink();
    }
  }


  /// 工具入口卡片（平板）
  Widget _buildToolEntry(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.all(S.x16),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(
            color: T.color(scheme.onSurface, TextTier.hairline,
                brightness: scheme.brightness),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: Icon(icon, size: 28, color: scheme.primary),
            ),
            const SizedBox(width: S.x16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                        ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 24,
              color: T.color(scheme.onSurface, TextTier.disabled,
                  brightness: scheme.brightness),
            ),
          ],
        ),
      ),
    );
  }

  /// 缓存清理卡片
  Widget _buildCacheCleaner(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(S.x16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(R.card),
        border: Border.all(
          color: T.color(scheme.onSurface, TextTier.hairline,
              brightness: scheme.brightness),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(R.control),
                ),
                child: Icon(Icons.cleaning_services_outlined,
                    size: 24, color: scheme.primary),
              ),
              const SizedBox(width: S.x16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '图片缓存',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _cacheCount > 0
                          ? '${_fmtSize(_cacheBytes)} · $_cacheCount 个文件'
                          : '暂无缓存',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: T.color(scheme.onSurface, TextTier.low,
                                brightness: scheme.brightness),
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busyCache
                      ? null
                      : () async {
                          await _refreshCacheSize();
                        },
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('刷新'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busyCache || _cacheCount == 0
                      ? null
                      : _confirmClearCache,
                  icon: _busyCache
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('清理缓存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── 手机布局 ────────────────────────────────────────────────────────

  Widget _buildPhoneLayout(ColorScheme scheme) {
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await _refreshCacheSize();
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      Responsive.pagePadding(context), 12,
                      Responsive.pagePadding(context), 0),
                  child: Row(
                    children: [
                      Text(
                        '工具箱',
                        style: Theme.of(context).textTheme.displaySmall?.copyWith(
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
                            borderRadius: BorderRadius.circular(R.control),
                            border: Border.all(
                              color: T.color(scheme.onSurface,
                                  TextTier.hairline,
                                  brightness: scheme.brightness),
                            ),
                          ),
                          child: Icon(Icons.settings_outlined,
                              size: 20,
                              color: T.color(scheme.onSurface, TextTier.mid,
                                  brightness: scheme.brightness)),
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
        // 手机快捷工具固定 2 列（唯一调用场景，旧 toolGridColumns 的
        // 3/4/6 分支死代码已删）。
        GridView.count(
          crossAxisCount: 2,
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: T.color(scheme.onSurface, TextTier.disabled,
                  brightness: scheme.brightness),
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
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB'
        : '${(bytes / 1024).round()} KB';
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
        padding: const EdgeInsets.all(S.x12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(color: scheme.outline),
          // Minimalist：卡片靠 hairline 描边分层，无投影。
          boxShadow: const [],
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
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: Icon(icon, size: 20, color: scheme.primary),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        )),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: T.color(scheme.onSurface, TextTier.low,
                              brightness: scheme.brightness),
                        )),
              ],
            ),
          ],
        ),
      ),
    );
  }


  // ─── 弹窗确认 ────────────────────────────────────────────────────────


  Future<void> _confirmClearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.card)),
        title: const Text('清理图片缓存'),
        content: Text('确定清理 $_cacheCount 个缓存文件（${_fmtSize(_cacheBytes)}）？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _clearCache();
    }
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                  ),
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
                        : const Icon(Icons.cleaning_services_outlined,
                            size: 18),
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
          Text('仅作站点跳转入口，不解析/不托管第三方内容。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: T.color(scheme.onSurface, TextTier.low,
                        brightness: scheme.brightness),
                  )),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading:
                Icon(Icons.sports_esports_rounded, color: scheme.primary),
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

  void _showPanel(
      ColorScheme scheme, IconData icon, String title, Widget body) {
    showResponsiveBottomSheet(
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

}
