import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/biquge_novel_source.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_manager.dart';
import 'package:xingmanxia/sources/tvtfun_video_source.dart';
import 'package:xingmanxia/sources/xbiquge_novel_source.dart';

/// 内置源的「档位健康度 + 配置一致性」回归闸门（2026-11-04）。
///
/// ## 背景一：死源占据默认位
/// 首页/列表默认取 `tier` 排序后的第一个可用源。若已死的源仍是 `primary`，
/// 用户打开对应 tab 直接空白——表现是「源加载不出来」，根因却不在 UI 层。
///
/// ## 背景二：**配置表与源内的默认 host 必须同步**（本文件最关键的坑）
/// `SourceHttp.pickHost()` 读的是 `SourceConfigStore.hostsFor()`，也就是
/// `source_config.dart` 里 `defaults()` 的 hosts，**而不是**各源类里的
/// `_defaultHosts` 兜底。因此「只改解析器里的域名」不够：配置表里若还是旧域名，
/// 请求仍会打到死站，且表现为「换站后照样握手失败」。更麻烦的是老用户的
/// `sources_config.json` 会覆盖默认值——所以 biquge 源内还额外过滤了
/// [_deadHosts] 一份已知死亡域名（见 biquge_novel_source.dart）。
///
/// ## 2026-11-04 的处置结论
/// - **笔趣阁 biquge**：旧站 tobiquge.com 被江苏反诈页接管（302 →
///   js96110.com.cn）、xbiquge.com 超时，同模板镜像无一存活 → 换站到
///   `biquge365.net` 并重写解析器；tier 降为 `fallback`，小说首页默认交给
///   新笔趣阁（xbiquge.bz）。
/// - **TvTFun tvtfun**：站点改版为 Nuxt 3 SPA，旧 `/api/videos*` 全 404 →
///   从 SSR 载荷逆向出新 `/api/client/*` 接口并重写；播放需人机验证故走
///   WebView。tier 恢复为 `fallback`（此前临时 `disabled`）。
///
/// 源站再变化时，请**同时**改档位/配置与本文件的断言，让改动是显式决定。
void main() {
  group('内置源档位健康度（死源不得占据默认位）', () {
    test('笔趣阁为 fallback（小说首页默认让位给新笔趣阁）', () {
      expect(BiqugeNovelSource().tier, SourceTier.fallback,
          reason: '换站后本源可用，但默认仍交给实测更充分的新笔趣阁；'
              '若要把默认切回来，改 tier 并同步本断言');
      expect(BiqugeNovelSource().id, 'biquge');
    });

    test('新笔趣阁仍是 primary（当前小说默认源，xbiquge.bz 实测可用）', () {
      expect(XbiqugeNovelSource().tier, SourceTier.primary,
          reason: '小说首页需要至少一个 primary 的可用网络源；'
              '降它之前先确认另一个源真的能用');
      expect(XbiqugeNovelSource().id, 'xbiquge');
    });

    test('TvTFun 已恢复为 fallback（Nuxt 新 API 重写完成）', () {
      expect(TvTfunVideoSource().tier, SourceTier.fallback,
          reason: '2026-11-04 已按 /api/client/* 重写并可正常列列表/搜索/详情；'
              '若再次失效，先置 disabled 并同步本断言');
      expect(TvTfunVideoSource().id, 'tvtfun');
    });

    test('小说源列表里至少有一个 primary 网络源（否则首页必空）', () {
      final primaries = SourceManager.novelSources
          .where((s) => s.tier == SourceTier.primary)
          .toList();
      expect(primaries, isNotEmpty,
          reason: '没有 primary 小说源时，小说首页会落到 fallback 甚至空列表');
    });

    test('视频源列表里仍有可用源，且默认源 AGE 未被误停用', () {
      final usable = SourceManager.videoSources
          .where((s) => s.tier != SourceTier.disabled)
          .toList();
      expect(usable, isNotEmpty, reason: '全部视频源被停用会让动漫首页空白');
      expect(usable.any((s) => s.id == 'agedm'), isTrue,
          reason: 'AGE 动漫是视频默认源，停用它会让动漫首页空白');
      // TvTFun 重写后可用，不应再是 disabled
      expect(usable.any((s) => s.id == 'tvtfun'), isTrue,
          reason: 'TvTFun 已重写恢复，应回到可选源列表');
    });
  });

  group('配置表与源默认 host 一致性（换站必须两处同步）', () {
    /// 已确认死亡、绝不能再出现在默认配置里的域名。
    const deadHosts = {
      'https://www.tobiquge.com',
      'http://www.tobiquge.com',
      'https://www.xbiquge.com',
      'http://www.xbiquge.com',
    };

    test('biquge 内置配置指向新站 biquge365.net，且不含已死域名', () {
      final cfg = SourceConfigStore.defaults()
          .firstWhere((c) => c.engineId == 'biquge');
      expect(cfg.hosts, isNotEmpty);
      expect(
        cfg.hosts.any((h) => h.contains('biquge365.net')),
        isTrue,
        reason: 'SourceHttp.pickHost 读的是配置表，不是源类的 _defaultHosts；'
            '配置表不改，换站等于没换（请求仍打到旧死站）',
      );
      for (final h in cfg.hosts) {
        expect(deadHosts.contains(h.trim()), isFalse,
            reason: '默认配置不得再含已死域名：$h');
      }
    });

    test('biquge 内置配置的 tier 与源类一致（都为 fallback）', () {
      final cfg = SourceConfigStore.defaults()
          .firstWhere((c) => c.engineId == 'biquge');
      expect(cfg.tier, BiqugeNovelSource().tier,
          reason: '配置表 tier 与源类 tier 不一致时，源管理页展示与排序会互相矛盾');
    });

    test('tvtfun 内置配置的 tier 与源类一致', () {
      final cfg = SourceConfigStore.defaults()
          .firstWhere((c) => c.engineId == 'tvtfun');
      expect(cfg.tier, TvTfunVideoSource().tier);
    });
  });
}
