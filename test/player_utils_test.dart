import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:xingmanxia/ui/player_utils.dart';

void main() {
  group('whLabel', () {
    test('宽×高文案', () {
      expect(whLabel(1920, 1080), '1920×1080');
      expect(whLabel(0, 0), '0×0');
    });
  });

  group('fmtFps', () {
    test('可解析：保留 2 位小数', () {
      expect(fmtFps('60'), '60.00');
      expect(fmtFps('59.940'), '59.94');
      expect(fmtFps('23.976023'), '23.98');
    });
    test('不可解析：原样返回，空串 → ?', () {
      expect(fmtFps('abc'), 'abc');
      expect(fmtFps(''), '?');
    });
  });

  group('ovrFps', () {
    test('纯数字（含小数）', () {
      expect(ovrFps('60.000000'), 60.0);
      expect(ovrFps('59.94'), 59.94);
      expect(ovrFps('0'), 0); // 非正数 → 0
      expect(ovrFps('-5'), 0);
    });
    test('分数形式 a/b', () {
      expect(ovrFps('60/1'), 60.0);
      expect(ovrFps('50/1'), 50.0);
      expect(ovrFps('1/0'), 0); // 分母非正 → 0
      expect(ovrFps('a/b'), 0);
    });
    test('不可解析 → 0', () {
      expect(ovrFps(''), 0);
      expect(ovrFps('nan'), 0);
    });
  });

  group('trimSpeed', () {
    test('整数值：1 位小数', () {
      expect(trimSpeed(1.0), '1.0');
      expect(trimSpeed(2.0), '2.0');
      expect(trimSpeed(4.0), '4.0');
    });
    test('非整数值：原样', () {
      expect(trimSpeed(0.25), '0.25');
      expect(trimSpeed(1.5), '1.5');
      expect(trimSpeed(3.5), '3.5');
    });
  });

  group('audioTrackSubtitle', () {
    AudioTrack track({String? language, String? codec, String? channels, bool? isDefault}) =>
        AudioTrack(
          '1',
          't',
          language,
          codec: codec,
          channels: channels,
          isDefault: isDefault,
        );

    test('全部字段 → 语言 · 编码 · 声道 · 默认', () {
      final s = audioTrackSubtitle(
          track(language: 'ja', codec: 'aac', channels: '2.0', isDefault: true));
      expect(s, '语言 ja · aac · 2.0 · 默认');
    });
    test('部分字段：只显示非空项', () {
      expect(audioTrackSubtitle(track(language: 'zh')), '语言 zh');
      expect(audioTrackSubtitle(track(codec: 'opus')), 'opus');
    });
    test('全空 → null', () {
      expect(audioTrackSubtitle(track()), isNull);
    });
  });
}
