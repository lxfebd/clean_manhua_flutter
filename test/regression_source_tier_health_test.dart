import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/biquge_novel_source.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_manager.dart';
import 'package:xingmanxia/sources/tvtfun_video_source.dart';
import 'package:xingmanxia/sources/xbiquge_novel_source.dart';

/// 内置源的「档位健康度」回归闸门（2026-11-04）。
///
/// 背景：首页/列表默认取 `tier` 排序后的第一个可用源。若某个已死的源仍是
/// `primary`，用户打开对应 tab 会直接空白——表现是「源加载不出来」，但根因
/// 不在 UI 层。2026-11-04 实测发现两个此类情况：
///
/// - **笔趣阁 biquge**：tobiquge.com 被江苏反诈页接管（302 →
///   js96110.com.cn）、xbiquge.com 超时；同模板镜像无一存活。它此前是
///   `primary`，与同样 `primary` 的新笔趣阁按注册顺序排在前面 → 小说首页
///   默认拿到了死源。已降为 `fallback`。
/// - **TvTFun**：站点改版为 Nuxt 3 SPA，旧 JSON API
///   （/api/videos、/api/videos/search）一律 404「接口不存在」，旧解析链路
///   不可能命中。已置 `disabled`（从源列表隐藏，避免用户选中后必然失败）。
///
/// 本测试锁住这些结论：源站若恢复（或解析器被重写），请**同时**改档位与
/// 这里的断言，让改动是显式决定而非无声回退。
void main() {
  group('内置源档位健康度（死源不得占据默认位）', () {
    test('笔趣阁已降为 fallback（小说首页默认让位给可用的新笔趣阁）', () {
      expect(BiqugeNovelSource().tier, SourceTier.fallback,
          reason: 'tobiquge.com 被反诈页接管、xbiquge.com 超时；'
              '若主站恢复，请把 tier 改回 primary 并同步本断言');
      expect(BiqugeNovelSource().id, 'biquge');
    });

    test('新笔趣阁仍是 primary（当前小说默认源，xbiquge.bz 实测可用）', () {
      expect(XbiqugeNovelSource().tier, SourceTier.primary,
          reason: '小说首页需要至少一个 primary 的可用网络源；'
              '降它之前先确认另一个源真的能用');
      expect(XbiqugeNovelSource().id, 'xbiquge');
    });

    test('TvTFun 已置 disabled（旧 JSON API 全 404，解析链路不可能命中）', () {
      expect(TvTfunVideoSource().tier, SourceTier.disabled,
          reason: '站点改版为 Nuxt 3 SPA（__NUXT_DATA__ 索引引用载荷），'
              '重写解析器后才应改回 fallback 并同步本断言');
      expect(TvTfunVideoSource().id, 'tvtfun');
    });

    test('小说源列表里至少有一个 primary 网络源（否则首页必空）', () {
      final primaries = SourceManager.novelSources
          .where((s) => s.tier == SourceTier.primary)
          .toList();
      expect(primaries, isNotEmpty,
          reason: '没有 primary 小说源时，小说首页会落到 fallback 甚至空列表');
    });

    test('视频源列表里 primary/fallback 至少各有一个可用源（排除 disabled）', () {
      final usable = SourceManager.videoSources
          .where((s) => s.tier != SourceTier.disabled)
          .toList();
      expect(usable, isNotEmpty, reason: '全部视频源被停用会让动漫首页空白');
      // AGE 是视频默认源（注册首位且可用），确保它没被误停用。
      expect(
          usable.any((s) => s.id == 'agedm'), isTrue,
          reason: 'AGE 动漫是视频默认源，停用它会让动漫首页空白');
    });
  });
}
