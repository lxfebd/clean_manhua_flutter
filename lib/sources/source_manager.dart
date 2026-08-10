import 'agedm_video_source.dart';
import 'baozi_source.dart';
import 'biquge_novel_source.dart';
import 'comic_source.dart';
import 'doubao_source.dart';
import 'jm_source.dart';
import 'mangadex_source.dart';
import 'novel_source.dart';
import 'picacg_source.dart';
import 'source_config.dart';
import 'tvtfun_video_source.dart';
import 'video_source.dart';
import 'xifan_video_source.dart';
import 'yyfun_source.dart';

/// 多源聚合管理器：注册所有可用源，支持切换当前源。
/// 源列表按推荐度排列（第一个是默认源）。
class SourceManager {
  // 默认源（下标 0）放在最前：优先国内可用、已验证的源，MangaDex(英文/非R18) 放最后。
  static final List<ComicSource> sources = [
    DoubaoSource(), // 豆包：国内可用，章节图 AES 解密已验证
    BaoziMangaSource(), // 包子漫画：免登录直链，无反爬（替代需登录的花火漫画）
    YYFunSource(), // 樱漫：应用自有后端，中文内容
    PicacgSource(), // 哔咔：需登录
    JmSource(), // 禁漫：反爬/验证码，可能暂不可用
    MangaDexSource(), // MangaDex：英文/非 R18，兜底
  ];

  static final List<VideoSource> videoSources = [
    AgedMVideoSource(),
    TvTfunVideoSource(),
    XifanVideoSource(),
  ];

  /// 小说源：笔趣阁类聚合（经典模板，host 可配置）。
  static final List<NovelSource> novelSources = [
    BiqugeNovelSource(),
  ];

  /// tier 排序权重：primary 优先，其次 fallback，disabled 最后（且不展示）。
  static const Map<SourceTier, int> _tierWeight = {
    SourceTier.primary: 0,
    SourceTier.fallback: 1,
    SourceTier.disabled: 2,
  };

  static int _current = 0;

  static ComicSource get current => sources[_current];
  static int get currentIndex => _current;

  static void switchTo(int index) {
    if (index >= 0 && index < sources.length) _current = index;
  }

  static ComicSource byId(String id) {
    return sources.firstWhere((s) => s.id == id, orElse: () => current);
  }

  /// 启用中的源列表（配置优先），按 tier（primary→fallback）排序后按注册顺序稳定。
  ///
  /// 在源管理页改过启用/层级后，UI 应重新调用本方法刷新列表。
  static Future<List<ComicSource>> enabledSources() async {
    final cfgs = await SourceConfigStore.all();
    final byId = <String, SourceConfig>{for (final c in cfgs) c.engineId: c};
    final list = sources.where((s) {
      final cfg = byId[s.id];
      final enabled = cfg?.isEnabled ?? s.isEnabled;
      final tier = cfg?.tier ?? s.tier;
      return enabled && tier != SourceTier.disabled;
    }).toList();
    list.sort((a, b) {
      final ta = byId[a.id]?.tier ?? a.tier;
      final tb = byId[b.id]?.tier ?? b.tier;
      return (_tierWeight[ta] ?? 1).compareTo(_tierWeight[tb] ?? 1);
    });
    return list;
  }

  /// 当前源是否已启用（配置优先）。
  static Future<bool> isEnabledOf(String id) async {
    final cfgs = await SourceConfigStore.all();
    for (final c in cfgs) {
      if (c.engineId == id) return c.isEnabled && c.tier != SourceTier.disabled;
    }
    return true;
  }

  /// 若当前源被禁用/不存在，回退到第一个启用源。配置变更后调用。
  static Future<void> ensureEnabledCurrent() async {
    final enabled = await enabledSources();
    if (enabled.isEmpty) {
      _current = 0;
      return;
    }
    final cur = sources[_current];
    if (!enabled.any((s) => s.id == cur.id)) {
      _current = sources.indexOf(enabled.first);
    }
  }

  // ---- 小说源管理（与漫画/动漫平行）----

  static int _currentNovel = 0;

  /// 当前小说源；列表为空时返回 null，调用方需判空。
  static NovelSource? get currentNovel =>
      novelSources.isEmpty ? null : novelSources[_currentNovel];

  static void switchNovelTo(int index) {
    if (index >= 0 && index < novelSources.length) _currentNovel = index;
  }

  static NovelSource? novelById(String id) {
    if (novelSources.isEmpty) return null;
    return novelSources.firstWhere((s) => s.id == id, orElse: () => currentNovel!);
  }

  /// 启用中的小说源列表（配置优先），按 tier 排序。
  static Future<List<NovelSource>> enabledNovelSources() async {
    if (novelSources.isEmpty) return const [];
    final cfgs = await SourceConfigStore.all();
    final byId = <String, SourceConfig>{for (final c in cfgs) c.engineId: c};
    final list = novelSources.where((s) {
      final cfg = byId[s.id];
      final enabled = cfg?.isEnabled ?? s.isEnabled;
      final tier = cfg?.tier ?? s.tier;
      return enabled && tier != SourceTier.disabled;
    }).toList();
    list.sort((a, b) {
      final ta = byId[a.id]?.tier ?? a.tier;
      final tb = byId[b.id]?.tier ?? b.tier;
      return (_tierWeight[ta] ?? 1).compareTo(_tierWeight[tb] ?? 1);
    });
    return list;
  }
}