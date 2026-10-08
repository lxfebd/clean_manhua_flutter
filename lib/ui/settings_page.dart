import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';

import '../net/backup_cipher.dart';
import '../net/bookshelf_store.dart';
import '../net/error_logger.dart';
import '../net/http_client.dart';
import '../net/local_store.dart';
import '../net/novel_chapter_cache.dart';
import '../net/novel_shelf_store.dart';
import '../net/shelf_updater.dart';
import '../net/update_checker.dart';
import '../net/update_notifier.dart';
import '../net/webdav_sync.dart';
import '../theme.dart';
import '../utils/danmaku.dart';
import 'reader_mode_geometry.dart';
import 'reader_prefs_providers.dart';
import 'reader_providers.dart';
import 'responsive.dart';
import 'style_scope.dart';
import 'theme_controller.dart';
import 'source_manage_page.dart';
import 'keyboard_shortcuts.dart';
import 'widgets/app_toast.dart';
import 'widgets/settings_row.dart';
import 'widgets/update_download_dialog.dart';
import 'widgets/motion.dart';
import 'widgets/row_separator.dart';
import 'settings/colorizer_section.dart';
import 'settings/gesture_settings_sheet.dart';
import 'settings/settings_widgets.dart';
import 'settings/webdav_sheet.dart';

