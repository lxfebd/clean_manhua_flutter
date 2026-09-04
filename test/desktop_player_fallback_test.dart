import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/sources/video_source.dart';
import 'package:xingmanxia/ui/anime_player_page.dart';
import 'package:xingmanxia/ui/desktop_webview.dart';

/// 桌面端播放页平台判定回归测试。
/// 历史灰屏 bug 根因：webview_flutter 无 Windows 平台实现，直接构造只会
/// 渲染灰色占位块。现在 Windows 必须走 WebView2（isWebViewSupported 为真），
/// 仅 Linux 这类无内嵌实现的平台显示降级页。
void main() {
  group('平台 WebView 能力判定', () {
    test('Windows 走 WebView2：isWebViewSupported 必须为真', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(isWebViewSupported, isTrue);
        expect(isWindowsWebView2, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('Android/iOS/macOS 走 webview_flutter', () {
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        expect(isWebViewSupported, isTrue, reason: '$p 应支持内嵌 WebView');
        expect(isWindowsWebView2, isFalse);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('Linux 无内嵌实现：判定为不支持（播放页显示降级页）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        expect(isWebViewSupported, isFalse);
        expect(isWindowsWebView2, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Linux 降级页渲染', () {
    Future<void> pumpPlayer(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AnimePlayerPage(
            url: 'https://example.com/play',
            title: '测试番剧',
            episodes: [VideoEpisode(1, 1, '第01集')],
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('Linux 平台渲染降级页而不是灰屏 WebView', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpPlayer(tester);
        expect(find.text('该线路需要网页播放'), findsOneWidget);
        expect(find.text('用系统浏览器播放'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
