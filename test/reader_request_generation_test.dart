import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P1-19 阅读图请求代际的源码契约回归。
///
/// 背景：`_CachedReaderImageState._load` 有 5 个以上 await 点（代理解析 →
/// 降级链 → 裁边 → 等滑动停止 → 超分 → 上色），每个之后都直接写 `_bytes`。
/// 没有代际校验时，旧 url 的迟到响应会覆盖新 url 的图（纵向滚动 widget 复用
/// 时这个窗口经常出现），表现为「第 3 页显示第 5 页的图」。
///
/// 私有 State 的时序难以在 widget 测试里稳定复现（需要可控的乱序 Future），
/// 故用与 design_tokens_test / reader_keepalive_test 同构的源码棘轮锁住契约。
void main() {
  String codeOnly(String text) => text
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final src = codeOnly(File('lib/ui/reader_widgets.dart').readAsStringSync());

  group('P1-19 请求代际契约', () {
    test('源码文件必须存在', () {
      expect(File('lib/ui/reader_widgets.dart').existsSync(), isTrue);
    });

    test('_CachedReaderImageState 必须有 _loadGen 字段', () {
      expect(src.contains('int _loadGen = 0;'), isTrue,
          reason: '代纪计数器是整套机制的基础');
    });

    test('_load 开头必须捕获本次代际', () {
      expect(src.contains('final gen = ++_loadGen;'), isTrue,
          reason: '不捕获就无法在 await 之后比对');
    });

    test('每个 await 之后的 mounted 检查都必须同时校验代际', () {
      // 只查 mounted 不查代际 = 旧请求仍会写状态。
      final bare = RegExp(r'if \(!mounted\) return;').allMatches(src).length;
      expect(bare, 0,
          reason: '阅读图加载路径上不允许出现「只看 mounted」的守卫');
      final guarded =
          RegExp(r'if \(!mounted \|\| gen != _loadGen\) return;')
              .allMatches(src)
              .length;
      expect(guarded, greaterThanOrEqualTo(5),
          reason: '至少覆盖：代理解析/降级链/裁边/等滑动停止/写字节 五个 await 点，'
              '实际找到 $guarded 处');
    });

    test('写 _bytes 的三处都必须校验代际', () {
      // setState 前必须有代际守卫（含 `mounted && gen == _loadGen` 形式）。
      final writes =
          RegExp(r'_bytes = (display|sr|colored)\b').allMatches(src);
      expect(writes.length, greaterThanOrEqualTo(3));
      final guardedWrites =
          RegExp(r'gen == _loadGen').allMatches(src).length;
      expect(guardedWrites, greaterThanOrEqualTo(3),
          reason: '写字节的三条路径都要有代纪守卫，实际 $guardedWrites 处');
    });

    test('换 url 时必须作废在途请求并复位状态', () {
      expect(src.contains('_loadGen++'), isTrue,
          reason: 'didUpdateWidget 里要递增代际作废旧请求');
      expect(src.contains('_bytes = null;'), isTrue,
          reason: '不复位字节，旧图会继续显示且不显示占位');
      expect(src.contains('_colorized = false;'), isTrue,
          reason: '不复位上色标记，新图会被误判为「已上色」而跳过推理');
    });

    test('失败态也必须是代际感知的', () {
      expect(src.contains('if (mounted && gen == _loadGen) {'), isTrue,
          reason: '旧代际的失败不许把新图标成失败态，也不该触发它的自动重试');
    });
  });
}
