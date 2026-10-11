import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/player_utils.dart';

void main() {
  group('mediaHeaders 播放请求头构造', () {
    test('异常输入不抛异常（防御性）', () {
      // Uri.tryParse 对空串/裸 scheme 等大多返回非 null（空 host），
      // 原实现对空 host 也会构造出 map；null 分支仅防极端输入。
      expect(mediaHeaders('http://'), containsPair('User-Agent', isNotNull));
      expect(() => mediaHeaders('://bad'), returnsNormally);
    });

    test('普通域名带 Referer + UA', () {
      final h = mediaHeaders('https://cdn.example.com/video.mp4');
      expect(h['Referer'], 'https://cdn.example.com/');
      expect(h.containsKey('User-Agent'), isTrue);
    });

    test('pan.wo.cn 主域不设 Referer', () {
      final h = mediaHeaders('https://pan.wo.cn/video.mp4');
      expect(h.containsKey('Referer'), isFalse);
      expect(h.containsKey('User-Agent'), isTrue);
    });

    test('pan.wo.cn 子域不设 Referer', () {
      final h = mediaHeaders('https://sub.pan.wo.cn/video.mp4');
      expect(h.containsKey('Referer'), isFalse);
    });

    test('非 pan.wo.cn 的同域后缀仍设 Referer', () {
      final h = mediaHeaders('https://xpan.wo.cn/video.mp4');
      expect(h['Referer'], 'https://xpan.wo.cn/');
    });

    test('http 协议 Referer 用 http scheme', () {
      final h = mediaHeaders('http://cdn.example.com/video.mp4');
      expect(h['Referer'], 'http://cdn.example.com/');
    });

    test('Host 头透传 hostHeaderFor（不崩溃即通过）', () {
      final h = mediaHeaders('https://cdn.example.com/video.mp4');
      // hostHeaderFor 对非优选 IP 返回空 map，这里只验证不抛异常且类型对。
      expect(h, isA<Map<String, String>>());
    });
  });
}