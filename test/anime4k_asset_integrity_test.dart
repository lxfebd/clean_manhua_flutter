// Anime4K shader 资产完整性回归测试。
//
// 背景（2026-09-14）：`assets/anime4k/` 下三个 Upscale shader 的首行被一次
// 批量编辑改坏成 `/ MIT License`（少了一个斜杠）。
//
// ⚠️ **实测结论（别再沿用错误说法）**：这**不是**功能缺陷。本机 mpv 真机实测
// （见 `星漫匣_画质能力诊断_2026-09-14.md` 附录，探针 v2）：
//   * 刻意把 shader 正文写坏 → mpv 立刻报
//     `fragment shader compile log (status=0): ERROR: ...`；
//   * 首行写成 `/ MIT License`（正文完好）→ **全程零报错，pass 照跑**。
// 说明首个 `//!` 指令之前的文本不会进入 GLSL 正文。当初"该行导致编译失败、
// 超分链整条失效"的判断是错的。
//
// 那为什么还留这个测试？资产被无意义地改坏本身就是隐患（谁也不知道下一次
// 批量编辑会伤到哪里），而这类改动当时**没有任何测试或构建期校验**能发现
// （文件存在、字节数正常、git 只显示 1 行）。本测试把「shader 文件必须是
// 合法、未被截断的 mpv 用户着色器」变成硬门槛：
// * 首行必须是 `//` 注释（防再出现半截注释符）；
// * 任何行都不允许以单个 `/` 开头；
// * 必须含 `//!HOOK` / `//!BIND` 指令（防被整体清空/截断）；
// * 不得带 UTF-8 BOM；
// * 每个 UI 档位引用的 shader 文件都必须真实存在；
// * Upscale 链的 WHEN 阈值必须与 Anime4KManager.upsampleWhenThreshold 一致。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/utils/anime4k.dart';

void main() {
  const assetDir = 'assets/anime4k';

  /// 收集 levels 里引用到的全部 shader 文件名（去重，保持稳定顺序）。
  List<String> referencedShaders() {
    final names = <String>{};
    for (final preset in Anime4KManager.levels) {
      names.addAll(preset.shaders);
    }
    final list = names.toList()..sort();
    return list;
  }

  group('assets/anime4k 资产完整性', () {
    test('pubspec 已声明 assets/anime4k/ 目录', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('assets/anime4k/'),
          reason: '未在 pubspec 声明 → rootBundle.load 会失败，超分静默失效');
    });

    test('每个档位引用的 shader 文件都存在且非空', () {
      final missing = <String>[];
      for (final name in referencedShaders()) {
        final f = File('$assetDir/$name');
        if (!f.existsSync() || f.lengthSync() == 0) missing.add(name);
      }
      expect(missing, isEmpty, reason: '档位引用了不存在的 shader：$missing');
    });

    test('shader 首行是 `//` 注释，且不存在单斜杠开头的行', () {
      final bad = <String>[];
      for (final name in referencedShaders()) {
        final f = File('$assetDir/$name');
        if (!f.existsSync()) continue;
        final bytes = f.readAsBytesSync();
        // BOM 检查
        if (bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF) {
          bad.add('$name: 带 UTF-8 BOM（mpv 首个 //! 指令会被污染）');
          continue;
        }
        final lines = const Utf8Decoder(allowMalformed: true)
            .convert(bytes)
            .split('\n');
        final first = lines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        if (!first.trimLeft().startsWith('//')) {
          bad.add('$name: 首行不是注释 → `${first.trim()}`');
        }
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trimLeft();
          // 单个 `/` 开头 = 非法（注释必须是 `//`）；行文本里出现
          // 编程性斜杠（如 WHEN 的 `/`）不受影响——只查行首。
          if (l.startsWith('/') && !l.startsWith('//')) {
            bad.add('$name:${i + 1}: 单斜杠开头 → `${l.trim()}`');
          }
        }
      }
      expect(bad, isEmpty,
          reason: 'shader 含非法 GLSL 行，会导致 mpv 编译失败、超分链失效：\n'
              '${bad.join('\n')}');
    });

    test('shader 含 mpv 必需指令（HOOK / BIND），未被截断', () {
      final bad = <String>[];
      for (final name in referencedShaders()) {
        final f = File('$assetDir/$name');
        if (!f.existsSync()) continue;
        final text = const Utf8Decoder(allowMalformed: true)
            .convert(f.readAsBytesSync());
        if (!text.contains('//!HOOK')) bad.add('$name: 缺 //!HOOK');
        if (!text.contains('//!BIND')) bad.add('$name: 缺 //!BIND');
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('Upscale 链的 WHEN 阈值 == Anime4KManager.upsampleWhenThreshold', () {
      // 这条防「代码判定」与「shader 实际行为」漂移：界面/诊断用
      // Anime4KManager.srChainEligible 判断"放大链会不会跑"，它必须与
      // shader 里 //!WHEN 写的字面阈值一致，否则又会出现"界面说生效、
      // 实际没跑"（或反之）的谎报。
      final threshold = Anime4KManager.upsampleWhenThreshold;
      expect(threshold, lessThan(1.0),
          reason: '阈值必须严格小于 1.0：mpv 用严格大于比较，'
              'OUTPUT==MAIN 时比值为精确 1.0，`1.0 > 1.0` 为假会让链被静默跳过');
      final bad = <String>[];
      for (final preset in Anime4KManager.levels) {
        for (final name in preset.shaders) {
          if (!name.contains('Upscale')) continue;
          final f = File('$assetDir/$name');
          if (!f.existsSync()) continue;
          final text = const Utf8Decoder(allowMalformed: true)
              .convert(f.readAsBytesSync());
          final whenLines = const LineSplitter()
              .convert(text)
              .where((l) => l.trimLeft().startsWith('//!WHEN'))
              .toList();
          if (whenLines.isEmpty) {
            bad.add('$name: 没有任何 //!WHEN 行');
            continue;
          }
          for (final line in whenLines) {
            final ths = RegExp(r'([0-9]*\.?[0-9]+)\s*>')
                .allMatches(line)
                .map((m) => double.parse(m.group(1)!))
                .toList();
            if (ths.isEmpty) {
              bad.add('$name: WHEN 行里找不到 `数字 >` 形式的阈值 → $line');
              continue;
            }
            for (final t in ths) {
              if (t != threshold) {
                bad.add('$name: 阈值 $t ≠ $threshold → $line');
              }
            }
          }
        }
      }
      expect(bad, isEmpty,
          reason: 'shader 阈值与代码常量不一致（改一处必须同时改另一处）：\n'
              '${bad.join('\n')}');
    });
  });
}
