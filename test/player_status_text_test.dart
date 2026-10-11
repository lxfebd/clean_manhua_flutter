import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/player_status_text.dart';

void main() {
  group('srBadgeLabel', () {
    test('档位 + 源分辨率', () {
      expect(srBadgeLabel('Anime4K x2', 1920, 1080, null), 'AI 超分 · Anime4K x2 · 1920×1080');
    });
    test('无源分辨率时不追加', () {
      expect(srBadgeLabel('Anime4K x2', 0, 0, null), 'AI 超分 · Anime4K x2');
    });
    test('eligible==false 时追加「缩小播放，仅修复」', () {
      expect(
        srBadgeLabel('Anime4K x2', 1920, 1080, false),
        'AI 超分 · Anime4K x2 · 1920×1080 · 缩小播放，仅修复',
      );
    });
    test('eligible==true 不追加', () {
      expect(srBadgeLabel('Anime4K x2', 1920, 1080, true),
          'AI 超分 · Anime4K x2 · 1920×1080');
    });
  });

  group('srHintText', () {
    test('无分辨率：片源分辨率获取中', () {
      expect(srHintText(0, 0, null), contains('片源分辨率获取中'));
    });
    test('eligible==false：缩小播放说明', () {
      final s = srHintText(1920, 1080, false);
      expect(s, contains('渲染尺寸比片源还小'));
      expect(s, contains('全屏播放或调大窗口'));
    });
    test('vw<=1280（低于 1080p）：收益说明 + 2K 超采样', () {
      final s = srHintText(1280, 720, null);
      expect(s, contains('720p'));
      expect(s, contains('2560×1440'));
    });
    test('vw>1280：高分辨率收益说明', () {
      final s = srHintText(1920, 1080, null);
      expect(s, contains('收益小于低分辨率片源'));
    });
  });

  group('bufferText', () {
    test('recovering 优先', () {
      expect(
        bufferText(
            recovering: true,
            switching: true,
            ready: true,
            buffering: true,
            dur: const Duration(seconds: 100),
            buffer: const Duration(seconds: 10)),
        '播放中断，正在重连…',
      );
    });
    test('switching：正在解析直链', () {
      expect(
        bufferText(
            recovering: false,
            switching: true,
            ready: false,
            buffering: false,
            dur: Duration.zero,
            buffer: Duration.zero),
        '正在解析直链…',
      );
    });
    test('就绪且缓冲中：百分比', () {
      expect(
        bufferText(
            recovering: false,
            switching: false,
            ready: true,
            buffering: true,
            dur: const Duration(seconds: 100),
            buffer: const Duration(seconds: 25)),
        '缓冲中 25%',
      );
    });
    test('百分比 clamp 到 100', () {
      expect(
        bufferText(
            recovering: false,
            switching: false,
            ready: true,
            buffering: true,
            dur: const Duration(seconds: 1),
            buffer: const Duration(seconds: 60)),
        '缓冲中 100%',
      );
    });
    test('dur==0 不除零：加载中', () {
      expect(
        bufferText(
            recovering: false,
            switching: false,
            ready: true,
            buffering: true,
            dur: Duration.zero,
            buffer: const Duration(seconds: 1)),
        '加载中…',
      );
    });
    test('未就绪：加载中', () {
      expect(
        bufferText(
            recovering: false,
            switching: false,
            ready: false,
            buffering: true,
            dur: const Duration(seconds: 100),
            buffer: const Duration(seconds: 10)),
        '加载中…',
      );
    });
  });
}