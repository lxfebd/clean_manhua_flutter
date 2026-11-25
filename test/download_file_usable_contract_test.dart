import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/atomic_file.dart';

/// P1-08「0 字节不算已下载」的调用点一致性棘轮。
///
/// 背景（审计自查发现的真缺陷）：语义改成 fileIsUsable（存在**且非空**）之后，
/// 有三处旧写法没同步——下载器的「跳过已下」判定和动漫卡片的「文件在」判定
/// 仍在用 existsSync。后果是**下载器跳过、渲染器拒绝**：0 字节页永远不再
/// 重下，也永远不显示，用户看到的是一张永久缺失的图（只能手动删记录重下）。
///
/// 这类 bug 的特征是「改了语义、漏改调用点」，编译和现有测试都抓不到，/// 所以用源码棘轮把不变量钉死。
void main() {
  String codeOnly(String p) => File(p)
      .readAsStringSync()
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  const paths = <String>[
    'lib/net/download_manager.dart',
    'lib/ui/bookshelf_download_view.dart',
  ];

  group('下载判定必须用 fileIsUsable', () {
    for (final p in paths) {
      test('$p：不得对下载产物用 existsSync', () {
        expect(File(p).existsSync(), isTrue, reason: '文件必须存在');
        final code = codeOnly(p);
        final bad = RegExp(r'.*existsSync\(\)')
            .allMatches(code)
            .map((m) => m.group(0)!)
            .toList();
        expect(bad, isEmpty,
            reason: '下载产物判定一律用 fileIsUsable（0 字节 = 未完成），'
                '发现：$bad');
      });
    }

    test('两个文件都必须真的用到 fileIsUsable（否则棘轮空转）', () {
      for (final p in paths) {
        expect(File(p).readAsStringSync(), contains('fileIsUsable'),
            reason: '$p 应当使用 fileIsUsable');
      }
    });

    test('fileIsUsable 本身语义正确：0 字节/目录 → false', () {
      final d = Directory.systemTemp.createTempSync('xmx_usable_');
      try {
        File('${d.path}/a.jpg').writeAsBytesSync(const []);
        expect(fileIsUsable('${d.path}/a.jpg'), isFalse,
            reason: '0 字节不算可用');
        File('${d.path}/b.jpg').writeAsBytesSync(List<int>.filled(128, 1));
        expect(fileIsUsable('${d.path}/b.jpg'), isTrue);
        expect(fileIsUsable(d.path), isFalse, reason: '目录不算可用文件');
        expect(fileIsUsable('${d.path}/missing.jpg'), isFalse);
      } finally {
        d.deleteSync(recursive: true);
      }
    });
  });
}
