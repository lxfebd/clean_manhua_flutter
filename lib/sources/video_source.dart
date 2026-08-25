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