import 'agedm_video_source.dart';
import 'anime1_video_source.dart';
import 'biquge_novel_source.dart';
import 'comic_source.dart';
import 'dm5_source.dart';
import 'doubao_source.dart';
import 'jm_source.dart';
import 'local_novel_source.dart';
import 'mangadex_source.dart';
import 'novel_source.dart';
import 'source_config.dart';
import 'source_plugin.dart';
import 'tvtfun_video_source.dart';
import 'video_source.dart';
import 'xbiquge_novel_source.dart';
import 'xifan_video_source.dart';

/// 多源聚合管理器：注册所有可用源，支持切换当前源。
/// 源列表按推荐度排列（第一个是默认源）。
///
/// 插件化说明：内置源以静态列表形式存在（开箱即用、零异步注册成本）；
/// 自定义源（JSON DSL 导入）通过 [SourcePlugin.bind] 动态 [add]/[remove]，
/// 启用状态经 SourceConfigStore 统一持久化，两种来源对 UI 完全透明。
class SourceManager {
  // 默认源（下标 0）放在最前：优先国内可用、已验证的源，MangaDex(英文/非 R18) 放最后。
  // 注：包子漫画(baozimh)因国内访问时命中"下载APP"落地页已移除；樱漫(YYFun)实为写真APP内容需登录已移除。
  static final List<ComicSource> sources = [
    Dm5Source(), // 动漫屋：国内可用，免登录，移动端图片直链（默认源）
    DoubaoSource(), // 豆包：国内可用，免登录，章节图 AES 解密已验证
    JmSource(), // 禁漫：反爬/验证码，可能暂不可用
    MangaDexSource(), // MangaDex：英文/非 R18，兜底
  ];

  /// 一次性注册各源的图片降级钩子（备用镜像/省空间压缩图）。
  /// 幂等：多次调用只注册一次，避免热重载后重复挂链。
  static bool _degradationRegistered = false;
  static void init() {
    if (_degradationRegistered) return;
    _degradationRegistered = true;
    JmSource.registerDegradation();
    MangaDexSource.registerDegradation();
  }

  static final List<VideoSource> videoSources = [
    AgedMVideoSource(),
    TvTfunVideoSource(),
    XifanVideoSource(),
    Anime1VideoSource(),
  ];

  static VideoSource? videoById(String id) {
    for (final s in videoSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 小说源：笔趣阁（tobiquge.com）+ 新笔趣阁（xbiquge.bz）+ 本地导入。
  /// 本地源放最后：不参与网络列表，仅在书架/导入入口展示。
  static final List<NovelSource> novelSources = [
    BiqugeNovelSource(),
    XbiqugeNovelSource(),
    LocalNovelSource(),
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

  // ---- 插件化源：动态增删（自定义源 DSL 经 SourcePlugin.bind/unbind 调用）----

  /// 动态注册漫画源实现（幂等：同 id 已存在则忽略）。
  static bool addSource(ComicSource src) {
    if (sources.any((s) => s.id == src.id)) return false;
    sources.add(src);
    return true;
  }

  /// 移除漫画源实现（不可移除内置源；当前源被移除时回退到第一个）。
  static bool removeSource(String id) {
    final builtinIds = {
      'dm5', 'doubao', 'jm', 'mangadex',
    };
    if (builtinIds.contains(id)) return false;
    final idx = sources.indexWhere((s) => s.id == id);
    if (idx < 0) return false;
    sources.removeAt(idx);
    if (_current >= sources.length) _current = 0;
    return true;
  }

  /// 动态注册视频源实现（幂等）。
  static bool addVideoSource(VideoSource src) {
    if (videoSources.any((s) => s.id == src.id)) return false;
    videoSources.add(src);
    return true;
  }

  static bool removeVideoSource(String id) {
    if (id == 'agedm' || id == 'tvtfun' || id == 'xifan' || id == 'anime1') {
      return false;
    }
    final idx = videoSources.indexWhere((s) => s.id == id);
    if (idx < 0) return false;
    videoSources.removeAt(idx);
    return true;
  }

  /// 动态注册小说源实现（幂等）。
  static bool addNovelSource(NovelSource src) {
    if (novelSources.any((s) => s.id == src.id)) return false;
    novelSources.add(src);
    return true;
  }

  static bool removeNovelSource(String id) {
    if (id == 'biquge' || id == 'xbiquge' || id == 'local_novel') return false;
    final idx = novelSources.indexWhere((s) => s.id == id);
    if (idx < 0) return false;
    novelSources.removeAt(idx);
    if (_currentNovel >= novelSources.length) _currentNovel = 0;
    return true;
  }
}