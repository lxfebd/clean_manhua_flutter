import 'package:flutter/material.dart';

import '../reader_mode_geometry.dart';
import '../responsive.dart';
import '../style_tokens.dart';

/// 阅读设置抽屉共用的选项按钮（chip）：active 高亮、inactive 弱化。
///
/// 漫画阅读器（[ReaderSettingsSheet]）与小说阅读器（_NovelReaderSettingsSheet）
/// 共用同一份样式；[dark] 区分两种抽屉的配色：
/// - dark = true（漫画）：抽屉固定深色底，前景恒白，防浅色主题白底白字；
/// - dark = false（小说）：前景跟随主题色。
class ReaderSettingsChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool dark;
  final double fontSize;
  final double paddingV;

  const ReaderSettingsChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.dark = true,
    this.fontSize = 12,
    this.paddingV = 10,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color fg, fgWeak, border, activeFg;
    if (dark) {
      // 深色抽屉：固定白色前景（同 ReaderSettingsSheet 的历史修复——浅色主题
      // 下用 scheme.surface 会白底白字完全看不见，必须恒白）。
      fg = Colors.white;
      fgWeak = Colors.white70;
      border = Colors.white.withValues(alpha: 0.1);
      activeFg = Colors.white;
    } else {
      fg = scheme.onSurface;
      fgWeak = scheme.onSurface.withValues(alpha: 0.85);
      border = scheme.onSurface.withValues(alpha: 0.1);
      activeFg = scheme.onPrimary;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(StyleTokens.controlRadiusOr(context, 8)),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: paddingV),
        decoration: BoxDecoration(
          color: active ? scheme.primary : (dark ? Colors.white.withValues(alpha: 0.06) : fgWeak.withValues(alpha: 0.06)),
          borderRadius: BorderRadius.circular(StyleTokens.controlRadiusOr(context, 8)),
          border: Border.all(color: active ? scheme.primary : border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? activeFg : (dark ? fgWeak : fg),
          ),
        ),
      ),
    );
  }
}

/// 阅读设置抽屉（S6）：亮度滑块 + 翻页模式 + 画质 + 自动翻页 + 目录/章节/下载。
class ReaderSettingsSheet extends StatefulWidget {
  final ReaderMode readerMode;
  final double dim;
  final int resLevel;
  final int autoPage;
  final bool trimBorder;
  final ValueChanged<double> onDimChanged;
  final ValueChanged<ReaderMode> onModeChanged;
  final ValueChanged<int> onResLevelChanged;
  final ValueChanged<int> onAutoPageChanged;
  final ValueChanged<bool> onTrimBorderChanged;
  final VoidCallback onCatalog;

  /// 章内切换章节（章节列表非空时才可用）。
  final VoidCallback? onSelectChapter;
  final VoidCallback? onDownload;
  const ReaderSettingsSheet({
    super.key,
    required this.readerMode,
    required this.dim,
    required this.resLevel,
    required this.autoPage,
    required this.trimBorder,
    required this.onDimChanged,
    required this.onModeChanged,
    required this.onResLevelChanged,
    required this.onAutoPageChanged,
    required this.onTrimBorderChanged,
    required this.onCatalog,
    this.onSelectChapter,
    this.onDownload,
  });

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late double _localDim;
  late int _localResLevel;
  late ReaderMode _localMode;
  late int _localAutoPage;
  late bool _localTrimBorder;

  @override
  void initState() {
    super.initState();
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localMode = widget.readerMode;
    _localAutoPage = widget.autoPage;
    _localTrimBorder = widget.trimBorder;
  }

