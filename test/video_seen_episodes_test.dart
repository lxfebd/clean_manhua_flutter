import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

/// P1-13 动漫追更基线的存储语义回归（不联网）。
///
/// 基线语义必须与小说 lastChapters 一致：**首次写入只置基线、不报更新**
/// （否则用户第一次检查必然每个番剧都报「有更新」），之后只认「集数变多」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_vseen_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') return tmp.path;
        return null;
      },
    );
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('videoSeenEpisodes 基线语义', () {
    test('从未记录 → -1（调用方据此判定「首次，只置基线」）', () async {
      expect(await LocalStore.videoSeenEpisodes('agedm', 'v1'), -1);
    });

    test('写入后读回一致（按 sourceId/videoId 隔离）', () async {
      await LocalStore.setVideoSeenEpisodes('agedm', 'v1', 12);
      await LocalStore.setVideoSeenEpisodes('agedm', 'v2', 5);
      expect(await LocalStore.videoSeenEpisodes('agedm', 'v1'), 12);
      expect(await LocalStore.videoSeenEpisodes('agedm', 'v2'), 5,
          reason: '不同 videoId 必须互不覆盖');
    });

    test('同 videoId 不同 sourceId 不串键', () async {
      await LocalStore.setVideoSeenEpisodes('agedm', 'same', 3);
      await LocalStore.setVideoSeenEpisodes('xifan', 'same', 9);
      expect(await LocalStore.videoSeenEpisodes('agedm', 'same'), 3);
      expect(await LocalStore.videoSeenEpisodes('xifan', 'same'), 9);
    });

    test('更新为更大值即覆盖（追更判据：cur > last）', () async {
      await LocalStore.setVideoSeenEpisodes('agedm', 'v3', 4);
      await LocalStore.setVideoSeenEpisodes('agedm', 'v3', 7);
      expect(await LocalStore.videoSeenEpisodes('agedm', 'v3'), 7);
    });

    test('跨读持久（重新走一遍 readJson 路径）', () async {
      await LocalStore.setVideoSeenEpisodes('agedm', 'persist', 21);
      // 直接读底层 JSON，验证真的落盘而不是只在内存缓存里。
      final raw = await LocalStore.readJson('video_seen_episodes');
      expect(raw is Map, isTrue);
      expect((raw as Map)['agedm/persist'], 21);
    });
  });
}
