import 'dart:async';

import 'capability_plugin.dart';
import 'capability_plugin_manager.dart';
import 'capability_runtime.dart';

/// 演示能力：章节字数统计（M1 框架验证用，纯 Dart 无原生依赖）。
///
/// 目的不是功能本身，而是验证「能力插件」全流程可走通：
/// 注册 → 启用 → acquire → run(Isolate 隔离) → 禁用 → 卸载。
/// 统计逻辑在 [Isolate.run] 内执行，长文本也不卡主线程。
///
/// 接入方式：作为内置能力由 CapabilityPluginManager 注册（非市场条目），
/// 后续真实能力（AI 上色/插帧）走同一接口，仅实现正文不同。
class ChapterStatsPlugin extends CapabilityPlugin {
  ChapterStatsPlugin()
      : super(
          id: 'utility.stats',
          name: '阅读统计',
          category: 'utility',
          version: '1.0.0',
          author: '星漫匣内置',
          description: '本地阅读统计（纯本地计算，不上传）',
          builtin: true,
        );

  /// 计算章节字数（供外部调用，走 CapabilityRuntime 隔离执行）。
  static Future<CapabilityResult> countWords(String text) {
    return CapabilityRuntime.instance.run('utility.stats', () {
      // Isolate.run 要求闭包可发送：这里只捕获 String 并返回 Map。
      final trimmed = text.trim();
      if (trimmed.isEmpty) {
        return <String, dynamic>{'chars': 0, 'words': 0, 'paragraphs': 0};
      }
      final chars = trimmed.replaceAll(RegExp(r'\s'), '').length;
      final words = trimmed
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .length;
      final paragraphs =
          trimmed.split(RegExp(r'\n+')).where((p) => p.trim().isNotEmpty).length;
      return <String, dynamic>{
        'chars': chars,
        'words': words,
        'paragraphs': paragraphs,
      };
    });
  }
}

/// 注册内置能力（main 启动时调用，幂等）。
Future<void> registerBuiltinCapabilities() async {
  final mgr = CapabilityPluginManager.instance;
  // 幂等：重复调用 install 对同 id 忽略。
  await mgr.install(ChapterStatsPlugin());
}
