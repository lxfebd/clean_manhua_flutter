import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/anime_player_page.dart';

/// 广告直链过滤回归测试：混广告源（站点先传广告 m3u8 再传正片）在
/// WebView 捕获链路里不得把广告当成正片接管原生播放器（否则会从 0:00
/// 播广告、再被正片二次接管再次从 0:00 重播）。
void main() {
  group('isAdMediaUrl 判定', () {
    test('path 独立段 ad/ads/adv 命中', () {
      expect(isAdMediaUrl('https://cdn.example.com/ad/playlist.m3u8'),
          isTrue);
      expect(isAdMediaUrl('https://cdn.example.com/ads/video.mp4'), isTrue);
      expect(isAdMediaUrl('https://cdn.example.com/adv/roll.m3u8'), isTrue);
      expect(isAdMediaUrl('https://cdn.example.com/advertisement/x.m3u8'),
          isTrue);
      expect(isAdMediaUrl('https://cdn.example.com/adserver/y.m3u8'), isTrue);
    });

    test('已知广告域名命中', () {
      expect(
          isAdMediaUrl(
              'https://ad.doubleclick.net/ddm/adj/x/video.m3u8'),
          isTrue);
      expect(
          isAdMediaUrl(
              'https://pagead2.googlesyndication.com/pagead/video.m3u8'),
          isTrue);
      expect(isAdMediaUrl('https://rtb.applovin.com/ad.m3u8'), isTrue);
    });

    test('正片直链不误伤', () {
      expect(isAdMediaUrl('https://v.example.com/ep/123/playlist.m3u8'),
          isFalse);
      expect(isAdMediaUrl('https://v.example.com/video/tos/abc/1.mp4'),
          isFalse);
      expect(isAdMediaUrl('https://v.example.com/hls/456/index.m3u8'),
          isFalse);
      // 查询参数里带 ad 也不误伤（只看 path 独立段）
      expect(isAdMediaUrl('https://v.example.com/play.m3u8?from=ad&x=1'),
          isFalse);
    });

    test('空串/边界', () {
      expect(isAdMediaUrl(''), isFalse);
      expect(isAdMediaUrl('https://v.example.com/adventure/ep1.m3u8'),
          isFalse); // adventure 不是独立 ad 段
      expect(isAdMediaUrl('https://v.example.com/ad-roll.m3u8'),
          isFalse); // ad-roll 连字符非独立段
    });
  });

  group('isDirectMediaUrl 直链判定', () {
    test('常规直链仍被放行', () {
      expect(isDirectMediaUrl('https://v.example.com/a.m3u8'), isTrue);
      expect(isDirectMediaUrl('https://v.example.com/a.mp4'), isTrue);
      expect(isDirectMediaUrl('https://v.example.com/hls/1/index.m3u8'),
          isTrue);
      expect(isDirectMediaUrl('blob:https://v.example.com/abc'), isTrue);
      expect(isDirectMediaUrl(''), isFalse);
    });
  });
}
