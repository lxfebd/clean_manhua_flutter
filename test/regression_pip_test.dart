import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/services/player_registry.dart';

/// 测试用假平台播放器：绕过原生库（CI 无 mpv 依赖），
/// 仅验证 PlayerRegistry 的交接语义（同一引用往返/释放/幂等）。
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());
}

Player _testPlayer() => Player(platformPlayer: _FakePlatformPlayer());

/// 注入播放位置：平台播放器 state 默认为 0，直接替换为指定位置/时长，
/// 供释放落盘测试读取（_persistFinal 读 p.state.position）。
void _setPosition(Player p, Duration pos, Duration dur) {
  p.platform!.state = PlayerState(position: pos, duration: dur);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_pip_persist');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmp.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() async {
    LocalStore.resetForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

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

  group('PlayerRegistry 关闭落盘（_persistFinal）', () {
    setUp(() {
      PlayerRegistry.retire();
    });

    tearDown(() {
      PlayerRegistry.retire();
      LocalStore.resetForTest();
    });

    test('retire 后进度写入 video_progress（位置 <5s 不写）', () async {
      final p = _testPlayer();
      final key = 'src1/vid1/1-3';
      _setPosition(p, const Duration(seconds: 2),
          const Duration(seconds: 100));
      PlayerRegistry.publish(PlayerHandoff(
        player: p,
        url: 'https://example.com/a.mp4',
        title: '测试',
        episodes: const [],
        sourceId: 'src1',
        videoId: 'vid1',
        historyKey: key,
        season: 1,
        episode: 3,
      ));
      PlayerRegistry.retire();
      // fire-and-forget：等 LocalStore 排队写完成。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await LocalStore.videoProgressOf(key), 0,
          reason: '位置 <5s 不应写进度');
      await p.dispose();
    });

    test('retire 后进度写入：中等位置落盘，看完清记录', () async {
      final p = _testPlayer();
      final key = 'src1/vid1/1-3';
      _setPosition(p, const Duration(seconds: 42),
          const Duration(seconds: 100));
      PlayerRegistry.publish(PlayerHandoff(
        player: p,
        url: 'https://example.com/a.mp4',
        title: '测试',
        episodes: const [],
        sourceId: 'src1',
        videoId: 'vid1',
        historyKey: key,
        season: 1,
        episode: 3,
      ));
      PlayerRegistry.retire();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await LocalStore.videoProgressOf(key), 42);

      // 看完（距结尾 15s 内）：清续播记录。
      final p2 = _testPlayer();
      _setPosition(p2, const Duration(seconds: 95),
          const Duration(seconds: 100));
      PlayerRegistry.publish(PlayerHandoff(
        player: p2,
        url: 'https://example.com/a.mp4',
        title: '测试',
        episodes: const [],
        sourceId: 'src1',
        videoId: 'vid1',
        historyKey: key,
        season: 1,
        episode: 3,
      ));
      PlayerRegistry.retire();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await LocalStore.videoProgressOf(key), 0,
          reason: '看完应清除续播记录');
      await p.dispose();
      await p2.dispose();
    });

    test('retire 落盘写入结构化观看记录（video_records）', () async {
      final p = _testPlayer();
      _setPosition(p, const Duration(seconds: 30),
          const Duration(seconds: 100));
      PlayerRegistry.publish(PlayerHandoff(
        player: p,
        url: 'https://example.com/a.mp4',
        title: '测试番剧',
        episodes: const [],
        sourceId: 'src1',
        videoId: 'vid1',
        historyKey: 'k',
        season: 1,
        episode: 3,
      ));
      PlayerRegistry.retire();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final recs = await LocalStore.videoRecords();
      final match = recs.where((r) => r.sourceId == 'src1').toList();
      expect(match, hasLength(1));
      expect(match.first.episode, 3);
      expect(match.first.seconds, 30);
      await p.dispose();
    });
  });
}