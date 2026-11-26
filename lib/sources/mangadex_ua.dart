/// MangaDex 专用请求头（api + uploads + *.mangadex.network 三处共用）。
///
/// ## 为什么必须单独一处
/// 2026-11 起 `api.mangadex.org` 与 `uploads.mangadex.org` 前置了
/// **POWBlock** 工作量证明反爬网关（SHA-256 前导零 PoW，
/// https://github.com/8Protons/POWBlock）。它对「自称浏览器却不是浏览器」
/// 的请求一律返回 **状态码 200 + 一张 2KB 的 HTML 验证页**：
///
/// | UA | 实测结果（2026-11-26，同机同时刻） |
/// |---|---|
/// | `Mozilla/5.0 (Windows NT 10.0; …) AppleWebKit/537.36` | 2022B HTML 挑战页 |
/// | `Mozilla/5.0 (compatible; xingmanxia/1.5.7)` | 2022B HTML 挑战页 |
/// | `xingmanxia/1.5.7 (https://github.com/…)` | 正常 JSON / image |
/// | 不带 UA / `curl/8.0` / `Dart/3.x` | 正常 |
///
/// 对接口，HTML 会让 `jsonDecode` 首字符即抛 `FormatException`，看起来像
/// 「API 契约变更」；对图片，HTML 会被解码端当成**损坏图**，表现为封面全灰、
/// 章节图全裂，日志里完全看不出是反爬。所以两个域名的 UA 必须一致修正。
///
/// ## 为什么不能用 `NetConn.defaultUA`
/// 那是**全项目共用的伪装浏览器 UA**——国内源（动漫屋、风车等）不伪装就
/// 直接 403/掉内容，必需。但它是 MangaDex 的毒药。这是域名级分流，
/// 不是全局改。
///
/// ## 版本号
/// UA 里带版本是 MangaDex API 规范要求（便于对方定位问题）。但**不能写死**：
/// 写死 1.5.7 后下次升版就与实际版本不符，对方排查时会拿到错误信息。
/// 这里从 [UpdateChecker.currentVersion] 取（启动时由 PackageInfo 写入的
/// 真实版本），拿不到时退回 [fallbackVersion]。
library;

import '../net/update_checker.dart';

/// 项目地址（MangaDex 规范要求 UA 可溯源到项目）。
const String kMangaDexUaContact =
    'https://github.com/lxfebd/clean_manhua_flutter';

/// 版本号取不到时的兜底（保证 UA 仍带形如 `x.y.z` 的版本，不会变成 `app/`）。
const String kMangaDexUaFallbackVersion = '1.0.0';

/// 统一的 MangaDex 应用 UA（形如 `xingmanxia/1.5.7 (https://github.com/…)`）。
///
/// 注意**不要**去掉括号里的项目地址：那是 POWBlock / 官方 API 判断
/// 「这是谁在请求」的依据，也是实测中唯一稳定放行的形态。
String mangaDexUserAgent() {
  final v = UpdateChecker.currentVersion();
  final ver = v.trim().isEmpty ? kMangaDexUaFallbackVersion : v.trim();
  return 'xingmanxia/$ver ($kMangaDexUaContact)';
}

/// MangaDex 的完整请求头（接口用，要求 JSON）。
Map<String, String> mangaDexApiHeaders() => {
      'User-Agent': mangaDexUserAgent(),
      'Accept': 'application/json',
    };

/// MangaDex 静态资源请求头（图片用；不要求 Accept，省一个字节都值得）。
Map<String, String> mangaDexImageHeaders() => {
      'User-Agent': mangaDexUserAgent(),
    };

/// 判断 URL 是否属于 MangaDex 全线域名（api / uploads / at-home CDN）。
///
/// 三个域名的共同点：都在同一套 POWBlock 网关后面，都必须用应用 UA。
bool isMangaDexHost(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.endsWith('mangadex.org') || host.endsWith('mangadex.network');
}
