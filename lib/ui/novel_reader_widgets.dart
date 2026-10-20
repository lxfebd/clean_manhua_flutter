part of 'novel_reader_page.dart';

class _NovelReaderSettingsSheet extends StatefulWidget {
  final int fontSize;
  final int lineHeight;
  final int theme;
  final int paragraphGap;
  final bool firstIndent;
  final int colorTemp;
  final ValueChanged<int> onFontSize;
  final ValueChanged<int> onLineHeight;
  final ValueChanged<int> onTheme;
  final ValueChanged<int> onParagraphGap;
  final ValueChanged<bool> onFirstIndent;
  final ValueChanged<int> onColorTemp;
  final double brightness;
  final ValueChanged<double> onBrightness;
  const _NovelReaderSettingsSheet({
    required this.fontSize,
    required this.lineHeight,
    required this.theme,
    required this.paragraphGap,
    required this.firstIndent,
    required this.colorTemp,
    required this.brightness,
    required this.onFontSize,
    required this.onLineHeight,
    required this.onTheme,
    required this.onParagraphGap,
    required this.onFirstIndent,
    required this.onColorTemp,
    required this.onBrightness,
  });

  @override
  State<_NovelReaderSettingsSheet> createState() =>
      _NovelReaderSettingsSheetState();
}

class _NovelReaderSettingsSheetState
    extends State<_NovelReaderSettingsSheet> {
  static const _sizes = [14, 16, 17, 18, 20, 22];
  static const _heights = [150, 160, 170, 180, 190, 200];
  static const _themeNames = ['跟随', '米白', '浅绿', '深青'];
  static const _gaps = [8, 14, 18, 24, 30];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1))),
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('阅读设置',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(
                        fontWeight: FontWeight.w700,
                        color:
                            Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 18),
            _row('字号',
                children: [
                  for (final s in _sizes)
                    _opt(s.toString(), s == widget.fontSize, () {
                      widget.onFontSize(s);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('行距',
                children: [
                  for (final h in _heights)
                    _opt('${h / 100}', h == widget.lineHeight, () {
                      widget.onLineHeight(h);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('背景',
                children: [
                  for (var i = 0; i < _themeNames.length; i++)
                    _opt(_themeNames[i], i == widget.theme, () {
                      widget.onTheme(i);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('段间距',
                children: [
                  for (final g in _gaps)
                    _opt('$g', g == widget.paragraphGap, () {
                      widget.onParagraphGap(g);
                      setState(() {});
                    }),
                ]),
            const SizedBox(height: 14),
            _row('首行缩进',
                children: [
                  _opt('关', !widget.firstIndent, () {
                    widget.onFirstIndent(false);
                    setState(() {});
                  }),
                  _opt('开（2字符）', widget.firstIndent, () {
                    widget.onFirstIndent(true);
                    setState(() {});
                  }),
                ]),
            const SizedBox(height: 14),
            // 色温无级调节：0 = 无色温，100 = 最暖（约 3000K）。
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('色温',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.85),
                            )),
                    const SizedBox(width: 8),
                    Text(
                      widget.colorTemp == 0
                          ? '关闭'
                          : '${(6500 - widget.colorTemp * 35)}K',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor:
                        Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.15),
                    thumbColor: Theme.of(context).colorScheme.primary,
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10),
                  ),
                  child: Slider(
                    value: widget.colorTemp.toDouble(),
                    max: 100,
                    divisions: 20,
                    label: widget.colorTemp == 0
                        ? '关闭'
                        : '${(6500 - widget.colorTemp * 35)}K',
                    onChanged: (v) {
                      widget.onColorTemp(v.round());
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // 阅读亮度：真实调系统亮度，失败时由阅读器黑纱遮罩降级模拟。
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('亮度',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.85),
                            )),
                    const SizedBox(width: 8),
                    Text(
                      '${(widget.brightness * 100).round()}%',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor:
                        Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.15),
                    thumbColor: Theme.of(context).colorScheme.primary,
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10),
                  ),
                  child: Slider(
                    value: widget.brightness,
                    max: 1.0,
                    divisions: 20,
                    label: '${(widget.brightness * 100).round()}%',
                    onChanged: (v) {
                      widget.onBrightness(v);
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, {required List<Widget> children}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.85),
                )),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: children,
        ),
      ],
    );
  }

  Widget _opt(String label, bool active, VoidCallback onTap) {
    return ReaderSettingsChip(
      label: label,
      active: active,
      onTap: onTap,
      dark: false,
    );
  }
}

/// 朗读设置抽屉：语速档位（0.5x ~ 2x）。
class _NovelTtsSheet extends StatelessWidget {
  final int rateIdx;
  final ValueChanged<int> onRate;
  const _NovelTtsSheet({required this.rateIdx, required this.onRate});

  @override
  Widget build(BuildContext context) {
    final rates = NovelTtsService.rates;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1))),
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('朗读设置',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(
                        fontWeight: FontWeight.w700,
                        color:
                            Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 18),
            Row(
              children: [
                Text('语速',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.85),
                        )),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < rates.length; i++)
                        _TtsRateChip(
                          label: '${rates[i]}x',
                          active: i == rateIdx,
                          onTap: () => onRate(i),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TtsRateChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TtsRateChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
/// 本章摘要底部面板：标题 + 摘要句列表 + 免责说明。
class _SummarySheet extends StatelessWidget {
  final String title;
  final List<String> sentences;

  const _SummarySheet({required this.title, required this.sentences});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('本章摘要',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                const Spacer(),
                Text('本地生成',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(
                            color: scheme.onSurface
                                .withValues(alpha: 0.45))),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 14),
            if (sentences.isEmpty)
              Text('本章暂无内容可摘要',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6)))
            else
              for (var i = 0; i < sentences.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: scheme.primary),
                      ),
                      Expanded(
                        child: Text(
                          sentences[i],
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                height: 1.55,
                                color: scheme.onSurface
                                    .withValues(alpha: 0.85),
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 6),
            Text(
              '摘要由本地算法生成，仅作快速回顾参考。',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.4)),
            ),
          ],
        ),
      ),
    );
  }
}

