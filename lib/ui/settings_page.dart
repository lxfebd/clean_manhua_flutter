import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';

import '../main.dart';
import '../net/bookshelf_store.dart';
import '../net/local_store.dart';
import '../net/novel_shelf_store.dart';
import '../net/update_checker.dart';
import '../theme.dart';
import 'source_manage_page.dart';
import 'widgets/update_download_dialog.dart';
import 'widgets/motion.dart';

/// 设置页：深色模式、阅读器翻页模式、清空下载/历史。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _dark = false;
  bool _horizontal = false;
  bool _rtl = false;
  int _themeId = 0;
  bool _loaded = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await LocalStore.darkMode();
    final h = await LocalStore.horizontalReader();
    final rtl = await LocalStore.rtlReader();
    final tid = await LocalStore.themeId();
    if (mounted) {
      setState(() {
        _dark = d;
        _horizontal = h;
        _rtl = rtl;
        _themeId = tid;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 110),
          children: [
            FadeSlideIn(
              duration: const Duration(milliseconds: 380),
              child: Text(
                  '设置',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
            ),
            const SizedBox(height: 20),
            FadeSlideIn(
              delay: const Duration(milliseconds: 80),
              child: _SectionLabel(label: '主题'),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 140),
              child: _SettingsCard(
                children: [
                  _SettingTile(
                    icon: Icons.dark_mode_outlined,
                    title: '深色模式',
                    subtitle: '夜间阅读更护眼',
                    trailing: Switch(
                      value: _dark,
                      onChanged: (v) async {
                        YingManHeApp.of(context)?.setDark(v);
                        await LocalStore.setDarkMode(v);
                        if (mounted) setState(() => _dark = v);
                      },
                    ),
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _ThemeSelector(
                    current: _themeId,
                    onChanged: (v) async {
                      YingManHeApp.of(context)?.setThemeId(v);
                      await LocalStore.setThemeId(v);
                      if (mounted) setState(() => _themeId = v);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FadeSlideIn(
              delay: const Duration(milliseconds: 220),
              child: _SectionLabel(label: '数据源'),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 280),
              child: _SettingsCard(
                children: [
                  _SettingTile(
                    icon: Icons.public_rounded,
                    title: '数据源管理',
                    subtitle: '启停各源、编辑域名/代理，免发版换域名',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SourceManagePage(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FadeSlideIn(
              delay: const Duration(milliseconds: 220),
              child: _SectionLabel(label: '阅读器'),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 280),
              child: _SettingsCard(
                children: [
                  _SettingTile(
                    icon: Icons.swipe_right_alt_rounded,
                    title: '横向翻页模式',
                    subtitle: '关闭则为纵向滚动逐页',
                    trailing: Switch(
                      value: _horizontal,
                      onChanged: (v) async {
                        await LocalStore.setHorizontalReader(v);
                        if (mounted) setState(() => _horizontal = v);
                      },
                    ),
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.arrow_back_ios_new_rounded,
                    title: 'RTL 反向翻页（日漫）',
                    subtitle: _rtl ? '从右往左' : '从左往右',
                    trailing: Switch(
                      value: _rtl,
                      onChanged: (v) async {
                        await LocalStore.setRtlReader(v);
                        if (mounted) setState(() => _rtl = v);
                      },
                    ),
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.touch_app_rounded,
                    title: '手势配置',
                    subtitle: '自定义点击区域操作',
                    onTap: _showGestureSettings,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FadeSlideIn(
              delay: const Duration(milliseconds: 220),
              child: _SectionLabel(label: '更新'),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 280),
              child: _SettingsCard(
                children: [
                  _SettingTile(
                    icon: Icons.system_update_alt_rounded,
                    title: '检查更新',
                    subtitle: '从 GitHub Releases 获取最新版本',
                    trailing: _checking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _checkUpdate,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FadeSlideIn(
              delay: const Duration(milliseconds: 220),
              child: _SectionLabel(label: '数据'),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 280),
              child: _SettingsCard(
                children: [
                  _SettingTile(
                    icon: Icons.backup_rounded,
                    title: '导出备份',
                    subtitle: '书架、历史、设置 → JSON 文件',
                    onTap: _exportBackup,
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.restore_rounded,
                    title: '导入备份',
                    subtitle: '从 JSON 文件恢复数据',
                    onTap: _importBackup,
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.download_outlined,
                    title: '清空全部下载',
                    subtitle: '删除已下载的章节图片，释放空间',
                    onTap: () => _confirm(
                      title: '清空下载',
                      content: '确定清空所有已下载的章节？',
                      action: () async {
                        await LocalStore.clearDownloads();
                      },
                      successMsg: '已清空下载',
                    ),
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.history_rounded,
                    title: '清空阅读历史',
                    subtitle: '清除所有阅读记录',
                    onTap: () => _confirm(
                      title: '清空历史',
                      content: '确定清空所有阅读历史？',
                      action: () async {
                        await LocalStore.clearHistory();
                      },
                      successMsg: '已清空历史',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            FadeSlideIn(
              delay: const Duration(milliseconds: 500),
              child: Center(
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Clipboard.setData(
                          const ClipboardData(text: 'https://github.com/lxfebd'),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制 GitHub 地址')),
                        );
                      },
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '涙不再为你而流  ',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            TextSpan(
                              text: '@lxfebd',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'github.com/lxfebd',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '星漫匣 · ${UpdateChecker.currentVersion()}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 导出备份：收集所有数据并保存为 JSON 文件。
  /// 手势配置弹窗：左侧/中间/右侧点击区域各自的三选一。
  Future<void> _showGestureSettings() async {
    final cfg = await LocalStore.gestureConfig();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F1013),
      barrierColor: Colors.black.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _GestureSettingsSheet(initial: cfg),
    );
  }

  Future<void> _exportBackup() async {
    try {
      final data = await LocalStore.collectBackup(
        bookshelfData: BookshelfStore.exportData(),
        novelShelfData: NovelShelfStore.exportData(),
      );
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final result = await FilePicker.saveFile(
        dialogTitle: '导出备份',
        fileName: '星漫匣_备份_${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null) return;
      File(result).writeAsStringSync(json);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出到 ${result.split('\\').last.split('/').last}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  /// 导入备份：从 JSON 文件恢复数据。
  Future<void> _importBackup() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择备份文件',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.single.path == null) return;
    try {
      final json = File(result.files.single.path!).readAsStringSync();
      final data = jsonDecode(json) as Map<String, dynamic>;
      if (data['version'] == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无效的备份文件')),
          );
        }
        return;
      }
      // 恢复书架
      if (data['bookshelf'] is Map) {
        BookshelfStore.importData(data['bookshelf'] as Map<String, dynamic>);
      }
      if (data['novel_shelf'] is Map) {
        NovelShelfStore.importData(data['novel_shelf'] as Map<String, dynamic>);
      }
      final count = await LocalStore.restoreBackup(data);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已恢复 $count 项数据（书架${data['bookshelf'] is Map ? ' +' : ''}${data['novel_shelf'] is Map ? '小说书架' : ''}）')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败：$e')),
        );
      }
    }
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await UpdateChecker.checkLatest();
      if (!mounted) return;
      if (info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已是最新版本')),
        );
        return;
      }
      _showUpdateDialog(info);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (info.notes != null && info.notes!.isNotEmpty) ...[
                Text(
                  info.notes!,
                  style: const TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                '当前版本：v${UpdateChecker.currentVersion()}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(ctx)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('以后再说'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              showUpdateDownloadDialog(context, info.apkUrl);
            },
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm({
    required String title,
    required String content,
    required Future<void> Function() action,
    required String successMsg,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMsg)),
        );
      }
    }
  }
}

/// 主题色选择器：5 个种子色圆点，点击立即切换全局主题。
class _ThemeSelector extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;
  const _ThemeSelector({required this.current, required this.onChanged});

  static const _names = ['墨蓝', '东京夜', '翡翠绿', '暖橙', '薰衣草'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined,
                  size: 20, color: scheme.onSurface.withValues(alpha: 0.85)),
              const SizedBox(width: 12),
              Text('主题色',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < AppTheme.seeds.length; i++)
                GestureDetector(
                  onTap: () => onChanged(i),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppTheme.seedOf(i),
                          shape: BoxShape.circle,
                          border: current == i
                              ? Border.all(
                                  color: scheme.onSurface,
                                  width: 2.5,
                                )
                              : null,
                          boxShadow: current == i
                              ? [
                                  BoxShadow(
                                      color: AppTheme.seedOf(i)
                                          .withValues(alpha: 0.4),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2)),
                                ]
                              : null,
                        ),
                        child: current == i
                            ? const Icon(Icons.check_rounded,
                                color: Colors.white, size: 20)
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(_names[i],
                          style: TextStyle(
                              fontSize: 10,
                              color: scheme.onSurface
                                  .withValues(alpha: 0.6))),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 分区标题
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  const _SettingTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
              if (trailing == null)
                Icon(Icons.chevron_right_rounded,
                    color: scheme.onSurface.withValues(alpha: 0.4), size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

/// 手势配置底部抽屉：左侧 / 中间 / 右侧各选一个动作。
class _GestureSettingsSheet extends StatefulWidget {
  final Map<String, String> initial;
  const _GestureSettingsSheet({required this.initial});

  @override
  State<_GestureSettingsSheet> createState() => _GestureSettingsSheetState();
}

class _GestureSettingsSheetState extends State<_GestureSettingsSheet> {
  late Map<String, String> _cfg;

  static const _regions = ['left', 'center', 'right'];
  static const _regionLabels = {'left': '左侧', 'center': '中间', 'right': '右侧'};
  static const _actionLabels = {
    'prevPage': '上一页',
    'nextPage': '下一页',
    'toggleMenu': '切换工具栏',
    'toggleBrightness': '切换亮度',
    'scrollDown': '向下滚动',
    'scrollUp': '向上滚动',
  };

  @override
  void initState() {
    super.initState();
    _cfg = Map.from(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
        decoration: const BoxDecoration(
          color: Color(0xFF0F1013),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('手势配置',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 4),
            const Text('点击阅读器三等分区域触发的操作',
                style: TextStyle(
                    fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 18),
            for (final r in _regions) ...[
              _regionRow(r, scheme),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3A6EA5),
                ),
                onPressed: () async {
                  await LocalStore.setGestureConfig(_cfg);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _regionRow(String region, ColorScheme scheme) {
    final current = _cfg[region] ?? 'toggleMenu';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_regionLabels[region] ?? region,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final a in LocalStore.gestureActions)
              _optBtn(a, current == a, () {
                setState(() => _cfg[region] = a);
              }),
          ],
        ),
      ],
    );
  }

  Widget _optBtn(String action, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF3A6EA5)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? const Color(0xFF3A6EA5)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          _actionLabels[action] ?? action,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}
