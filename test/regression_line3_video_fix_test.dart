import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xingmanxia/sources/video_source.dart';

/// 修复线 3「视频/动漫播放」P0/P1 回归测试。
///
/// 覆盖：
///   #3 (P1) 字节系 CDN 直链不再被当成正片直链 —— `isAdMediaUrl` 命中、
///        捕获链路据此拦截，且纯正片域名判定不受影响
///   #1 (P0) WebView2 初始化失败降级页增加重试入口（不再永久锁死）
///   #2 (P1) 桌面 PiP 入口按钮仅在能力探测成功后渲染
///
/// #1/#2 为 UI 行为，未做运行时 widget 测试：AnimePlayerPage 的桌面分支
/// 会同步构造 `DesktopWebview`（WebView2 FFI），NativePlayerPage 的
/// initState 会创建 media_kit `Player`（需原生 mpv 后端）——两者在
/// flutter_test 无原生引擎的环境下都会抛 MissingPluginException/FFI 缺失，
/// 无法稳定复现（与 [regression_pip_test.dart] 用 FakePlatformPlayer 绕开
/// 原生库是同类限制）。故按修复线 6 的既定做法（见
/// [regression_line6_net_fix_test.dart]）改用源码审查断言：断言守卫代码
/// 实际存在于源码中且顺序正确。若后续在 lib/ 内加入测试钩子，可再补运行时
/// widget 测试。
void main() {
  final root = p.join('lib', 'ui', 'anime_player_page.dart');
  final native = p.join('lib', 'ui', 'native_player_page.dart');

  String animeSrc() => File(root).readAsStringSync();
  String nativeSrc() => File(native).readAsStringSync();

  group('#3 isAdMediaUrl 字节系 CDN', () {
    test('pstatp/topbuzzcdn/capcut 全部命中（字节系广告 CDN）', () {
      expect(
          isAdMediaUrl('https://pstatp.com/origin/ad/12345/video.m3u8'),
          isTrue);
      expect(isAdMediaUrl('https://pstatp.com/ad_video/x.m3u8'), isTrue);
      expect(
          isAdMediaUrl(
              'https://topbuzzcdn.com/video/ad/playlist.m3u8?sig=abc'),
          isTrue);
      expect(isAdMediaUrl('https://p.pstatp.com/media/x.m3u8'), isTrue);
      expect(isAdMediaUrl('https://i0.capcut.com/ad/stream.m3u8'), isTrue);
      expect(isAdMediaUrl('https://www.capcut.com/ad/video.mp4'), isTrue);
    });

    test('子域名/查询串变体不误伤', () {
      expect(
          isAdMediaUrl(
              'https://ad-creative.pstatp.com/origin/ad/1/a.m3u8?x=1'),
          isTrue);
      // path/文件名里嵌 pstatp.com 的形态不误判：按 host 段匹配后
      // v.example.com 不是字节系 CDN，不拦截。
      expect(isAdMediaUrl('https://v.example.com/pstatp.com.m3u8'), isFalse);
      expect(
          isAdMediaUrl(
              'https://vod.pstatp.com/hls/1/index.m3u8?from=ad&x=1'),
          isTrue);
    });

    test('纯正片域名判定不变', () {
      expect(isAdMediaUrl('https://v.example.com/a.m3u8'), isFalse);
      expect(isAdMediaUrl('https://v.example.com/video/tos/a/1.mp4'),
          isFalse);
      expect(isAdMediaUrl('https://v.example.com/hls/1/index.m3u8'), isFalse);
      expect(isAdMediaUrl(''), isFalse);
      expect(isAdMediaUrl('https://v.example.com/adventure/ep1.m3u8'),
          isFalse);
      expect(isAdMediaUrl('https://v.example.com/ad-roll.m3u8'), isFalse);
    });

    test('isDirectMediaUrl 纯正片域名判定不变', () {
      expect(isDirectMediaUrl('https://v.example.com/a.m3u8'), isTrue);
      expect(isDirectMediaUrl('https://v.example.com/a.mp4'), isTrue);
      expect(isDirectMediaUrl('https://v.example.com/hls/1/index.m3u8'),
          isTrue);
      expect(isDirectMediaUrl('blob:https://v.example.com/abc'), isTrue);
      expect(isDirectMediaUrl(''), isFalse);
      expect(isDirectMediaUrl('https://example.com/p'), isFalse);
    });

    test('既有拦截点保持有效（不误伤真实源）', () {
      // Anime1 正片直链：源站自有域名，不受字节系拦截影响。
      expect(isAdMediaUrl('https://.v.anime1.me/ep/12/playlist.m3u8'),
          isFalse);
      // 既有拦截点靠 isDirectMediaUrl && isAdMediaUrl 双判：
      // 非直链的网页播放页地址不进入拦截分支。
      expect(isDirectMediaUrl('https://v.example.com/play/ep/1'), isFalse);
    });
  });

  group('#1 WebView2 初始化失败降级页重试入口', () {
    test('重试入口与守卫代码存在（源码审查）', () {
      final src = animeSrc();

      // 1) 连点防抖 + mounted 守卫：重试入口第一行。
      expect(
          src.contains(
              RegExp(r'if \(_desktopRetry \|\| !mounted\) return;')),
          isTrue,
          reason: '重试入口需防连点 + mounted 守卫');

      // 2) 重试按钮直接绑定 handler（非闭包包裹）：这是防抖的唯一机制。
      expect(
          src.contains(
              RegExp(r'onPressed: _desktopRetry \? null : _retryDesktopInit')),
          isTrue,
          reason: '重试按钮需把 _retryDesktopInit 直接绑定给 onPressed');

      // 3) 降级页存在重试入口文案（label 实际渲染文案，忽略注释出现）。
      expect(
          src.contains(RegExp(
              r"label: Text\(_desktopRetry \? '正在重试…' : '重试内嵌播放'\)")),
          isTrue);

      // 4) 重试前清理旧实例与订阅（否则旧 controller 残留句柄/音频）。
      expect(
          src.contains('_desktopSubs.clear();') &&
              src.contains(RegExp(r'final old = _desktop;')),
          isTrue,
          reason: '重试前需清理上一轮实例与事件订阅');

      // 5) 重试成功路径复位失败标记，重新渲染 WebView。
      expect(
          src.contains('setState(() => _desktopInitFailed = false);'),
          isTrue,
          reason: '重试成功需复位 _desktopInitFailed');

      // 6) 重试失败路径回到失败态（按钮重新可用，不再锁死）。
      expect(
          src.contains('_desktopInitFailed = true;') &&
              src.contains('_webviewInit = false;'),
          isTrue,
          reason: '重试失败需回到失败态');
    });

    test('降级页重试按钮在既有按钮之后渲染', () {
      // 保证不会挤掉「用系统浏览器播放」出口，且重试入口位于失败态。
      final src = animeSrc();
      final int browserIdx =
          src.indexOf('label: const Text(\'用系统浏览器播放\')');
      final int retryIdx =
          src.indexOf("label: Text(_desktopRetry ? '正在重试…' : '重试内嵌播放')");
      expect(browserIdx, greaterThan(0));
      expect(retryIdx, greaterThan(browserIdx),
          reason: '重试按钮应在浏览器降级出口之后');
    });

    test('Linux/无内嵌平台重试入口保持隐藏（无内嵌实现时不显示）', () {
      final src = animeSrc();
      // 重试分支仅由 _desktopInitFailed 驱动；Linux 走的是
      // _desktopInitFailed == false 的降级页分支（无内嵌实现），
      // 故不会误显重试按钮。
      expect(
          src.contains(RegExp(r'if \(_desktopInitFailed\) \.\.\.\[')),
          isTrue);
    });
  });

  group('#2 桌面 PiP 入口按钮按能力位隐藏', () {
    test('能力位与渲染守卫代码存在（源码审查）', () {
      final src = nativeSrc();

      // 1) 记录 install() 结果到状态位（非 Android 时 install() 返回 false）。
      expect(src.contains('bool _pipAvailable = false;'), isTrue,
          reason: '需记录 PiP 能力位');
      expect(
          src.contains(
              RegExp(r'setState\(\(\) => _pipAvailable = ok\);')),
          isTrue,
          reason: 'install() 结果需写入能力位');

      // 2) PiP 按钮渲染由能力位守卫（旧写法是 PipChannel.inPip != null）。
      expect(src.contains(RegExp(r'if \(_pipAvailable\)')), isTrue,
          reason: 'PiP 按钮需由能力位守卫');
      expect(
          src.contains(RegExp(
              r'_barBtn\(Icons\.picture_in_picture_alt_rounded, _toggleSystemPip\)')),
          isTrue,
          reason: 'PiP 按钮仍指向 _toggleSystemPip');

      // 3) 不再用 PipChannel.inPip 作为渲染条件（旧写法）。
      expect(
          !src.contains('PipChannel.inPip'), isTrue,
          reason: '渲染条件应改为能力位，不再依赖 PipChannel.inPip');
    });

    test('非 Android 平台不再渲染 PiP 入口（能力位默认 false）', () {
      final src = nativeSrc();
      // 能力位默认 false，只有 install() 返回 true 才置真 → 非 Android
      //（install() 内部因 defaultTargetPlatform 判定返回 false）不渲染。
      expect(
          src.contains(RegExp(r'unawaited\(PipChannel\.install\(\)')),
          isTrue,
          reason: '需在 initState 安装 PiP 通道并记录能力');
    });
  });
}
