import '../models/comic_item.dart';
import 'comic_source.dart';
import 'source_config.dart';

/// 视频（动漫/番剧）数据源统一接口。
/// 与 ComicSource 不同：剧集返回 [VideoEpisode]，每个剧集对应一个播放 URL
/// （可能是 m3u8、mp4，或一个 iframe 解析器链接）。
abstract class VideoSource {
  String get id;
  String get name;

  /// 是否需要登录。默认 false，子类可覆盖。
  bool get requiresLogin => false;

  /// 是否启用。默认 true。
  bool get isEnabled => true;

  /// 源优先级层级。默认 fallback。
  SourceTier get tier => SourceTier.fallback;

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
  // HLS / TS 流路径。`.ts` 收窄到路径边界判定（去 query 后以 .ts 结尾，
  // 或 /hls/ 上下文）：裸子串 `.ts` 会把 .tsx/.tsv/xxx.ts.txt 误判成直链。
  final noQueryPath = u.split('?').first;
  if (noQueryPath.contains('/hls/') || noQueryPath.endsWith('.ts')) {
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
  // 已知正片直链豁免：AGE 等源换域名但 /video/tos/ 路径固定
  // （[isDirectMediaUrl] 已按正片放行），在字节 CDN 黑名单之前豁免，
  // 消除「isDirect 放行 vs isAd 拦截」的自相矛盾；豁免放在 ad 段检查之后，
  // /video/tos/ad/… 仍会被上面的 ad 独立段拦住，无洞。
  if (noQuery.contains('/video/tos/')) return false;
  // 字节系内容/广告 CDN：toutiao/topbuzz 等域名被 [isDirectMediaUrl] 判为
  // 「直链」（按域名白名单），广告流若走这些 CDN 会被当成正片接管原生播放器
  // （从 0:00 播广告）。本应用 6 个视频源的正片均不用字节 CDN，这里整体拦截。
  // 按 host（authority 段）匹配而非全 URL 子串：path/文件名里嵌
  // `pstatp.com.m3u8` 的形态不再误判为命中；无 scheme 的裸域名 URL 也
  // 正确取到 host（首段即 authority）。
  const byteAdCdns = {'pstatp.com', 'topbuzzcdn.com', 'capcut.com'};
  var authority = noQuery;
  final schemeIdx = authority.indexOf('://');
  if (schemeIdx >= 0) authority = authority.substring(schemeIdx + 3);
  final slashIdx = authority.indexOf('/');
  if (slashIdx >= 0) authority = authority.substring(0, slashIdx);
  final host = authority.toLowerCase();
  for (final d in byteAdCdns) {
    if (host == d || host.endsWith('.$d')) return true;
  }
  return false;
}

/// 优选 IP → 源站域名 的映射。部分源为绕开 DNS 污染会用「优选 IP 直连」，
/// 但该 IP 与源站之间走 SNI/Host 区分，拉流时（mpv/WebView）必须带正确
/// 的 Host 头，否则 TLS 证书校验不过或回落到错误的虚拟主机。
const Map<String, String> preferredIpHosts = {
  // TvTFun：Cloudflare 优选 IP（见 TvTfunVideoSource.cloudflareIp）。
  '104.16.150.186': 'www.tvtfun.net',
};

/// 返回直连 URL 所需的 Host 头：已知优选 IP 映射到对应源站域名；
/// 未知 IP / 域名地址不补（域名地址本身即 Host）。
/// 此前两个播放页各自硬编码 `Host: www.tvtfun.net`（IP 直连一律按
/// tvtfun 处理）——非 tvtfun 源的 IP 直连会被打错 Host，统一收口到这里。
Map<String, String> hostHeaderFor(String url) {
  try {
    final host = Uri.parse(url).host;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
      final mapped = preferredIpHosts[host];
      if (mapped != null) return {'Host': mapped};
      return const {};
    }
  } catch (_) {}
  return const {};
}