/// 播放缓冲档位（P1-26）。
///
/// ## 为什么不能一刀切 256MB
/// 旧实现所有平台统一 `bufferSize: 256MB`。这是为了解决慢源问题（实测
/// bf.modujx15.com 单连接仅 35–140KB/s，mpv 默认 32MB 在 1.26MB/s 码率上
/// 只够 ~25 秒，播几下就耗尽 → 分片卡顿 → 重载循环）。
///
/// 但 256MB 是**字节容量**上限，不是实际占用——mpv 会尽量填满它。
/// 在 2GB/3GB 的 Android 设备上，这 256MB 要和解码帧、图片缓存、WebView
/// 抢内存，被系统杀掉的概率显著上升。
///
/// ## 分档思路
/// 按**运行时可用内存**（不是屏幕尺寸）分档：
/// - 低内存手机（≤2GB）：64MB —— 保住播放不被杀，慢源靠重连补偿
/// - 常见手机（3–4GB）：128MB
/// - 大内存手机/平板（6GB+）：192MB
/// - Windows 桌面：256MB（内存充裕，慢源优先）
///
/// ## 一个刻意的保守
/// 低档不会低于 64MB。实测低于 64MB 时慢源首播失败率明显上升，
/// 那是把「OOM 风险」换成了「根本播不了」——更糟。宁可 64MB + 重试，
/// 也不降到 32MB。
///
/// 另外：**不通过加大缓冲来掩盖重试问题**。缓冲只是让慢源有足够窗口，
/// 真正的重连/降清晰度逻辑在播放器层，不在这里。
library;

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// 播放缓冲档位。
enum PlaybackBufferTier {
  /// 低内存移动设备（≤2GB RAM）：64MB。
  mobileLow,

  /// 常见移动设备（3–4GB RAM）：128MB。
  mobileNormal,

  /// 大内存移动设备 / 平板（6GB+）：192MB。
  mobileHigh,

  /// 桌面（Windows/macOS/Linux）：256MB。
  desktop,
}

/// 选择播放缓冲大小。
class PlaybackBufferPolicy {
  PlaybackBufferPolicy._();

  static const int kMobileLowMb = 64;
  static const int kMobileNormalMb = 128;
  static const int kMobileHighMb = 192;
  static const int kDesktopMb = 256;

  /// 缓存当前档位（设备信息读取是异步的，播放页构造时同步需要结果）。
  ///
  /// 默认给 [PlaybackBufferTier.mobileNormal]，避免首帧前读不到信息时
  /// 退化成最低档（那会让本该流畅的设备也少缓冲）。
  static PlaybackBufferTier _tier = PlaybackBufferTier.mobileNormal;
  static bool _resolved = false;

  /// 仅测试用：直接设定档位。
  @visibleForTesting
  static void testSetTier(PlaybackBufferTier t) {
    _tier = t;
    _resolved = true;
  }

  /// 仅测试用：重置到未解析状态。
  @visibleForTesting
  static void testReset() {
    _tier = PlaybackBufferTier.mobileNormal;
    _resolved = false;
  }

  /// 当前档位。
  static PlaybackBufferTier get tier => _tier;

  /// 当前缓冲字节数。
  static int get bufferBytes => bytesFor(_tier);

  /// 档位 → 字节。
  static int bytesFor(PlaybackBufferTier t) {
    final mb = switch (t) {
      PlaybackBufferTier.mobileLow => kMobileLowMb,
      PlaybackBufferTier.mobileNormal => kMobileNormalMb,
      PlaybackBufferTier.mobileHigh => kMobileHighMb,
      PlaybackBufferTier.desktop => kDesktopMb,
    };
    return mb * 1024 * 1024;
  }

  /// 在 App 启动时解析一次（main.dart 的 init 段调用）。
  ///
  /// 失败不影响启动：读不到设备信息就保持默认档。
  static Future<void> resolve() async {
    if (_resolved) return;
    _resolved = true;
    try {
      if (kIsWeb) {
        _tier = PlaybackBufferTier.mobileNormal;
        return;
      }
      if (Platform.isAndroid) {
        _tier = _androidTier(await _androidRamMb());
        return;
      }
      if (Platform.isIOS) {
        // iOS 由系统统一管理内存，不做细分；按常见机型给中档。
        _tier = PlaybackBufferTier.mobileNormal;
        return;
      }
      // Windows / macOS / Linux
      _tier = PlaybackBufferTier.desktop;
    } catch (e) {
      // 读不到就保持默认（mobileNormal）：宁可少缓冲也不因为探测失败
      // 把桌面端降成 64MB。
      debugPrint('PlaybackBufferPolicy.resolve failed: $e');
    }
  }

  /// Android 物理内存（MB）。读不到返回 null。
  static Future<int?> _androidRamMb() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final bytes = info.physicalRamSize;
      if (bytes <= 0) return null;
      return (bytes / (1024 * 1024)).round();
    } catch (_) {
      return null;
    }
  }

  /// 按 Android 物理内存分档。
  ///
  /// 阈值依据（2026-11 主流机型分布）：
  /// - ≤2.5GB：多为入门机（2GB/3GB 实际可用更低），64MB
  /// - 2.5–5.5GB：4GB/6GB 机型主流，128MB
  /// - >5.5GB：8GB+ 与多数平板，192MB
  ///
  /// 用 2.5/5.5 而不是 2/4/6，是因为 `physicalRamSize` 报的是**物理总量**，
  /// 而系统与厂商占掉的部分不固定；用中间值切分能减少临界机型误判。
  static PlaybackBufferTier _androidTier(int? ramMb) {
    if (ramMb == null) return PlaybackBufferTier.mobileNormal;
    if (ramMb <= 2560) return PlaybackBufferTier.mobileLow;
    if (ramMb <= 5632) return PlaybackBufferTier.mobileNormal;
    return PlaybackBufferTier.mobileHigh;
  }

  /// 供界面展示的档位说明（中文，避免英文残留）。
  static String get tierLabel => switch (_tier) {
        PlaybackBufferTier.mobileLow => '低内存优化（64MB）',
        PlaybackBufferTier.mobileNormal => '标准（128MB）',
        PlaybackBufferTier.mobileHigh => '大内存/平板（192MB）',
        PlaybackBufferTier.desktop => '桌面（256MB）',
      };
}
