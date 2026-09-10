import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:xingmanxia/services/player_registry.dart';

/// 测试用假平台播放器：绕过原生库（CI 无 mpv 依赖），
/// 仅验证 PlayerRegistry 的交接语义（同一引用往返/释放/幂等）。
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());
}

Player _testPlayer() => Player(platformPlayer: _FakePlatformPlayer());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerRegistry 画中画交接', () {
    setUp(() {
      PlayerRegistry.retire();
    });

    tearDown(() {
      PlayerRegistry.retire();
    });

    test('publish/resumePlayer 同一 Player 往返', () async {
      final p = _testPlayer();
      expect(PlayerRegistry.active, isFalse);
      PlayerRegistry.publish(PlayerHandoff(
        player: p,
        url: 'https://example.com/v.m3u8',
        title: '测试番剧',
        episodes: const [],
        position: const Duration(seconds: 42),
        speed: 1.5,
        season: 1,
        episode: 3,
      ));
      expect(PlayerRegistry.active, isTrue);
      expect(PlayerRegistry.current?.player, same(p));
      expect(PlayerRegistry.current?.episode, 3);

      final taken = PlayerRegistry.resumePlayer();
      expect(taken, isNotNull);
      expect(taken!.player, same(p));
      expect(taken.position.inSeconds, 42);
      expect(taken.speed, 1.5);
      expect(PlayerRegistry.active, isFalse);
      await p.dispose();
    });

    test('retire 释放 Player 并清空登记', () async {
      final p = _testPlayer();
      PlayerRegistry.publish(PlayerHandoff(
        player: p,
        url: 'https://example.com/a.mp4',
        title: '测试',
        episodes: const [],
      ));
      PlayerRegistry.retire();
      expect(PlayerRegistry.active, isFalse);
      expect(PlayerRegistry.current, isNull);
    });

    test('无登记时 retire/resume 幂等', () {
      PlayerRegistry.retire();
      expect(PlayerRegistry.resumePlayer(), isNull);
      expect(PlayerRegistry.active, isFalse);
    });
  });
}