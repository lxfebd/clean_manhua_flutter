import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';

import '../main.dart';
import '../net/backup_cipher.dart';
import '../net/bookshelf_store.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';
import '../net/novel_shelf_store.dart';
import '../net/shelf_updater.dart';
import '../net/update_checker.dart';
import '../net/webdav_sync.dart';
import '../theme.dart';
import '../utils/danmaku.dart';
import 'responsive.dart';
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
  int _readerMode = 1; // 0=纵向滚动，1=单页横向（默认），2=双页并排
  bool _rtl = false;
  int _themeId = 0;
  bool _loaded = false;
  bool _checking = false;
  DanmakuSettings _danmaku = const DanmakuSettings();
  UpdateFreq _updateFreq = UpdateFreq.off;

  String get _updateFreqLabel => switch (_updateFreq) {
        UpdateFreq.off => '关闭',
        UpdateFreq.every6h => '每 6 小时检查一次',
        UpdateFreq.every12h => '每 12 小时检查一次',
        UpdateFreq.daily => '每天检查一次',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await LocalStore.darkMode();
    final mode = await LocalStore.readerMode();
    final rtl = await LocalStore.rtlReader();
    final tid = await LocalStore.themeId();
    final dm = await LocalStore.danmakuSettings();
    final freq = await ShelfUpdater.frequency();
    if (mounted) {
      setState(() {
        _dark = d;
        _readerMode = mode;
        _rtl = rtl;
        _themeId = tid;
        _danmaku = dm;
        _updateFreq = freq;
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
        // 设置页限宽居中（M3 LS-U2）：本页是独立路由，桌面大屏不拉满全宽。
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    Responsive.pagePadding(context), 14,
                    Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
                children: [
            // 桌面端（Windows）没有系统返回手势/物理返回键，必须提供
            // 显式返回按钮；移动端依赖系统返回，保持原样不加。
            if (DesktopUi.isDesktopPlatform)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Tooltip(
                      message: '返回',
                      child: IconButton(
                        onPressed: () => Navigator.maybePop(context),
                        icon: const Icon(Icons.arrow_back_rounded, size: 20),
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.75),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '返回',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
            FadeSlideIn(
              duration: const Duration(milliseconds: 380),
              child: Text(
                  '设置',
                  style: TextStyle(
                    fontSize: DesktopUi.isDesktopPlatform ? 26 : 21,
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
                    title: '翻页模式',
                    subtitle: _readerMode == 0
                        ? '纵向滚动逐页'
                        : (_readerMode == 1 ? '单页横向翻页' : '双页并排（适合平板横屏）'),
                    trailing: PopupMenuButton<int>(
                      initialValue: _readerMode,
                      icon: const Icon(Icons.unfold_more_rounded,
                          color: Colors.white70),
                      onSelected: (v) async {
                        await LocalStore.setReaderMode(v);
                        if (mounted) setState(() => _readerMode = v);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 0, child: Text('纵向滚动')),
                        PopupMenuItem(value: 1, child: Text('单页横向')),
                        PopupMenuItem(value: 2, child: Text('双页并排')),
                      ],
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
              child: _SectionLabel(label: '播放器'),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 280),
              child: _SettingsCard(
                children: [
                  _SettingTile(
                    icon: Icons.subtitles_rounded,
                    title: '弹幕',
                    subtitle: _danmaku.on ? '已开启 · 数据源：弹弹 play' : '视频播放时显示评论弹幕',
                    trailing: Switch(
                      value: _danmaku.on,
                      onChanged: (v) async {
                        final next = _danmaku.copyWith(on: v);
                        await LocalStore.setDanmaku(next);
                        if (mounted) setState(() => _danmaku = next);
                      },
                    ),
                  ),
                  if (_danmaku.on) ...[
                    Container(
                      height: 0.5,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                    ),
                    _SliderTile(
                      icon: Icons.format_size_rounded,
                      title: '弹幕字号',
                      value: _danmaku.fontSize,
                      min: 12,
                      max: 22,
                      divisions: 10,
                      display: '${_danmaku.fontSize.round()}',
                      onChanged: (v) {
                        final next = _danmaku.copyWith(fontSize: v);
                        setState(() => _danmaku = next);
                        LocalStore.setDanmaku(next);
                      },
                    ),
                    Container(
                      height: 0.5,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                    ),
                    _SliderTile(
                      icon: Icons.speed_rounded,
                      title: '弹幕速度',
                      value: _danmaku.speed,
                      min: 1.0,
                      max: 3.0,
                      divisions: 20,
                      display: '${_danmaku.speed.toStringAsFixed(1)}x',
                      onChanged: (v) {
                        final next = _danmaku.copyWith(speed: v);
                        setState(() => _danmaku = next);
                        LocalStore.setDanmaku(next);
                      },
                    ),
                    Container(
                      height: 0.5,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                    ),
                    _SliderTile(
                      icon: Icons.opacity_rounded,
                      title: '弹幕透明度',
                      value: _danmaku.opacity,
                      min: 0.2,
                      max: 1.0,
                      divisions: 8,
                      display: '${(_danmaku.opacity * 100).round()}%',
                      onChanged: (v) {
                        final next = _danmaku.copyWith(opacity: v);
                        setState(() => _danmaku = next);
                        LocalStore.setDanmaku(next);
                      },
                    ),
                  ],
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
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.notifications_active_outlined,
                    title: '收藏更新提醒',
                    subtitle: _updateFreqLabel,
                    trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                    onTap: _pickUpdateFreq,
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
                    icon: Icons.cloud_sync_rounded,
                    title: 'WebDAV 同步',
                    subtitle: WebDavSync.hasConfig
                        ? '已配置 ${WebDavSync.config!['url']}'
                        : '多端同步书架 / 进度 / 设置',
                    onTap: _openWebDav,
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
              delay: const Duration(milliseconds: 220),
              child: _SectionLabel(label: '关于'),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 280),
              child: _SettingsCard(
                children: [
                  _SettingTile(
                    icon: Icons.article_outlined,
                    title: '免责声明',
                    subtitle: '内容来源与版权说明',
                    onTap: _showDisclaimer,
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.privacy_tip_outlined,
                    title: '隐私说明',
                    subtitle: '本地存储与网络请求',
                    onTap: _showPrivacy,
                  ),
                  Container(
                    height: 0.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                  _SettingTile(
                    icon: Icons.bug_report_outlined,
                    title: '导出错误日志',
                    subtitle: '崩溃 / 网络 / 解析错误的本地记录',
                    onTap: _exportLogs,
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
      ),
      ),
      ),
    );
  }

  /// 导出错误日志：合并本地日志为文本文件，供用户反馈问题时发送。
  /// 日志仅含崩溃/网络/解析错误与设备信息，不含书架/历史等用户数据。
  Future<void> _exportLogs() async {
    try {
      final path = await ErrorLogger.instance.exportLogs();
      if (path == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂无日志可导出')),
          );
        }
        return;
      }
      final result = await FilePicker.saveFile(
        dialogTitle: '导出错误日志',
        fileName: '星漫匣_日志_${DateTime.now().millisecondsSinceEpoch}.txt',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (result == null) return;
      File(result).writeAsBytesSync(File(path).readAsBytesSync());
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

  /// 导出备份：收集所有数据并保存为 JSON 文件。
  /// 手势配置弹窗：左侧/中间/右侧点击区域各自的三选一。
  Future<void> _showGestureSettings() async {
    final cfg = await LocalStore.gestureConfig();
    if (!mounted) return;
    showResponsiveBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _GestureSettingsSheet(initial: cfg),
    );
  }

  /// 备份口令输入框。allowSkip 时“跳过加密”返回空串（导出明文备份）；
  /// 取消（或导入场景）返回 null。
  Future<String?> _askBackupPassword(
      {required String title, String? prompt, bool allowSkip = false}) async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final pwd = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (prompt != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  prompt,
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                ),
              ),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '密码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          if (allowSkip)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('跳过加密'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isEmpty) {
                messenger
                    .showSnackBar(const SnackBar(content: Text('密码不能为空')));
                return;
              }
              Navigator.of(ctx).pop(controller.text);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return pwd;
  }

  Future<void> _exportBackup() async {
    try {
      final data = await LocalStore.collectBackup(
        bookshelfData: BookshelfStore.exportData(),
        novelShelfData: NovelShelfStore.exportData(),
      );
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final password = await _askBackupPassword(
        title: '备份加密（可选）',
        prompt: '输入密码后导出的备份将被加密保存；密码丢失将无法恢复。也可跳过加密直接导出。',
        allowSkip: true,
      );
      if (password == null) return; // 用户取消
      final out = password.isEmpty ? json : BackupCipher.encrypt(json, password);
      final result = await FilePicker.saveFile(
        dialogTitle: '导出备份',
        fileName: password.isEmpty
            ? '星漫匣_备份_${DateTime.now().millisecondsSinceEpoch}.json'
            : '星漫匣_备份_${DateTime.now().millisecondsSinceEpoch}_enc.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null) return;
      File(result).writeAsStringSync(out);
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

  /// 导入备份：从 JSON 文件恢复数据。检测加密备份并提示输入密码。
  Future<void> _importBackup() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择备份文件',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.single.path == null) return;
    try {
      var json = File(result.files.single.path!).readAsStringSync();
      if (json.trimLeft().startsWith(BackupCipher.magic)) {
        final password = await _askBackupPassword(
          title: '备份已加密',
          prompt: '该备份文件已用密码加密，请输入导出时设置的密码。',
        );
        if (password == null) return; // 取消导入
        try {
          json = BackupCipher.decrypt(json, password);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('密码错误或文件已损坏')),
            );
          }
          return;
        }
      }
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

    /// 收藏更新提醒频率选择。
  Future<void> _pickUpdateFreq() async {
    final v = await showDialog<UpdateFreq>(
      context: context,
      builder: (ctx) => SimpleDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('收藏更新提醒'),
        children: [
          for (final f in UpdateFreq.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(f),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _updateFreq == f
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      size: 18,
                      color: _updateFreq == f
                          ? Theme.of(ctx).colorScheme.primary
                          : Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Text(f.label, style: const TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    await ShelfUpdater.setFrequency(v);
    if (!mounted) return;
    ShelfUpdater.instance.applyFrequency(v);
    setState(() => _updateFreq = v);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(v == UpdateFreq.off
            ? '已关闭收藏更新提醒'
            : '已开启：${v.label}自动检查收藏更新'),
        duration: const Duration(seconds: 2),
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

  /// 打开 WebDAV 同步配置面板。
  Future<void> _openWebDav() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _WebDavSheet(
        onChanged: () => setState(() {}), // 刷新「已配置」副标题
      ),
    );
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

  void _showDisclaimer() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('免责声明'),
        content: SingleChildScrollView(
          child: Text(
            '1. 本应用为开源学习项目，仅用于技术交流与个人学习，不提供任何影视、'
            '漫画、小说等内容的制作、上传或存储服务。\n\n'
            '2. 应用内所有内容（含图片、文字、视频链接等）均来自互联网公开站点，'
            '由多个第三方数据源自动抓取聚合呈现，版权归原作者/权利人所有。\n\n'
            '3. 应用不拥有、不控制、不审核任何第三方源站的内容，也不对源站内容'
            '的合法性、准确性、完整性作任何保证。\n\n'
            '4. 请勿使用本应用从事任何商业用途或侵犯他人合法权益的行为。'
            '因使用本应用或其聚合内容产生的任何纠纷与损失，应用开发者不承担任何责任。\n\n'
            '5. 如认为任何内容侵犯了您的合法权益，请通过源站渠道联系权利人下架，'
            '应用开发者会尽力配合处理。',
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  void _showPrivacy() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('隐私说明'),
        content: SingleChildScrollView(
          child: Text(
            '1. 书架、阅读历史、偏好设置等数据均只保存在本机，不上传任何服务器，'
            '支持随时导出/导入备份（JSON 文件由您自行保管）。\n\n'
            '2. 应用仅向您浏览的第三方内容源站发起网络请求，应用自身不收集'
            '您的任何个人信息。\n\n'
            '3. 更新检查仅向 GitHub Releases 请求版本信息，不发送任何个人数据。\n\n'
            '4. 若您在「网络工具」中配置了代理，之后的所有网络请求将通过该代理'
            '转发，请确保您的代理环境安全可信。',
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }
}

/// 主题色选择器：5 个种子色圆点，点击立即切换全局主题。
class _ThemeSelector extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;
  const _ThemeSelector({required this.current, required this.onChanged});

  static const _names = ['墨(默认)', '墨蓝', '翡翠', '靛蓝', '薰衣草'];

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
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: scheme.primary,
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

/// 带图标标题 + 滑条 + 当前值显示的设置项（用于字号/速度/透明度等数值调节）。
class _SliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
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
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
          SizedBox(
            width: 150,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
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
    final maxH = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
                top:
                    BorderSide(color: scheme.onSurface.withValues(alpha: 0.1))),
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
                    color: scheme.onSurface.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('手势配置',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              const SizedBox(height: 4),
              Text('点击阅读器三等分区域触发的操作',
                  style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.5))),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final r in _regions) ...[
                        _regionRow(r, scheme),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
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
      ),
    );
  }

  Widget _regionRow(String region, ColorScheme scheme) {
    final current = _cfg[region] ?? 'toggleMenu';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_regionLabels[region] ?? region,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.85))),
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
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.14),
          ),
        ),
        child: Text(
          _actionLabels[action] ?? action,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// WebDAV 同步配置面板：服务器地址 / 账号 / 目录 / 加密开关 / 上传下载。
class _WebDavSheet extends StatefulWidget {
  final VoidCallback onChanged;
  const _WebDavSheet({required this.onChanged});

  @override
  State<_WebDavSheet> createState() => _WebDavSheetState();
}

class _WebDavSheetState extends State<_WebDavSheet> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();
  bool _encrypt = true;
  bool _busy = false;
  String? _status;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    final c = WebDavSync.config;
    if (c != null) {
      _urlCtrl.text = c['url'] as String? ?? '';
      _userCtrl.text = c['username'] as String? ?? '';
      _passCtrl.text = c['password'] as String? ?? ''; // hasPassword 占位时为空
      _dirCtrl.text = c['dir'] as String? ?? '';
      _encrypt = (c['encrypt'] as bool?) ?? true;
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() fn,
      {String ok = ''}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await fn();
      if (mounted) {
        setState(() {
          _status = ok.isEmpty ? '完成' : ok;
          _statusOk = true;
        });
      }
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '$label失败：$e';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() {
        _status = '请填写 WebDAV 服务器地址';
        _statusOk = false;
      });
      return;
    }
    WebDavSync.saveConfig(
      url: url,
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      dir: _dirCtrl.text.trim(),
      encrypt: _encrypt,
    );
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_sync_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'WebDAV 同步',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '把收藏、阅读进度、设置同步到你的 WebDAV 网盘\n'
              '（坚果云 / Nextcloud / 群晖 WebDAV 等），实现多端同步。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://dav.jianguoyun.com/dav/',
                prefixIcon: Icon(Icons.link_rounded, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _userCtrl,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码 / 应用密码',
                      prefixIcon: Icon(Icons.key_rounded, size: 20),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _dirCtrl,
              decoration: const InputDecoration(
                labelText: '保存目录（可选）',
                hintText: 'Apps/星漫匣',
                prefixIcon: Icon(Icons.folder_outlined, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '加密同步文件（AES-256-GCM，口令不落盘）',
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ),
                Switch(
                  value: _encrypt,
                  onChanged: (v) => setState(() => _encrypt = v),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存配置'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _run('上传',
                        () => WebDavSync.push(),
                        ok: '已上传到 WebDAV'),
                    icon: const Icon(Icons.upload_rounded, size: 18),
                    label: const Text('上传同步'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _confirmPull(),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('从 WebDAV 拉取并覆盖本地'),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: (_statusOk ? scheme.primary : scheme.error)
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _statusOk ? Icons.check_circle_outline : Icons.error_outline,
                      size: 18,
                      color: _statusOk ? scheme.primary : scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status!,
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmPull() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('拉取远端数据'),
        content: const Text('将用 WebDAV 上的数据覆盖本地的收藏、历史、进度和设置。'
            '本地上传之后的新改动会被覆盖，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('拉取并覆盖'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run('拉取', () async {
      await WebDavSync.pull();
      await WebDavSync.recordPull();
    }, ok: '已从 WebDAV 恢复数据');
  }
}
