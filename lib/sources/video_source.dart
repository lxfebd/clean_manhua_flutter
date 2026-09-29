import '../models/comic_item.dart';
import 'comic_source.dart';

/// 视频（动漫/番剧）数据源统一接口。
/// 与 ComicSource 不同：剧集返回 [VideoEpisode]，每个剧集对应一个播放 URL
/// （可能是 m3u8、mp4，或一个 iframe 解析器链接）。
abstract class VideoSource {
  String get id;
  String get name;

  /// 一级分类 / 频道列表（如全部 / 日本 / 中国 / 剧场版 等）。
  Future<List<Category>> categories();

  /// 按分类分页列表（page 从 1 开始）。
  Future<List<ComicItem>> listByCategory(String categoryId, int page);

  /// 搜索剧集。
  Future<List<ComicItem>> search(String keyword, int page);

  /// 加载番剧详情（剧集列表 + 元信息）。
  Future<VideoDetail> detail(String videoId);

  /// 单集播放入口：返回 [playUrl]，可直接交给 WebView 或 m3u8 播放器。
  /// 通常是番剧站点提供的 iframe 解析器 URL（站点加密了真实 m3u8，
  /// 用通用解析器代播）。
  Future<String> playUrl(String videoId, int season, int episode);
}

class VideoEpisode {
  final int season;
  final int episode;
  final String title;
  VideoEpisode(this.season, this.episode, this.title);
}

class VideoDetail {
  final ComicItem video;
  final List<VideoEpisode> episodes;
  final String? description;
  final String? cover;
  final String? area; // 地区
  final String? year;
  final String? type; // TV / 剧场版 / OVA
  /// 配音/语言（如「日语」「国语」），详情页展示用。
  final String? lang;
  /// 标签列表（如 恋爱 / 搞笑 / 奇幻），详情页展示用。
  final List<String> tags;
  /// 播放源（线路）名称映射：key 为 [VideoEpisode.season]（1 基），
  /// value 为源名（如「稀饭新番主线-1」）。为 null 或缺失某 key 时按「线路 N」兜底。
  final Map<int, String>? sourceNames;
  VideoDetail(this.video, this.episodes,
      {this.description,
      this.cover,
      this.area,
      this.year,
      this.type,
      this.lang,
      this.tags = const [],
      this.sourceNames});
}

/// 判断 URL 是否为直接可播的视频媒体直链。
///
/// 支持常见的视频扩展名、HLS 路径，以及已知视频 CDN 域名（如 toutiao50.com）。
/// 从 resolve-play-url 等 API 拦截到的 URL 也会被放行（由调用方保证来源可靠）。
bool isDirectMediaUrl(String url) {
  if (url.isEmpty) return false;
  final u = url.toLowerCase();
  // 视频文件扩展名
  if (u.contains('.m3u8') || u.contains('.mp4') ||
      u.contains('.webm') || u.contains('.mkv') || u.contains('.flv')) {
    return true;
  }
  // HLS / TS 流路径
  if (u.contains('/hls/') || u.contains('.ts')) {
    return true;
  }
  // 字节跳动 TOS 对象存储视频路径（AGE 等源换域名但路径固定）
  if (u.contains('/video/tos/')) {
    return true;
  }
  // 已知视频 CDN 域名（头条/抖音/topbuzz/capcut/剪映等字节系）
  if (u.contains('toutiao50.com') || u.contains('toutiao') ||
      u.contains('pstatp.com') || u.contains('bytedance') ||
      u.contains('douyin') || u.contains('ixigua.com') ||
      u.contains('snssdk.com') || u.contains('topbuzzcdn.com') ||
      u.contains('topbuzz.com') || u.contains('capcutvod.com') ||
      u.contains('capcut.com')) {
    return true;
  }
  // blob URL（WASM 解密的 MSE 流）
  if (u.startsWith('blob:')) return true;
  return false;
}

/// 判断 URL 是否为广告直链：path 独立段 ad/ads/adv 等，或已知广告域名。
/// 广告 m3u8 混入正片流（站点先放广告再放正片）时，若广告被无条件捕获，
/// 会先接管原生播放器、从 0:00 播广告；此判定用于在捕获入口拦截，
/// 确保正片成为首个被接管的对象。
bool isAdMediaUrl(String url) {
  if (url.isEmpty) return false;
  final u = url.toLowerCase();
  final noQuery = u.split('?').first;
  final segments = noQuery.split('/');
  const adSegments = {
    'ad', 'ads', 'adv', 'advert', 'adverts', 'advertise', 'advertising',
    'advertisement', 'adserve', 'adserver', 'adservice', 'adtrack', 'adtag',
  };
  for (final s in segments) {
    if (adSegments.contains(s)) return true;
  }
  const adDomains = {
    'doubleclick', 'googlesyndication', 'amazon-adsystem', 'adnxs',
    'applovin', 'unityads', 'adcolony',
  };
  for (final d in adDomains) {
    if (u.contains(d)) return true;
  }
  return false;
}