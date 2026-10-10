import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 修复「直链接管失败后的无限横跳」回归测试（源码审查）。
///
/// 背景：WebView 每 900ms 轮询捕获直链 → mpv 试开 → 失败 → `_webGeneration++`
/// 重建 WebView → 重新捕获（签名轮换的新 URL）→ 再 handoff → 再失败，
/// 构成无限循环（用户可见为反复横跳/抽搐）。旧防循环机制按「完整 URL 精确
/// 匹配」记忆失效直链（`_rejectedHandoffs` Set），签名每次刷新 URL 即 miss。
///
/// 修复为按资源键（scheme+host+path）计数失败的 `HandoffQuarantine`，闸门
/// 置于任何状态翻转之前。本测试断言该结构存在于源码中且顺序正确；运行时不
/// 可测（flutter_test 无原生 mpv/WebView2 引擎），按修复线 3/6 的既定做法用
/// 源码审查（见 [regression_line3_video_fix_test.dart]）。
void main() {
  final root = p.join('lib', 'ui', 'anime_player_page.dart');
  final native = p.join('lib', 'ui', 'native_player_page.dart');

  String animeSrc() => File(root).readAsStringSync();
  String nativeSrc() => File(native).readAsStringSync();

  group('直链接管失败隔离（防横跳）', () {
    test('隔离闸门先于状态翻转（闸门前置是防横跳的关键）', () {
      final src = nativeSrc();
      final fn = src.indexOf('Future<bool> _handoffWebToMpv(String src)');
      expect(fn, greaterThan(0));
      // 方法体内：闸门判定出现在卸载 WebView（_useWeb = false）之前。
      final gate = src.indexOf('_handoffQuarantine.isQuarantined(src)', fn);
      final flip = src.indexOf('setState(() => _useWeb = false);', fn);
      expect(gate, greaterThan(fn),
          reason: '隔离闸门需存在于 _handoffWebToMpv 方法内');
      expect(flip, greaterThan(gate),
          reason: '闸门必须在任何状态翻转之前——隔离达标后不得卸载 WebView');
    });

    test('旧的完整 URL 精确匹配记忆已删除（签名轮换不再失效）', () {
      final src = nativeSrc();
      expect(src.contains('_rejectedHandoffs'), isFalse,
          reason: '旧机制按完整 URL 精确匹配，签名轮换必 miss，已删除');
      expect(src.contains('_rememberRejectedHandoff'), isFalse);
    });

    test('失败计数与成功清除、换集清空均挂接隔离器', () {
      final src = nativeSrc();
      // 失败路径记数（error 监听分支 + handoff 失败分支）。
      expect(src.contains('_handoffQuarantine.recordFailure(_handoffSrc);'),
          isTrue,
          reason: 'error 监听分支需记录失败');
      expect(src.contains('_handoffQuarantine.recordFailure(src);'), isTrue,
          reason: 'handoff 失败分支需记录失败');
      // 成功接管清除该资源计数，换集清空全部。
      expect(src.contains('_handoffQuarantine.clear(src);'), isTrue,
          reason: '接管成功需清除该资源失败计数');
      expect(src.contains('_handoffQuarantine.resetAll();'), isTrue,
          reason: '换集后需清空隔离（新资源重新获得尝试机会）');
    });

    test('隔离器与 import 存在', () {
      final src = nativeSrc();
      expect(src.contains("import '../utils/handoff_quarantine.dart';"),
          isTrue);
      expect(src.contains('final HandoffQuarantine _handoffQuarantine'),
          isTrue);
    });

    test('anime 页失败分支直接回落 _resolving，不再重武装计时器', () {
      final src = animeSrc();
      // 定位 handoff 回调的失败分支（cb 之后的 else）。
      final afterCb = src.indexOf('final taken = await cb(src);');
      expect(afterCb, greaterThan(0));
      final elseIdx = src.indexOf('} else {', afterCb);
      expect(elseIdx, greaterThan(afterCb));
      // else 分支片段（~400 字符足够覆盖注释+回落）。
      final seg = src.substring(elseIdx, elseIdx + 400);
      // 直接回落：黑幕立即解除，网页立即可见可听。
      expect(seg.contains('setState(() => _resolving = false);'), isTrue,
          reason: '失败分支需直接回落 _resolving，不再等 8 秒超时');
      // 不再重武装计时器：旧逻辑会随签名刷新的轮询无限续期，黑幕永挂。
      expect(seg.contains('_resolveTimer = Timer'), isFalse,
          reason: '失败分支不得重新武装 8 秒计时器（无限续期）');
    });

    test('anime 页既有单次 8 秒超时仍在（initState 首载超时不被误删）', () {
      final src = animeSrc();
      // 防误删：initState / 切集处的单次《_resolveTimer = Timer(8s)…
      // 仍然必须存在（本轮只删了失败分支的重武装，未动首载超时）。
      expect(src.contains('_resolveTimer = Timer(const Duration(seconds: 8)'),
          isTrue,
          reason: '首载/切集的超时放弃计时器应保留');
    });
  });
}