import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/atomic_file.dart';

/// P1-08 原子写的实测回归（真文件系统、临时目录）。
///
/// 这条测试直接验证「进程被杀不会留下半截文件」的机制：写盘走 .part，
/// 完成后 rename。残留的 .part 与 0 字节目标文件都不得被当成有效数据。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xmx_atomic_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String p(String name) => dir.path + Platform.pathSeparator + name;

  group('writeFileAtomic', () {
    test('写入成功：字节一致且不残留 .part', () async {
      final target = p('a.img');
      final ok = await writeFileAtomic(target, utf8.encode('完整内容123'));
      expect(ok, isTrue);
      expect(File(target).existsSync(), isTrue);
      expect(File(target).readAsStringSync(), '完整内容123');
      expect(File('$target.part').existsSync(), isFalse,
          reason: '成功后 .part 必须已被 rename 吃掉');
    });

    test('覆盖已存在文件：内容为新内容（不是追加/拼接）', () async {
      final target = p('b.img');
      await writeFileAtomic(target, utf8.encode('旧内容比较长一点'));
      await writeFileAtomic(target, utf8.encode('新'));
      expect(File(target).readAsStringSync(), '新');
      expect(File(target).lengthSync(), utf8.encode('新').length);
    });

    test('历史遗留的半截 part 不会缝进新文件', () async {
      final target = p('c.img');
      // 模拟旧实现/上一次崩溃残留的半截 part（带唯一后缀的那一版）。
      File('$target.part.999').writeAsStringSync('上一次崩溃残留的半截数据');
      await writeFileAtomic(target, utf8.encode('干净'));
      expect(File(target).readAsStringSync(), '干净',
          reason: '新文件必须只含本次写入的完整字节');
      expect(File('$target.part.1').existsSync(), isFalse,
          reason: '本次自己产生的 part 必须已被 rename 吃掉');
    });

    test('父目录不存在时自动创建', () async {
      final target = p('nested${Platform.pathSeparator}deep${Platform.pathSeparator}d.img');
      final ok = await writeFileAtomic(target, utf8.encode('x'));
      expect(ok, isTrue);
      expect(File(target).existsSync(), isTrue);
    });

    test('目标路径被目录占用 → 返回 false 且不残留 .part', () async {
      final target = p('blocked.img');
      Directory(target).createSync(); // 用目录占住目标路径，写必失败
      final ok = await writeFileAtomic(target, utf8.encode('x'));
      expect(ok, isFalse, reason: '失败必须显式返回，调用方才知道这页没写成');
      expect(File('$target.part').existsSync(), isFalse,
          reason: '失败也要清理 .part，别把垃圾留在缓存目录');
    });

    test('并发写同一路径：最终内容必是其中一份完整数据', () async {
      final target = p('race.img');
      await Future.wait([
        for (var i = 0; i < 8; i++)
          writeFileAtomic(target, utf8.encode('内容${i.toString() * 20}')),
      ]);
      final text = File(target).readAsStringSync();
      // 每个写者的载荷形状是「内容」+ 同一个数字重复 20 次；缝起来必然破形。
      expect(RegExp(r'^内容(\d)\1*$').hasMatch(text), isTrue,
          reason: '并发写不得把多份数据缝在一起，实际：$text');
      expect(text.length, 22,
          reason: '长度也必须等于单份载荷（2 + 20），缝一起会变长');
    });
  });

  group('fileIsUsable', () {
    test('不存在 → false', () {
      expect(fileIsUsable(p('missing.img')), isFalse);
    });

    test('0 字节 → false（不能当成有效页）', () {
      final f = File(p('empty.img'));
      f.writeAsStringSync('');
      expect(f.existsSync(), isTrue);
      expect(fileIsUsable(f.path), isFalse,
          reason: '0 字节只会来自异常路径，旧实现把它当成已下载');
    });

    test('非空 → true', () {
      final f = File(p('ok.img'));
      f.writeAsStringSync('abcd');
      expect(fileIsUsable(f.path), isTrue);
    });

    test('目录 → false', () {
      final d = Directory(p('adir'));
      d.createSync();
      expect(fileIsUsable(d.path), isFalse);
    });
  });
}
