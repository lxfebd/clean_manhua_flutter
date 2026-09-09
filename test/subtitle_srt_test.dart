import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/subtitle_srt.dart';

void main() {
  group('SubtitleSrt.parse 基础解析', () {
    test('标准 SRT 多区块', () {
      const raw = '''
1
00:00:01,000 --> 00:00:03,500
你好，世界

2
00:00:04,000 --> 00:00:06,000
第二句字幕

3
00:00:07,500 --> 00:00:09,000
第三句
多行文本
''';
      final cues = SubtitleSrt.parse(raw);
      expect(cues.length, 3);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 3500);
      expect(cues[0].text, '你好，世界');
      expect(cues[1].startMs, 4000);
      expect(cues[2].text, '第三句\n多行文本');
    });

    test('无序号 SRT（时间行在首行）', () {
      const raw = '''
00:00:01,000 --> 00:00:02,000
无序号字幕
''';
      final cues = SubtitleSrt.parse(raw);
      expect(cues.length, 1);
      expect(cues[0].text, '无序号字幕');
    });

    test('点号毫秒分隔 + 1/2 位毫秒', () {
      const raw = '''
1
00:00:01.5 --> 00:00:03.25
点号毫秒测试
''';
      final cues = SubtitleSrt.parse(raw);
      expect(cues.single.startMs, 1500);
      expect(cues.single.endMs, 3250);
    });

    test('CRLF 与 BOM 容错', () {
      final raw = '\uFEFF1\r\n00:00:01,000 --> 00:00:02,000\r\nBOM CRLF\r\n';
      final cues = SubtitleSrt.parse(raw);
      expect(cues.single.text, 'BOM CRLF');
    });

    test('空输入与无效区块跳过', () {
      expect(SubtitleSrt.parse(''), isEmpty);
      expect(SubtitleSrt.parse('没有时间轴的文本'), isEmpty);
      expect(
        SubtitleSrt.parse('''
1
00:00:01,000 --> 00:00:02,000
有效

垃圾区块，无时间轴
''').length,
        1,
      );
    });
  });

  group('SubtitleSrt.parseBytes 编码探测', () {
    test('UTF-8 BOM', () {
      final bytes = Uint8List.fromList(utf8.encode('\uFEFF1\n00:00:01,000 --> 00:00:02,000\n你好\n'));
      final cues = SubtitleSrt.parseBytes(bytes);
      expect(cues, isNotNull);
      expect(cues!.single.text, '你好');
    });

    test('UTF-16 LE BOM', () {
      // 用 utf16 编码器构造真实 UTF-16LE 字节（含 BOM），验证编码探测
      const srt = '1\n00:00:01,000 --> 00:00:02,000\n你好\n';
      final bytes = <int>[
        0xFF, 0xFE, // UTF-16 LE BOM
      ];
      for (final cu in srt.codeUnits) {
        bytes.add(cu & 0xFF);
        bytes.add((cu >> 8) & 0xFF);
      }
      final cues = SubtitleSrt.parseBytes(Uint8List.fromList(bytes));
      expect(cues, isNotNull);
      expect(cues!.single.startMs, 1000);
      expect(cues.single.text, '你好');
    });
  });

  group('SubtitleIndex 时间命中', () {
    test('at() 返回当前时刻字幕，越界返回 null', () {
      final idx = SubtitleIndex([
        const SubtitleCue(startMs: 1000, endMs: 3000, text: '一'),
        const SubtitleCue(startMs: 5000, endMs: 6000, text: '二'),
      ]);
      expect(idx.at(0), isNull);
      expect(idx.at(1000)?.text, '一');
      expect(idx.at(2999)?.text, '一');
      expect(idx.at(3000), isNull); // end 开区间
      expect(idx.at(5500)?.text, '二');
      expect(idx.at(6000), isNull);
    });

    test('乱序输入自动排序', () {
      final idx = SubtitleIndex([
        const SubtitleCue(startMs: 5000, endMs: 6000, text: '后'),
        const SubtitleCue(startMs: 1000, endMs: 2000, text: '先'),
      ]);
      expect(idx.cues.first.text, '先');
    });

    test('重叠字幕取最近开始', () {
      final idx = SubtitleIndex([
        const SubtitleCue(startMs: 1000, endMs: 5000, text: '长'),
        const SubtitleCue(startMs: 2000, endMs: 3000, text: '短'),
      ]);
      expect(idx.at(1500)?.text, '长');
      expect(idx.at(2500)?.text, '短');
    });
  });
}