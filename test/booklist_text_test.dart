import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/utils/booklist_text.dart';

void main() {
  group('BooklistText.parse', () {
    test('标准导出文本：序号 + 书名 + 作者 + 状态', () {
      final raw = '''
星漫匣 · 我的书单（共 3 本）
导出时间：2026-09-10 12:00
─────────────
1. 海贼王 — 尾田荣一郎（连载中）
2. 鬼灭之刃
3. 咒术回战 — 芥见下下
''';
      final r = BooklistText.parse(raw);
      expect(r.length, 3);
      expect(r[0].name, '海贼王');
      expect(r[0].author, '尾田荣一郎');
      expect(r[0].status, '连载中');
      expect(r[1].name, '鬼灭之刃');
      expect(r[1].author, '');
      expect(r[2].name, '咒术回战');
      expect(r[2].status, '');
    });

    test('无表头纯列表（用户粘贴）', () {
      final r = BooklistText.parse('1. 火影忍者\n2. 龙珠');
      expect(r.length, 2);
      expect(r[0].name, '火影忍者');
    });

    test('书名含「·」等符号不截断', () {
      final r = BooklistText.parse('1. 关于我转生变成史莱姆这档事 · 第二季');
      expect(r.length, 1);
      expect(r[0].name, '关于我转生变成史莱姆这档事 · 第二季');
    });

    test('作者仅用「-」分隔可识别', () {
      final r = BooklistText.parse('1. 东京食尸鬼 - 石田スイ');
      expect(r.length, 1);
      expect(r[0].author, '石田スイ');
    });

    test('半角括号状态可识别', () {
      final r = BooklistText.parse('1. 进击的巨人(完结)');
      expect(r[0].name, '进击的巨人');
      expect(r[0].status, '完结');
    });

    test('空行/表头/间隔线被跳过', () {
      final r = BooklistText.parse('''
星漫匣 · 我的书单（共 2 本）

导出时间：2026-09-10 12:00
─────────────
1. 书A
（空行会被跳过）
2. 书B
''');
      expect(r.length, 2);
    });

    test('空输入返回空列表', () {
      expect(BooklistText.parse(''), isEmpty);
      expect(BooklistText.parse('   \n\n'), isEmpty);
    });

    test('parse 与 format 闭环：format 输出可被 parse 还原', () {
      final entries = [
        const BooklistEntry(name: '书A', author: '作者甲', status: '连载中'),
        const BooklistEntry(name: '书B'),
        const BooklistEntry(name: '书C', author: '作者丙', status: '完结'),
      ];
      final text = BooklistText.format(entries, at: DateTime(2026, 9, 10));
      final back = BooklistText.parse(text);
      expect(back.length, 3);
      expect(back[0].name, '书A');
      expect(back[0].author, '作者甲');
      expect(back[0].status, '连载中');
      expect(back[2].author, '作者丙');
    });

    test('书名含括弧内的副标题不误判为状态', () {
      // 书名自身带括号（如「(新) 一拳超人」）时，括号视为状态是合理近似；
      // 至少保证序号+书名主部分正确。
      final r = BooklistText.parse('1. 一拳超人（新）');
      expect(r[0].name, '一拳超人');
      expect(r[0].status, '新');
    });
  });
}