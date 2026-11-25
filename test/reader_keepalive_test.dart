import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 阅读器 keepAlive 门禁（P0-05：纵向阅读双层 keepAlive 导致页面 State 与
/// 图片字节无界保留）。
///
/// 做法与 design_tokens_test 的棘轮同构：扫源码断言「不得再出现
/// wantKeepAlive => true（或任何条件表达式）」。关闭 keepAlive 是安全的——
/// 图片走 ImageCacheManager 磁盘缓存，回翻是重读盘而非重新联网；但它会被
/// 「顺手加回来优化回翻」的改动破坏，所以必须有测试焊死。
///
/// 若未来确需按模式开启 keepAlive，请先有实测内存数据（100 页 ×3 章的
/// 第三章/第一章峰值 ≤1.2），再改这里并写清理由。
void main() {
  /// 阅读器相关源码（图片组件都住在这里）。
  const readerFiles = <String>[
    'lib/ui/reader_widgets.dart',
    'lib/ui/reader_page.dart',
  ];

  String normalize(String expr) =>
      expr.split('//').first.trim().replaceAll(RegExp(r'\s+'), '');

  /// 剥掉整行注释后再扫：否则文档注释里写的
  /// 「`wantKeepAlive => true` 的反例」会被正则当成真实代码。
  String codeOnly(String text) => text
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  group('阅读器 keepAlive 棘轮（P0-05）', () {
    test('源码文件必须存在（否则本测试静默失效）', () {
      for (final p in readerFiles) {
        expect(File(p).existsSync(), isTrue, reason: '缺 $p');
      }
    });

    test('阅读器侧不得再开启 keepAlive', () {
      final offenders = <String>[];
      for (final p in readerFiles) {
        final text = codeOnly(File(p).readAsStringSync());
        for (final m
            in RegExp(r'wantKeepAlive\s*=>\s*([^;]+);').allMatches(text)) {
          final v = normalize(m.group(1)!);
          if (v != 'false') {
            offenders.add('$p: wantKeepAlive => ${m.group(1)!.trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '长章内存与已读页数成正比会 OOM；请改回 false'
              '（图片已走磁盘缓存，回翻不重新联网）：\n${offenders.join('\n')}');
    });

    test('lib/ui 其他文件新增无条件 keepAlive 必须留名（白名单制）', () {
      // 白名单：书架用 wantKeepAlive=>true 保留 5 个 Tab 的滚动位置，
      // 页数有界（Tab 数），且每页仍是懒建的网格——与阅读器「长章无界
      // 累积」不是一类问题。新增条目必须同样是有界理由 + 实测数据，
      // 否则说明有人在把无界 keepAlive 扩散到别的页面。
      const allowlist = <String, String>{
        'lib/ui/bookshelf_page.dart': '5 个 Tab 各保留滚动位置，页数有界',
      };
      final hits = <String>[];
      for (final f
          in Directory('lib/ui').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final norm = f.path.replaceAll(r'\', '/');
        for (final m
            in RegExp(r'wantKeepAlive\s*=>\s*([^;]+);').allMatches(
                codeOnly(f.readAsStringSync()))) {
          if (normalize(m.group(1)!) == 'true' &&
              !allowlist.containsKey(norm)) {
            hits.add('$norm: 硬编码 true（未登记的有界理由）');
          }
        }
      }
      expect(hits, isEmpty,
          reason:
              '无条件 keepAlive 会无界驻留 State 与字节；需要时用有界策略'
                  '并附实测数据，再登记进 allowlist：\n${hits.join('\n')}');
    });
  });
}
