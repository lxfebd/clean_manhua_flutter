part of 'settings_page.dart';

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
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
          borderRadius: BorderRadius.circular(R.control),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
              borderRadius: BorderRadius.circular(
                StyleTokens.controlRadiusOr(context, 10),
              ),
            ),
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
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