  @override
  void didUpdateWidget(covariant ReaderSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _localDim = widget.dim;
    _localResLevel = widget.resLevel;
    _localMode = widget.readerMode;
    _localAutoPage = widget.autoPage;
    _localTrimBorder = widget.trimBorder;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.pagePadding(context), 16, Responsive.pagePadding(context), 28),
      // 固定深色背景：阅读器本身是黑底图片查看器，弹窗用深色与整体一致，
      // 且无论 App 是浅色/深色主题，白色文字都必定可读
      // （原先用 scheme.surface，浅色主题下变成白底白字，完全看不见）。
      decoration: BoxDecoration(
        color: const Color(0xFF1C1B1F),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
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
          Text('阅读设置',
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: 12),
          // 内容区可滚动：亮度+翻页+画质+自动翻页+按钮在横屏平板上
          // 容易超出 BottomSheet 默认高度（原溢出 ~129px）。
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
          // 亮度
          Row(
            children: [
              const Icon(Icons.light_mode_rounded,
                  size: 16, color: Colors.white70),
              const SizedBox(width: 10),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: scheme.primary,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                    thumbColor: Colors.white,
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 8),
                  ),
                  child: Slider(
                    value: _localDim,
                    onChanged: (v) {
                      setState(() => _localDim = v);
                      widget.onDimChanged(v);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('${(_localDim * 100).round()}%',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 14),
          // 翻页模式
          Text('翻页模式',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 8),
          Row(
            children: [
              _layoutOption('纵向滚动', _localMode == ReaderMode.vertical, () {
                setState(() => _localMode = ReaderMode.vertical);
                widget.onModeChanged(ReaderMode.vertical);
              }),
              const SizedBox(width: 8),
              _layoutOption('单页横向', _localMode == ReaderMode.single, () {
                setState(() => _localMode = ReaderMode.single);
                widget.onModeChanged(ReaderMode.single);
              }),
              const SizedBox(width: 8),
              _layoutOption('双页并排', _localMode == ReaderMode.double, () {
                setState(() => _localMode = ReaderMode.double);
                widget.onModeChanged(ReaderMode.double);
              }),
            ],
          ),
          const SizedBox(height: 16),
          // 画质（真超分 = Lanczos-3 2x 上采样）
          Text('画质增强',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
          const SizedBox(height: 8),
          Row(
            children: [
              _resOption('原图', 0, _localResLevel, () {
                setState(() => _localResLevel = 0);
                widget.onResLevelChanged(0);
              }),
              const SizedBox(width: 6),
              _resOption('平滑', 1, _localResLevel, () {
                setState(() => _localResLevel = 1);
                widget.onResLevelChanged(1);
              }),
              const SizedBox(width: 6),
              _resOption('高清(2x)', 2, _localResLevel, () {
                setState(() => _localResLevel = 2);
                widget.onResLevelChanged(2);
              }),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '「高清(2x)」= 真实 Lanczos-3 超分（Isolate 内 2x 上采样），首张慢、之后秒开',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 16),
          // 自动翻页
          Text('自动翻页',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 8),
          Row(
            children: [
              _autoOption('关闭', 0, _localAutoPage, () {
                setState(() => _localAutoPage = 0);
                widget.onAutoPageChanged(0);
              }),
              const SizedBox(width: 6),
              _autoOption('5秒', 5, _localAutoPage, () {
                setState(() => _localAutoPage = 5);
                widget.onAutoPageChanged(5);
              }),
              const SizedBox(width: 6),
              _autoOption('10秒', 10, _localAutoPage, () {
                setState(() => _localAutoPage = 10);
                widget.onAutoPageChanged(10);
              }),
              const SizedBox(width: 6),
              _autoOption('20秒', 20, _localAutoPage, () {
                setState(() => _localAutoPage = 20);
                widget.onAutoPageChanged(20);
              }),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '开启后自动翻页，触摸屏幕或显示菜单时暂停',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 16),
          // 自动裁边去白边
          InkWell(
            onTap: () {
              setState(() => _localTrimBorder = !_localTrimBorder);
              widget.onTrimBorderChanged(_localTrimBorder);
            },
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _localTrimBorder
                        ? Icons.crop_free_rounded
                        : Icons.crop_free_rounded,
                    size: 17,
                    color: _localTrimBorder
                        ? scheme.primary
                        : Colors.white70,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('自动裁边去白边',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                  Switch(
                    value: _localTrimBorder,
                    activeThumbColor: scheme.primary,
                    onChanged: (v) {
                      setState(() => _localTrimBorder = v);
                      widget.onTrimBorderChanged(v);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '开启后自动识别并去除漫画页四周白边，最大化内容显示面积',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ghostBtn('目录', Icons.list_alt_rounded,
                    () => widget.onCatalog()),
              ),
              const SizedBox(width: 8),
              if (widget.onSelectChapter != null) ...[
                Expanded(
                  child: _ghostBtn('章节', Icons.menu_book_rounded,
                      () => _showChapterPicker()),
                ),
                const SizedBox(width: 8),
              ],
              if (widget.onDownload != null)
                Expanded(
                  child: _ghostBtn('下载本话', Icons.download_outlined,
                      () => widget.onDownload!()),
                ),
            ],
          ),
        ],
      ),
    ),
  ),
        ],
      ),
    );
  }

  /// 章内切换：展示章节列表底部弹窗。
  void _showChapterPicker() {
    final cb = widget.onSelectChapter;
    if (cb == null) return;
    Navigator.of(context).pop(); // 关闭设置抽屉
    cb();
  }

  Widget _layoutOption(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: ReaderSettingsChip(
        label: label,
        active: active,
        onTap: onTap,
        dark: true,
        fontSize: 13,
        paddingV: 11,
      ),
    );
  }

  Widget _resOption(String label, int value, int current, VoidCallback onTap) {
    return Expanded(
      child: ReaderSettingsChip(
        label: label,
        active: value == current,
        onTap: onTap,
        dark: true,
      ),
    );
  }

  /// 自动翻页选项按钮（复用画质选项风格）。
  Widget _autoOption(String label, int value, int current, VoidCallback onTap) =>
      _resOption(label, value, current, onTap);

  Widget _ghostBtn(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: Colors.white),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 13, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