/// 设置页：深色模式、阅读器翻页模式、清空下载/历史。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  int _readerMode = 1; // 0=纵向滚动，1=单页横向（默认），2=双页并排
  bool _rtl = false;
  bool _loaded = false;
  bool _loadError = false; // 本地设置读取失败（错误态可重试）
  bool _checking = false;
  DanmakuSettings _danmaku = const DanmakuSettings();
  UpdateFreq _updateFreq = UpdateFreq.off;
  bool _notifyEnabled = false;
  bool _trustSelfSigned = false;

  /// 主题/风格全局状态（Riverpod）：深色/种子色/风格三块 UI 直接 watch，
  /// 不再在页面维护本地镜像副本（旧 `_dark/_themeId/_uiStyleOverride` 已删）。
  ThemeState get _theme => ref.watch(themeControllerProvider);

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

  /// WebDAV 入口副标题：显示最近同步时间（空 = 从未同步）。
  String _webdavSyncText = '';

  Future<void> _load() async {
    try {
      final mode = await LocalStore.readerMode();
      final rtlPrefs =
          await ref.read(comicReaderPrefsProvider.notifier).resume();
      final dm = await LocalStore.danmakuSettings();
      final freq = await ShelfUpdater.frequency();
      final notify = await UpdateNotifier.enabled();
      _webdavSyncText = await _syncText();
      if (mounted) {
        setState(() {
          _readerMode = mode;
          _rtl = rtlPrefs.rtl;
          _danmaku = dm;
          _updateFreq = freq;
          _notifyEnabled = notify;
          _trustSelfSigned = Net.trustSelfSigned;
          _loaded = true;
          _loadError = false;
        });
      }
    } catch (_) {
      // 本地读取异常（损坏/IO）：不永久转圈，显示错误态可重试。
      if (mounted) {
        setState(() {
          _loaded = true;
          _loadError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => EscPopScope(child: _buildRoot(context));

  Widget _buildRoot(BuildContext context) {
    final theme = Theme.of(context);
    if (_loadError) {
      // 设置读取失败：错误态 + 重试，不再永久转圈。
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 44,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 12),
              Text(
                '设置加载失败',
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
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
                  Responsive.pagePadding(context),
                  14,
                  Responsive.pagePadding(context),
                  (Responsive.isTablet(context) ? 24 : 110),
                ),
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
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                size: 20,
                              ),
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.75,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '返回',
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.55,
                              ),
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
                    child: SectionLabel(label: '主题'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 140),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
                          icon: Icons.dark_mode_outlined,
                          title: '深色模式',
                          subtitle: '夜间阅读更护眼',
                          trailing: Switch(
                            value: _theme.themeMode == ThemeMode.dark,
                            onChanged: (v) {
                              ref
                                  .read(themeControllerProvider.notifier)
                                  .setDark(v);
                              LocalStore.setDarkMode(v);
                            },
                          ),
                        ),
                        RowSeparator(),
                        _ThemeSelector(
                          current: _theme.themeId,
                          onChanged: (v) {
                            ref
                                .read(themeControllerProvider.notifier)
                                .setThemeId(v);
                            LocalStore.setThemeId(v);
                          },
                        ),
                        RowSeparator(),
                        _UiStyleSelector(
                          current: _theme.uiStyleOverride,
                          autoLabel: UIStyle.forPlatform(
                            Theme.of(context).platform,
                          ).label,
                          onChanged: (v) {
                            ref
                                .read(themeControllerProvider.notifier)
                                .setUiStyle(v);
                            LocalStore.setUiStyle(v?.id);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 220),
                    child: SectionLabel(label: '数据源'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 280),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
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
                    child: SectionLabel(label: '阅读器'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 280),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
                          icon: Icons.swipe_right_alt_rounded,
                          title: '翻页模式',
                          subtitle:
                              _readerMode == 0
                                  ? '纵向滚动逐页'
                                  : (_readerMode == 1
                                      ? '单页横向翻页'
                                      : '双页并排（适合平板横屏）'),
                          trailing: PopupMenuButton<int>(
                            initialValue: _readerMode,
                            icon: const Icon(
                              Icons.unfold_more_rounded,
                              color: Colors.white70,
                            ),
                            onSelected: (v) async {
                              // 经全局 provider 写回：阅读器与设置页共享同一偏好源。
                              await ref
                                  .read(readerModeProvider.notifier)
                                  .setMode(ReaderMode.fromValue(v));
                              if (mounted) setState(() => _readerMode = v);
                            },
                            itemBuilder:
                                (_) => const [
                                  PopupMenuItem(value: 0, child: Text('纵向滚动')),
                                  PopupMenuItem(value: 1, child: Text('单页横向')),
                                  PopupMenuItem(value: 2, child: Text('双页并排')),
                                ],
                          ),
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.arrow_back_ios_new_rounded,
                          title: 'RTL 反向翻页（日漫）',
                          subtitle: _rtl ? '从右往左' : '从左往右',
                          trailing: Switch(
                            value: _rtl,
                            onChanged: (v) async {
                              await ref
                                  .read(comicReaderPrefsProvider.notifier)
                                  .update(rtl: v);
                              if (mounted) setState(() => _rtl = v);
                            },
                          ),
                        ),
                        RowSeparator(),
                        SettingsRow(
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
                    delay: const Duration(milliseconds: 300),
                    child: SectionLabel(label: '小说阅读器'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 360),
                    child: _NovelReaderPrefsCard(
                      prefs: ref.watch(novelReaderPrefsProvider),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 220),
                    child: SectionLabel(label: '播放器'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 280),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
                          icon: Icons.subtitles_rounded,
                          title: '弹幕',
                          subtitle:
                              _danmaku.on ? '已开启 · 数据源：弹弹 play' : '视频播放时显示评论弹幕',
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
                          RowSeparator(),
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
                          RowSeparator(),
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
                          RowSeparator(),
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
                    child: SectionLabel(label: '更新'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 280),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
                          icon: Icons.system_update_alt_rounded,
                          title: '检查更新',
                          subtitle: '从 GitHub Releases 获取最新版本',
                          trailing:
                              _checking
                                  ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : null,
                          onTap: _checkUpdate,
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.notifications_active_outlined,
                          title: '收藏更新提醒',
                          subtitle: _updateFreqLabel,
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                          ),
                          onTap: _pickUpdateFreq,
                        ),
                        // 系统通知走原生 MethodChannel（Android 通知栏），Web 端无实现
                        // 且系统通知语义不存在，直接隐藏该项（收藏更新提醒的应用内横幅仍可用）。
                        if (!kIsWeb) ...[
                          RowSeparator(),
                          SettingsRow(
                            icon: Icons.notifications_outlined,
                            title: '系统通知',
                            subtitle:
                                _notifyEnabled ? '更新时在通知栏提醒' : '关闭：仅应用内横幅提醒',
                            trailing: Switch(
                              value: _notifyEnabled,
                              onChanged: _toggleNotify,
                            ),
                            onTap: () => _toggleNotify(!_notifyEnabled),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 220),
                    child: SectionLabel(label: '网络'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 280),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
                          icon: Icons.verified_user_outlined,
                          title: '信任自签证书',
                          subtitle:
                              _trustSelfSigned
                                  ? '已开启：放行自签 HTTPS（家庭 NAS/自建服务器）'
                                  : '关闭：严格校验服务器证书（默认，更安全）',
                          trailing: Switch(
                            value: _trustSelfSigned,
                            onChanged: _toggleTrustSelfSigned,
                          ),
                          onTap:
                              () => _toggleTrustSelfSigned(!_trustSelfSigned),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 220),
                    child: SectionLabel(label: '数据'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 280),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
                          icon: Icons.backup_rounded,
                          title: '导出备份',
                          subtitle:
                              kIsWeb
                                  ? 'Web 端不支持（数据保存在浏览器本地）'
                                  : '书架、历史、设置 → JSON 文件',
                          enabled: !kIsWeb,
                          onTap: _exportBackup,
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.restore_rounded,
                          title: '导入备份',
                          subtitle: kIsWeb ? 'Web 端不支持' : '从 JSON 文件恢复数据',
                          enabled: !kIsWeb,
                          onTap: _importBackup,
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.cloud_sync_rounded,
                          title: 'WebDAV 同步',
                          subtitle:
                              !WebDavSync.hasConfig
                                  ? (kIsWeb ? 'Web 端不支持' : '多端同步书架 / 进度 / 设置')
                                  : (_webdavSyncText.isEmpty
                                      ? '已配置 ${WebDavSync.config!['url']}'
                                      : '$_webdavSyncText · ${WebDavSync.config!['url']}'),
                          enabled: !kIsWeb,
                          onTap: _openWebDav,
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.download_outlined,
                          title: '清空全部下载',
                          subtitle: '删除已下载的章节图片，释放空间',
                          onTap:
                              () => _confirm(
                                title: '清空下载',
                                content: '确定清空所有已下载的章节？',
                                action: () async {
                                  await LocalStore.clearDownloads();
                                },
                                successMsg: '已清空下载',
                              ),
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.history_rounded,
                          title: '清空阅读历史',
                          subtitle: '清除所有阅读记录',
                          onTap:
                              () => _confirm(
                                title: '清空历史',
                                content: '确定清空所有阅读历史？',
                                action: () async {
                                  await LocalStore.clearHistory();
                                },
                                successMsg: '已清空历史',
                              ),
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.manage_search_rounded,
                          title: '清空搜索历史',
                          subtitle: '清除搜索框的历史关键词',
                          onTap:
                              () => _confirm(
                                title: '清空搜索历史',
                                content: '确定清空搜索历史关键词？',
                                action: () async {
                                  await LocalStore.clearSearchHistory();
                                },
                                successMsg: '已清空搜索历史',
                              ),
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.cleaning_services_outlined,
                          title: '清除小说缓存',
                          subtitle: '删除离线缓存的章节正文（断网兜底用）',
                          onTap:
                              () => _confirm(
                                title: '清除小说缓存',
                                content: '确定清除全部离线小说章节缓存？',
                                action: () async {
                                  await NovelChapterCache.clearAll();
                                },
                                successMsg: '已清除小说缓存',
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  // 漫画上色（本地 AI）：默认关、仅桌面端（电脑）可见——256×256
                  // 本地推理在手机端耗时/卡顿不达标，手机端隐藏入口（组件保留给
                  // 电脑端）。自包含状态组件，不与本页其它开关耦合。
                  if (DesktopUi.isDesktopPlatform) const ColorizerSection(),
                  const SizedBox(height: 28),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 220),
                    child: SectionLabel(label: '关于'),
                  ),
                  const SizedBox(height: 6),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 280),
                    child: SettingsCard(
                      children: [
                        SettingsRow(
                          icon: Icons.keyboard_alt_rounded,
                          title: '键盘快捷键',
                          subtitle: '全局 / 漫画阅读器 / 小说阅读器 / 视频播放器',
                          onTap:
                              () => Navigator.of(context).push(
                                PageRouteBuilder<void>(
                                  opaque: false,
                                  barrierColor: Colors.transparent,
                                  pageBuilder:
                                      (_, __, ___) =>
                                          const ShortcutHelpOverlay(),
                                ),
                              ),
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.article_outlined,
                          title: '免责声明',
                          subtitle: '内容来源与版权说明',
                          onTap: _showDisclaimer,
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.privacy_tip_outlined,
                          title: '隐私说明',
                          subtitle: '本地存储与网络请求',
                          onTap: _showPrivacy,
                        ),
                        RowSeparator(),
                        SettingsRow(
                          icon: Icons.bug_report_outlined,
                          title: '导出错误日志',
                          subtitle:
                              kIsWeb
                                  ? 'Web 端不支持（错误仅记录在浏览器控制台）'
                                  : '崩溃 / 网络 / 解析错误的本地记录',
                          enabled: !kIsWeb,
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
                                const ClipboardData(
                                  text: 'https://github.com/lxfebd',
                                ),
                              );
                              AppToast.info(context, '已复制 GitHub 地址');
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
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.12,
                              ),
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
          AppToast.info(context, '暂无日志可导出');
        }
        return;
      }
      // 移动端 saveFile 必须携带 bytes（桌面端仅弹出保存路径）。
      // 传 bytes 后 file_picker 会在用户选择的路径写入内容，全平台一致。
      final bytes = await File(path).readAsBytes();
      final result = await FilePicker.saveFile(
        dialogTitle: '导出错误日志',
        fileName: '星漫匣_日志_${DateTime.now().millisecondsSinceEpoch}.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      if (result == null) return;
      if (mounted) {
        AppToast.info(
          context,
          '已导出到 ${result.split('\\').last.split('/').last}',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '导出失败，请重试');
      }
      ErrorLogger.instance.warn('settings log export failed: $e');
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
      builder: (_) => GestureSettingsSheet(initial: cfg),
    );
  }

  /// 备份口令输入框。allowSkip 时“跳过加密”返回空串（导出明文备份）；
  /// 取消（或导入场景）返回 null。
  Future<String?> _askBackupPassword({
    required String title,
    String? prompt,
    bool allowSkip = false,
  }) async {
    final controller = TextEditingController();
    final pwd = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
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
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
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
                    AppToast.error(context, '密码不能为空');
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
      final out =
          password.isEmpty ? json : BackupCipher.encrypt(json, password);
      // 移动端 saveFile 必须携带 bytes，否则抛 ArgumentError；
      // 传 bytes 后 file_picker 会写入所选路径，全平台一致。
      final bytes = Uint8List.fromList(utf8.encode(out));
      final result = await FilePicker.saveFile(
        dialogTitle: '导出备份',
        fileName:
            password.isEmpty
                ? '星漫匣_备份_${DateTime.now().millisecondsSinceEpoch}.json'
                : '星漫匣_备份_${DateTime.now().millisecondsSinceEpoch}_enc.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (result == null) return;
      if (mounted) {
        AppToast.info(
          context,
          '已导出到 ${result.split('\\').last.split('/').last}',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '导出失败，请重试');
      }
      ErrorLogger.instance.warn('settings backup export failed: $e');
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
      var json = await File(result.files.single.path!).readAsString();
      if (BackupCipher.isEncrypted(json.trimLeft())) {
        final password = await _askBackupPassword(
          title: '备份已加密',
          prompt: '该备份文件已用密码加密，请输入导出时设置的密码。',
        );
        if (password == null) return; // 取消导入
        try {
          json = BackupCipher.decrypt(json, password);
        } catch (_) {
          if (mounted) {
            AppToast.error(context, '密码错误或文件已损坏');
          }
          return;
        }
      }
      final data = jsonDecode(json) as Map<String, dynamic>;
      if (data['version'] == null) {
        if (mounted) {
          AppToast.error(context, '无效的备份文件');
        }
        return;
      }
      // 覆盖确认：导入会用备份数据覆盖当前本地数据，不可恢复，必须二次确认。
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('导入备份'),
              content: const Text(
                '导入将覆盖当前本地的书架、阅读历史与设置数据，且不可撤销。\n\n确定继续吗？',
                style: TextStyle(fontSize: 13.5, height: 1.6),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('覆盖导入'),
                ),
              ],
            ),
      );
      if (confirmed != true) return; // 取消导入
      // 恢复书架
      if (data['bookshelf'] is Map) {
        BookshelfStore.importData(data['bookshelf'] as Map<String, dynamic>);
      }
      if (data['novel_shelf'] is Map) {
        NovelShelfStore.importData(data['novel_shelf'] as Map<String, dynamic>);
      }
      final count = await LocalStore.restoreBackup(data);
      if (mounted) {
        AppToast.info(
          context,
          '已恢复 $count 项数据（书架${data['bookshelf'] is Map ? ' +' : ''}${data['novel_shelf'] is Map ? '小说书架' : ''}）',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '恢复失败，请检查文件后重试');
      }
      ErrorLogger.instance.warn('settings backup restore failed: $e');
    }
  }

  /// 系统通知开关：开启时请求通知权限（Android 13+ 运行时弹窗）。
  Future<void> _toggleNotify(bool value) async {
    setState(() => _notifyEnabled = value);
    try {
      await UpdateNotifier.setEnabled(value);
      if (value) {
        await UpdateNotifier.instance.ensurePermission();
      }
    } catch (e) {
      // 权限被拒/存储失败：回滚开关并提示，避免状态与真实配置不一致。
      ErrorLogger.instance.warn('toggle notify failed: $e');
      if (mounted) {
        setState(() => _notifyEnabled = !value);
        AppToast.error(context, value ? '通知开启失败，请检查权限' : '通知关闭失败，请重试');
      }
      return;
    }
    if (mounted && value) {
      AppToast.show(
        context,
        '已开启：收藏更新时在通知栏提醒',
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// 信任自签证书开关：影响所有 HttpClient 的证书校验（默认不信任，防 MITM）。
  Future<void> _toggleTrustSelfSigned(bool value) async {
    setState(() => _trustSelfSigned = value);
    await Net.setTrustSelfSigned(value);
    if (mounted) {
      AppToast.show(
        context,
        value ? '已开启：信任自签证书（仅安全网络建议）' : '已关闭：严格校验服务器证书',
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// 收藏更新提醒频率选择。
  Future<void> _pickUpdateFreq() async {
    final v = await showDialog<UpdateFreq>(
      context: context,
      builder:
          (ctx) => SimpleDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
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
                          color:
                              _updateFreq == f
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
    AppToast.show(
      context,
      v == UpdateFreq.off ? '已关闭收藏更新提醒' : '已开启：${v.label}自动检查收藏更新',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await UpdateChecker.checkLatest();
      if (!mounted) return;
      if (info == null) {
        AppToast.info(context, '已是最新版本');
        return;
      }
      _showUpdateDialog(info);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '检查更新失败，请稍后重试');
      ErrorLogger.instance.warn('检查更新失败：$e');
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
      builder:
          (_) => WebDavSheet(
            onChanged: () async {
              _webdavSyncText = await _syncText();
              if (mounted) setState(() {});
            },
          ),
    );
  }

  /// 最近一次 WebDAV 同步时间文案（空 = 从未同步）。
  Future<String> _syncText() async {
    try {
      final ms = await WebDavSync.lastSyncMillis();
      if (ms <= 0) return '';
      final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
      final now = DateTime.now();
      String day;
      if (t.year == now.year && t.month == now.month && t.day == now.day) {
        day = '今天';
      } else if (t.isAfter(
        DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(const Duration(days: 1)),
      )) {
        day = '昨天';
      } else {
        day = '${t.month}月${t.day}日';
      }
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      return '上次同步：$day $hh:$mm';
    } catch (_) {
      return '';
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: Text('发现新版本 v${info.version}'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (info.notes != null && info.notes!.isNotEmpty) ...[
                    Text(info.notes!, style: const TextStyle(fontSize: 12.5)),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    '当前版本：v${UpdateChecker.currentVersion()}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(
                        ctx,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                  showUpdateDownloadDialog(
                    context,
                    info.apkUrl,
                    assetName: info.assetName,
                  );
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
      builder:
          (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
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
      try {
        await action();
      } catch (e) {
        ErrorLogger.instance.warn('settings confirm action failed: $e');
        if (mounted) {
          AppToast.error(context, '操作失败，请重试');
        }
        return;
      }
      if (mounted) {
        AppToast.info(context, successMsg);
      }
    }
  }

  void _showDisclaimer() {
    showDialog<void>(
      context: context,
      builder:
          (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
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
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.85),
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
      builder:
          (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
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
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.85),
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
              Icon(
                Icons.palette_outlined,
                size: 20,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 12),
              Text(
                '主题色',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
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
                          border:
                              current == i
                                  ? Border.all(
                                    color: scheme.onSurface,
                                    width: 2.5,
                                  )
                                  : null,
                          boxShadow:
                              current == i
                                  ? [
                                    BoxShadow(
                                      color: AppTheme.seedOf(
                                        i,
                                      ).withValues(alpha: 0.4),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                  : null,
                        ),
                        child:
                            current == i
                                ? const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 20,
                                )
                                : null,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _names[i],
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
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

/// UI 风格选择器：跟随平台 / 极简 / 小米 / 苹果。
///
/// `current == null` 表示「跟随平台」，副标题显示当前平台实际映射到的风格；
/// 点击选项立即生效（经 themeControllerProvider.setUiStyle 全树切换并持久化）。
class _UiStyleSelector extends StatelessWidget {
  final UIStyle? current;
  final String autoLabel;
  final ValueChanged<UIStyle?> onChanged;

  const _UiStyleSelector({
    required this.current,
    required this.autoLabel,
    required this.onChanged,
  });

  static const _options = <UIStyle?>[
    null,
    UIStyle.minimalist,
    UIStyle.xiaomi,
    UIStyle.apple,
  ];

  String _label(UIStyle? s) => s == null ? '跟随平台' : s.label;

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
              Icon(
                Icons.style_outlined,
                size: 20,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 12),
              Text(
                'UI 风格',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Text(
              current == null ? '当前：$autoLabel（按平台自适应）' : '当前：${current!.label}',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in _options) ...[
                Expanded(
                  child: _StyleOption(
                    label: _label(s),
                    selected: current == s,
                    onTap: () => onChanged(s),
                  ),
                ),
                if (s != _options.last) const SizedBox(width: 6),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _StyleOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _StyleOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.65),
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

/// 小说阅读器偏好设置卡（设置页入口；阅读器抽屉内同源同值）。
/// 直接 watch [novelReaderPrefsProvider]，改动经 notifier.update 写回——
/// 懒加载首读（resume）+ 相等短路（同值不写盘）都在 provider 内，这里
/// 只做纯展示与转发，不维护本地镜像副本。
class _NovelReaderPrefsCard extends ConsumerWidget {
  final NovelReaderPrefs prefs;
  const _NovelReaderPrefsCard({required this.prefs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(novelReaderPrefsProvider.notifier);
    return SettingsCard(
      children: [
        _SliderTile(
          icon: Icons.format_size_rounded,
          title: '字号',
          value: prefs.fontSize.toDouble(),
          min: 13,
          max: 28,
          divisions: 15,
          display: '${prefs.fontSize}',
          onChanged: (v) =>
              notifier.update(fontSize: v.round()),
        ),
        RowSeparator(),
        _SliderTile(
          icon: Icons.format_line_spacing_rounded,
          title: '行距',
          value: prefs.lineHeight.toDouble(),
          min: 120,
          max: 240,
          divisions: 24,
          display: '${prefs.lineHeight}%',
          onChanged: (v) =>
              notifier.update(lineHeight: v.round()),
        ),
        RowSeparator(),
        _SliderTile(
          icon: Icons.space_bar_rounded,
          title: '段间距',
          value: prefs.paragraphGap.toDouble(),
          min: 6,
          max: 36,
          divisions: 30,
          display: '${prefs.paragraphGap}px',
          onChanged: (v) =>
              notifier.update(paragraphGap: v.round()),
        ),
        RowSeparator(),
        SettingsRow(
          icon: Icons.format_indent_increase_rounded,
          title: '首行缩进',
          subtitle: prefs.firstIndent ? '每段首行缩进两字' : '顶格排版',
          trailing: Switch(
            value: prefs.firstIndent,
            onChanged: (v) => notifier.update(firstIndent: v),
          ),
        ),
        RowSeparator(),
        _SliderTile(
          icon: Icons.gradient_rounded,
          title: '色温',
          value: prefs.colorTemp.toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          display: prefs.colorTemp == 0 ? '无' : '${prefs.colorTemp}',
          onChanged: (v) =>
              notifier.update(colorTemp: v.round()),
        ),
        RowSeparator(),
        SettingsRow(
          icon: Icons.palette_outlined,
          title: '纸色主题',
          subtitle: switch (prefs.theme) {
            1 => '米白',
            2 => '浅绿',
            3 => '深青',
            _ => '跟随系统',
          },
          trailing: PopupMenuButton<int>(
            initialValue: prefs.theme,
            icon: const Icon(Icons.unfold_more_rounded),
            onSelected: (v) => notifier.update(theme: v),
            itemBuilder:
                (_) => const [
                  PopupMenuItem(value: 0, child: Text('跟随系统')),
                  PopupMenuItem(value: 1, child: Text('米白')),
                  PopupMenuItem(value: 2, child: Text('浅绿')),
                  PopupMenuItem(value: 3, child: Text('深青')),
                ],
          ),
        ),
      ],
    );
  }
}




