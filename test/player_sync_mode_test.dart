import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/player_sync_mode.dart';

/// 同步模式选型决策（[decideSyncMode]）回归测试。
///
/// 覆盖修复线 3「视频/动漫播放」的倍速治理核心：显示时钟不可靠或音轨
/// 缺失时退回 audio 同步（恒 1 倍速），绝不进 display-resample。
void main() {
  group('decideSyncMode 显示时钟区间', () {
    test('正常 60Hz + 有音轨 → display-resample', () {
      final d = decideSyncMode(
        edispRaw: '60.000000',
        aidRaw: '1',
        audioChannelsRaw: '2',
        degraded: false,
      );
      expect(d.usesDisplayResample, isTrue);
      expect(d.mode, 'display-resample');
    });

    test('120Hz 高刷 + 有音轨 → display-resample', () {
      final d = decideSyncMode(
        edispRaw: '120.000000',
        aidRaw: '1',
        audioChannelsRaw: '2',
        degraded: false,
      );
      expect(d.usesDisplayResample, isTrue);
    });

    test('30Hz 下限边界可放行', () {
      final d = decideSyncMode(
        edispRaw: '30',
        aidRaw: '1',
        audioChannelsRaw: '2',
        degraded: false,
      );
      expect(d.usesDisplayResample, isTrue);
    });

    test('250Hz 上限边界可放行', () {
      final d = decideSyncMode(
        edispRaw: '250',
        aidRaw: '1',
        audioChannelsRaw: '2',
        degraded: false,
      );
      expect(d.usesDisplayResample, isTrue);
    });

    test('低于 30Hz（0/15）→ audio', () {
      expect(
          decideSyncMode(
            edispRaw: '0',
            aidRaw: '1',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
      expect(
          decideSyncMode(
            edispRaw: '15',
            aidRaw: '1',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
    });

    test('高于 250Hz（419/525 实测垃圾值）→ audio', () {
      expect(
          decideSyncMode(
            edispRaw: '419',
            aidRaw: '1',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
      expect(
          decideSyncMode(
            edispRaw: '525',
            aidRaw: '1',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
      expect(
          decideSyncMode(
            edispRaw: '4211',
            aidRaw: '1',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
    });

    test('空串/解析失败（?）→ audio', () {
      expect(
          decideSyncMode(
            edispRaw: '',
            aidRaw: '1',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
      expect(
          decideSyncMode(
            edispRaw: 'ERR(property not found)',
            aidRaw: '1',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
    });
  });

  group('decideSyncMode 音轨感知', () {
    test('无音轨（aid=no）→ audio', () {
      final d = decideSyncMode(
        edispRaw: '60',
        aidRaw: 'no',
        audioChannelsRaw: '2',
        degraded: false,
      );
      expect(d.mode, 'audio');
      expect(d.hasAudio, isFalse);
    });

    test('aid 为空 → audio', () {
      expect(
          decideSyncMode(
            edispRaw: '60',
            aidRaw: null,
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
    });

    test('aid=0（整数轨道号 0）→ audio', () {
      expect(
          decideSyncMode(
            edispRaw: '60',
            aidRaw: '0',
            audioChannelsRaw: '2',
            degraded: false,
          ).mode,
          'audio');
    });

    test('aid 非 no 但 channels 读不到/为 0/ERR → audio（设备被占场景）', () {
      expect(
          decideSyncMode(
            edispRaw: '60',
            aidRaw: '1',
            audioChannelsRaw: '',
            degraded: false,
          ).mode,
          'audio');
      expect(
          decideSyncMode(
            edispRaw: '60',
            aidRaw: '1',
            audioChannelsRaw: '0',
            degraded: false,
          ).mode,
          'audio');
      expect(
          decideSyncMode(
            edispRaw: '60',
            aidRaw: '1',
            audioChannelsRaw: 'ERR(property not found)',
            degraded: false,
          ).mode,
          'audio');
    });
  });

  group('decideSyncMode 墙钟降级覆盖', () {
    test('degraded=true 无视正常 edisp+音轨 → 强制 audio', () {
      final d = decideSyncMode(
        edispRaw: '60',
        aidRaw: '1',
        audioChannelsRaw: '2',
        degraded: true,
      );
      expect(d.mode, 'audio');
      expect(d.degraded, isTrue);
      // 决策仍如实记录探测值，供日志归因。
      expect(d.hasAudio, isTrue);
      expect(d.dispFps, 60.0);
    });

    test('degraded=true 且 edisp 本就垃圾 → audio（信息保留）', () {
      final d = decideSyncMode(
        edispRaw: '525',
        aidRaw: 'no',
        audioChannelsRaw: '',
        degraded: true,
      );
      expect(d.mode, 'audio');
      expect(d.dispFps, 525.0);
      expect(d.hasAudio, isFalse);
    });
  });
}
