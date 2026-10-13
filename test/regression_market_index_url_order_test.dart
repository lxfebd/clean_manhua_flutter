import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/market_index_urls.dart';

/// 锁死索引候选地址的**排序原则**：官方直连 → 回源型第三方代理 → CDN 缓存镜像。
///
/// 为什么值得锁：2026-10-13 事故——jsDelivr 对 `@main` 缓存 7 天且无自助
/// purge，发布新索引后 raw 已更新、jsDelivr 仍旧版。当时 jsDelivr 排在候选
/// 前列，raw 一旦超时（国内常见）用户就装到缺新源、含已下架死源的旧市场，
/// 且 UI 无任何异常。修法是把「回源且最新」的 GH 代理插到 jsDelivr 之前。
/// 本测试保证这个顺序不被无意改回去。
void main() {
  int firstIdx(List<String> urls, bool Function(String) test) {
    for (var i = 0; i < urls.length; i++) {
      if (test(urls[i])) return i;
    }
    return -1;
  }

  // 注意：gh-proxy 的 URL 里也内嵌 raw.githubusercontent.com 子串，
  // 判「官方直连」必须看 host，不能用 contains。
  final official = firstIdx(
      kMarketIndexUrls, (u) => Uri.parse(u).host == 'raw.githubusercontent.com');
  final originProxy = firstIdx(kMarketIndexUrls,
      (u) => u.contains('gh-proxy.com') || u.contains('ghproxy.net'));
  final cdnCache = firstIdx(kMarketIndexUrls, (u) => u.contains('jsdelivr'));

  test('候选顺序：官方直连在回源代理之前', () {
    expect(official, greaterThanOrEqualTo(0));
    expect(originProxy, greaterThanOrEqualTo(0));
    expect(official, lessThan(originProxy),
        reason: '可信度最高的官方直连必须最先尝试');
  });

  test('候选顺序：回源代理在 CDN 缓存镜像之前（本次事故根因）', () {
    expect(originProxy, lessThan(cdnCache),
        reason: 'jsDelivr 对 @main 缓存 7 天且无自助 purge，必须排在回源代理之后，'
            '否则 raw 超时后用户会装到旧索引');
  });

  test('至少保留一个官方直连 + 一个回源代理 + 一个 CDN 兜底', () {
    expect(
        kMarketIndexUrls
            .where((u) => Uri.parse(u).host == 'raw.githubusercontent.com'),
        isNotEmpty,
        reason: '没有官方直连就没有可信的最新来源');
    expect(kMarketIndexUrls.any((u) => u.contains('gh-proxy.com') || u.contains('ghproxy.net')),
        isTrue,
        reason: '没有回源代理时，国内 raw 超时就直接掉进 7 天旧缓存');
    expect(kMarketIndexUrls.any((u) => u.contains('jsdelivr')), isTrue,
        reason: 'CDN 兜底仍是最后一道可用保障');
  });

  test('总预算不小于单候选超时（否则首个候选都跑不满）', () {
    expect(kMarketIndexTotalTimeout, greaterThanOrEqualTo(kMarketIndexTimeout),
        reason: 'totalTimeout < timeout 会让第一个候选立刻被截断，链形同虚设');
  });
}
