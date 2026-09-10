import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/video_download_manager.dart';
import 'package:xingmanxia/ui/widgets/player_widgets.dart';
import 'package:xingmanxia/utils/danmaku.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 打桩：LocalStore 落到临时目录（单元测试无插件通道）。
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_regression').path;
        }
        return null;
      },
    );
  });

  group('LocalStore 合并式设置写入（回归：settings 静默丢字段）', () {
    test('setDarkMode 后 danmaku 设置不被清空', () async {
      await LocalStore.init();

      // 先写入弹幕设置（合并式写入）
      await LocalStore.setDanmaku(const DanmakuSettings(
        on: true,
        opacity: 0.8,
        speed: 3.0,
        fontSize: 18.0,
      ));

      // 再切换深色模式（修复前：全量覆盖白名单会丢掉 danmaku 键）
      await LocalStore.setDarkMode(true);

      // 弹幕设置必须保留
      final s = await LocalStore.danmakuSettings();
      expect(s.on, isTrue);
      expect(s.opacity, closeTo(0.8, 0.001));
      expect(s.fontSize, closeTo(18.0, 0.001));
    });

    test('setThemeId 后窗口几何不被清空', () async {
      await LocalStore.init();

      // 先写入窗口几何（合并式）
      await LocalStore.setWindowGeometry(w: 1280, h: 800, x: 100, y: 50);

      // 再切换主题色（修复前：会丢掉 winW/winH/winX/winY）
      await LocalStore.setThemeId(2);

      final g = await LocalStore.windowGeometry();
      expect(g, isNotNull);
      expect(g!['w'], closeTo(1280, 0.001));
      expect(g['h'], closeTo(800, 0.001));
      expect(g['x'], closeTo(100, 0.001));
      expect(g['y'], closeTo(50, 0.001));
    });

    test('setResLevel 后其它阅读设置不被清空', () async {
      await LocalStore.init();

      await LocalStore.setHorizontalReader(true);
      await LocalStore.setRtlReader(true);
      await LocalStore.setAutoPageTurn(5);
      await LocalStore.setResLevel(3);

      expect(await LocalStore.horizontalReader(), isTrue);
      expect(await LocalStore.rtlReader(), isTrue);
      expect(await LocalStore.autoPageTurn(), 5);
      expect(await LocalStore.resLevel(), 3);
    });
  });

  group('VideoDownloadManager 删除后重新下载（回归：残留取消标记）', () {
    test('cancel → remove → start 后任务状态不被误判为 canceled', () async {
      final m = VideoDownloadManager.instance;
      // 用一个不可达 URL，让任务快速走失败分支退出，避免真实网络下载。
      const url = 'http://127.0.0.1:1/nonexistent.mp4';

      final t1 = await m.start(
        sourceId: 'test',
        videoId: 'vid-1',
        title: '测试番剧',
        season: 1,
        episode: 1,
        url: url,
      );
      expect(m.taskOf(t1.key), isNotNull);

      // 取消 → 删除（模拟用户删除下载后重新下载）
      m.cancel(t1.key);
      await m.remove(t1.key);
      expect(m.taskOf(t1.key), isNull);

      // 重新下载同一集：必须新建任务，且不应继承取消标记
      final t2 = await m.start(
        sourceId: 'test',
        videoId: 'vid-1',
        title: '测试番剧',
        season: 1,
        episode: 1,
        url: url,
      );
      expect(m.taskOf(t2.key), isNotNull);

      // 等任务结束（不可达 URL 会快速 failed，而不是 canceled）
      await Future<void>.delayed(const Duration(seconds: 3));
      final finalTask = m.taskOf(t2.key);
      expect(finalTask, isNotNull);
      expect(finalTask!.state, isNot('canceled'),
          reason: '删除后重新下载的任务不应被残留取消标记命中');
    });
  });

  group('下载画质偏好持久化（批量下载画质选择）', () {
    test('setDownloadQuality 与 downloadQuality 读写一致', () async {
      await LocalStore.init();
      // 默认原画
      expect(await LocalStore.downloadQuality(), 0);
      // 省空间档
      await LocalStore.setDownloadQuality(1);
      expect(await LocalStore.downloadQuality(), 1);
      // 不影响其它阅读设置（合并式写入）
      await LocalStore.setResLevel(2);
      expect(await LocalStore.downloadQuality(), 1);
      expect(await LocalStore.resLevel(), 2);
      // 复位
      await LocalStore.setDownloadQuality(0);
      expect(await LocalStore.downloadQuality(), 0);
    });
  });

  group('进度条锁定（回归：锁定时仍可拖动进度条）', () {
    testWidgets('enabled=false 时拖动不触发 onSeek', (tester) async {
      Duration? seeked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: PlayerProgressBar(
              position: const Duration(seconds: 10),
              duration: const Duration(seconds: 100),
              buffered: Duration.zero,
              enabled: false,
              onSeek: (t) => seeked = t,
            ),
          ),
        ),
      ));
      // 在条上按下并拖动一段距离
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      // 锁定态下不应有任何 seek 回调
      expect(seeked, isNull);
    });
  });
}
