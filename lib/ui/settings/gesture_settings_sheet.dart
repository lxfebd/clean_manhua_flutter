import 'package:flutter/material.dart';

import '../../net/error_logger.dart';
import '../../net/local_store.dart';
import '../widgets/app_toast.dart';

/// 手势配置底部抽屉：左侧 / 中间 / 右侧各选一个动作。
class GestureSettingsSheet extends StatefulWidget {
  final Map<String, String> initial;
  const GestureSettingsSheet({super.key, required this.initial});

  @override
  State<GestureSettingsSheet> createState() => GestureSettingsSheetState();
}

class GestureSettingsSheetState extends State<GestureSettingsSheet> {
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
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.1)),
            ),
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
              Text(
                '手势配置',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '点击阅读器三等分区域触发的操作',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
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
                    try {
                      await LocalStore.setGestureConfig(_cfg);
                    } catch (e) {
                      ErrorLogger.instance.warn(
                        'save gesture config failed: $e',
                      );
                      if (context.mounted) {
                        AppToast.error(context, '手势配置保存失败，请重试');
                      }
                      return;
                    }
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
        Text(
          _regionLabels[region] ?? region,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
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
          color:
              active
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                active
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