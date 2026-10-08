import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';

import '../../net/error_logger.dart';
import '../../utils/colorizer_manager.dart';
import '../widgets/app_toast.dart';
import '../widgets/motion.dart';
import '../widgets/row_separator.dart';
import '../widgets/settings_row.dart';
import 'settings_widgets.dart';

/// 漫画上色设置区（本地 AI）：开关 + 模型导入/卸载。
///
/// 自包含状态：不依赖本页其它开关。约束（用户评审要求）：
/// - 默认关；开关写 LocalStore（ColorizerManager.enabled）；
/// - web / 无模型 / RAM<4GB 低端机 → 入口禁用并给出原因副标题；
/// - 模型由用户自放/导入（不内置，公开仓库红线），选中 .tflite 后复制
///   到应用文档目录并热加载。
class ColorizerSection extends StatefulWidget {
  const ColorizerSection({super.key});

  @override
  State<ColorizerSection> createState() => ColorizerSectionState();
}

class ColorizerSectionState extends State<ColorizerSection> {
  final ColorizerManager _m = ColorizerManager.instance;
  bool _enabled = false;
  String? _subtitle; // 状态说明（禁用原因 / 模型路径）
  bool _busy = false;
  bool _lowEnd = false; // 低端机（RAM<4GB）：隐藏导入入口

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final isWeb = kIsWeb;
    try {
      await _m.restore();
      await _m.ensureLoaded();
      final lowEnd = await ColorizerManager.isLowEndDevice();
      if (!mounted) return;
      setState(() {
        _lowEnd = lowEnd;
        _enabled = _m.enabled && _m.isAvailable;
        _subtitle = switch ((isWeb, lowEnd, _m.isAvailable, _m.modelPath)) {
          (true, _, _, _) => 'Web 端不支持本地 AI 推理',
          (false, true, _, _) => '低端机（内存 < 4GB）不可用',
          (false, false, false, _) => '未导入模型（需 .tflite）',
          (false, false, true, final p?) =>
            '模型：${p.split('\\').last.split('/').last}',
          _ => '已启用，可在阅读器内使用',
        };
      });
    } catch (e) {
      ErrorLogger.instance.warn('colorizer refresh failed: $e');
      if (mounted) {
        setState(() => _subtitle = '模型状态读取失败');
      }
    }
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      await _m.setEnabled(on);
    } catch (e) {
      ErrorLogger.instance.warn('colorizer toggle failed: $e');
      if (mounted) {
        AppToast.error(context, '上色功能切换失败，请重试');
      }
    }
    if (!mounted) return;
    setState(() {
      _enabled = on && _m.isAvailable;
      _busy = false;
    });
  }

  Future<void> _pickModel() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择上色模型文件',
      type: FileType.custom,
      allowedExtensions: ['tflite', 'tflite.zip'],
    );
    if (result == null || result.files.single.path == null) return;
    setState(() => _busy = true);
    final ok = await _m.importModel(result.files.single.path!);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _enabled = _m.enabled && _m.isAvailable;
        _subtitle = '模型加载成功，可在阅读器内使用';
      } else {
        _subtitle = '模型导入失败（文件无效或损坏）';
      }
    });
    if (ok) {
      AppToast.info(context, '上色模型已导入');
    } else {
      AppToast.error(context, '模型导入失败');
    }
  }

  Future<void> _unload() async {
    await _m.unload();
    if (!mounted) return;
    setState(() {
      _enabled = false;
      _subtitle = '未导入模型（需 .tflite）';
    });
  }

  @override
  Widget build(BuildContext context) {
    // 开关需模型就绪；导入入口仅需平台可用（web 无 FFI、低端机禁用）。
    final canUse = _m.isAvailable && !kIsWeb && !_lowEnd;
    final canManage = !kIsWeb && !_lowEnd;
    return FadeSlideIn(
      delay: const Duration(milliseconds: 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel(label: '漫画上色'),
          const SizedBox(height: 6),
          SettingsCard(
            children: [
              SettingsRow(
                icon: Icons.palette_rounded,
                title: '灰度漫画自动上色',
                subtitle: _subtitle ?? '检测模型…',
                trailing: Switch(
                  value: _enabled,
                  onChanged: (canUse && !_busy) ? _toggle : null,
                ),
              ),
              if (canManage) ...[
                RowSeparator(),
                SettingsRow(
                  icon: Icons.file_download_rounded,
                  title: '导入上色模型',
                  subtitle:
                      _m.modelPath != null
                          ? '已加载，点击可替换'
                          : '选择 .tflite 文件（AnimeGAN/DDColor 等）',
                  enabled: !_busy,
                  onTap: _pickModel,
                ),
                if (_m.modelPath != null) ...[
                  RowSeparator(),
                  SettingsRow(
                    icon: Icons.delete_forever_rounded,
                    title: '卸载模型',
                    subtitle: '释放内存并禁用上色',
                    enabled: !_busy,
                    onTap: _unload,
                  ),
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }
}