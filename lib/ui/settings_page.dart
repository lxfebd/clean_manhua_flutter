import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../net/local_store.dart';
import '../net/update_checker.dart';
import 'source_manage_page.dart';
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
    if (mounted) {
      setState(() {
        _dark = d;
        _horizontal = h;
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
                        await LocalStore.setDarkMode(v);
                        if (mounted) setState(() => _dark = v);
                        YingManHeApp.of(context)?.setDark(v);
                      },
                    ),
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
              delay: const Duration(milliseconds: 420),
              child: _SettingsCard(
                children: [
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
              await _downloadAndInstall(info.apkUrl);
            },
            child: const Text('下载并安装'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(String url) async {
    if (!mounted) return;
    final msg = ScaffoldMessenger.of(context)
      ..showSnackBar(const SnackBar(content: Text('正在下载更新…')));
    try {
      final path = await UpdateChecker.downloadApk(url);
      if (!mounted) return;
      msg.hideCurrentSnackBar();
      final ok = await _installApk(path);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载完成，APK 在 $path')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      msg.hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
  }

  /// 通过系统安装器安装 APK（Android 需要 FileProvider + 未知来源授权）。
  Future<bool> _installApk(String path) async {
    if (Platform.isAndroid) {
      try {
        await MethodChannel('xingmanxia/install')
            .invokeMethod('installApk', {'path': path});
        return true;
      } catch (e) {
        debugPrint('install failed: $e');
        return false;
      }
    }
    return false;
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
