import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 桌面端快捷键总览面板（`?` 呼出）。
///
/// 只做静态展示：每组按“键位 → 动作”渲染，数据来自 [groupedShortcuts]。
/// 在当前路由之上弹一个半透明遮罩层，点遮罩或 Esc 关闭，不干扰 Navigator。
/// Esc 用全局 Keyboard handler 捕获：opaque:false 路由焦点仍在底层页面，
/// Navigator 的 DismissIntent 不会触发，必须自行处理。
class ShortcutHelpOverlay extends StatefulWidget {
  const ShortcutHelpOverlay({super.key});

  @override
  State<ShortcutHelpOverlay> createState() => _ShortcutHelpOverlayState();
}

class _ShortcutHelpOverlayState extends State<ShortcutHelpOverlay> {
  bool _escHandler(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_escHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_escHandler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 0.45),
        body: Center(
          child: Material(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: [
                        Icon(Icons.keyboard_alt_rounded,
                            size: 20, color: scheme.primary),
                        const SizedBox(width: 8),
                        Text('键盘快捷键',
                            style: Theme.of(context).textTheme.titleMedium),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final g in groupedShortcuts) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 12, bottom: 6),
                              child: Text(
                                g.label,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                            for (final s in g.items)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 190,
                                      child: Text(
                                        s.keys.join(' / '),
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures()
                                          ],
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        s.action,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: scheme.onSurface,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
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
}

class _ShortcutItem {
  final List<String> keys;
  final String action;
  const _ShortcutItem(this.keys, this.action);
}

class _ShortcutGroup {
  final String label;
  final List<_ShortcutItem> items;
  const _ShortcutGroup(this.label, this.items);
}

/// 快捷键总览数据：面板渲染 + 全局 `?` 面板两处共用，避免文案漂移。
const groupedShortcuts = <_ShortcutGroup>[
  _ShortcutGroup('全局', [
    _ShortcutItem(['Ctrl/Cmd + 1…7'], '切换主界面标签（首页/动漫/小说/书架/工具/我的）'),
    _ShortcutItem(['Ctrl/Cmd + ←', '后退'],
        'Ctrl/Cmd + →'),
    _ShortcutItem(['Ctrl/Cmd + F'], '全局搜索'),
    _ShortcutItem(['Ctrl/Cmd + R'], '刷新当前列表'),
    _ShortcutItem(['Alt + ←'], '返回上一页'),
    _ShortcutItem(['?'], '本快捷键面板'),
  ]),
  _ShortcutGroup('漫画阅读器', [
    _ShortcutItem(['←'], '上一页（RTL 漫画为下一页）'),
    _ShortcutItem(['→'], '下一页（RTL 漫画为上一页）'),
    _ShortcutItem(['Space'], '下一页'),
    _ShortcutItem(['+', '-'], '放大 / 缩小图片'),
    _ShortcutItem(['0'], '重置缩放'),
    _ShortcutItem(['B'], '书签当前页'),
    _ShortcutItem(['G'], '页面目录'),
    _ShortcutItem(['C'], '切换章节列表'),
    _ShortcutItem(['S'], '阅读设置'),
    _ShortcutItem(['L'], '放大镜'),
    _ShortcutItem(['Home'], '本章第一页'),
    _ShortcutItem(['End'], '本章最后一页'),
    _ShortcutItem(['Esc'], '隐藏 / 显示工具栏'),
  ]),
  _ShortcutGroup('小说阅读器', [
    _ShortcutItem(['←', '→'], '上一章 / 下一章'),
    _ShortcutItem(['Space', 'PgDn'], '向下滚动'),
    _ShortcutItem(['PgUp'], '向上滚动'),
    _ShortcutItem(['+', '-'], '增大 / 减小字号'),
    _ShortcutItem(['B'], '书签当前章'),
    _ShortcutItem(['G'], '章节目录'),
    _ShortcutItem(['S'], '阅读设置'),
    _ShortcutItem(['T'], '开始 / 暂停朗读'),
    _ShortcutItem(['Esc'], '返回'),
  ]),
  _ShortcutGroup('视频播放器', [
    _ShortcutItem(['Space'], '播放 / 暂停'),
    _ShortcutItem(['←', '→'], '快退 / 快进 10 秒'),
    _ShortcutItem(['↑', '↓'], '音量 + / -'),
    _ShortcutItem(['0…9'], '跳转到进度 0%…90%'),
    _ShortcutItem(['[', ']'], '减慢 / 加快倍速'),
    _ShortcutItem(['N', 'P'], '下一集 / 上一集'),
    _ShortcutItem(['M'], '静音'),
    _ShortcutItem(['T'], '音轨切换'),
    _ShortcutItem(['B'], '弹幕开关'),
    _ShortcutItem(['C'], '弹幕设置'),
    _ShortcutItem(['I'], '画中画'),
    _ShortcutItem(['F'], '全屏 / 退出全屏'),
    _ShortcutItem(['Esc'], '隐藏控制层 / 退出全屏'),
  ]),
];
