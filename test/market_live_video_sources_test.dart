import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_video_source.dart';

/// 市场 video 源的**真实网络**链路验证：分类 → 分类列表 → 详情剧集 → 播放地址。
///
/// 补齐 comic / novel 两侧已有的实时验证：视频源最常见的假阳性是「列表能出、
/// 剧集能出、但播放地址藏在需要 JS 的播放器里」——只有真取到 m3u8/mp4 才算能用。
/// 本测试第一次跑就抓出风车动漫的真实缺陷：缺 `categories` 时 App 用空串取数，
/// 站点把 `/html/-{page}.html` 302 回首页，列表永远停在同一页（加载更多失效）。
/// 测试路径与 App 实际路径一致：动漫首页（ui/anime_home_page.dart）取
/// `categories()` 首个分类，分类为空时用空串走 `listByCategory('', page)`。
///
/// CI 不出网：仅当环境变量 `XM_LIVE=1` 时执行。本地验证：
/// `$env:XM_LIVE=1; flutter test test/market_live_video_sources_test.dart`
void main() {
  final liveOn = (Platform.environment['XM_LIVE'] ?? '').trim() == '1';
  final skip = liveOn ? null : '设置 XM_LIVE=1 才跑真实站点验证';

  // 离线可查：DSL 结构校验不依赖网络，始终跑。
  // ashan_yy 是**鞍山影院（DSL 版）**：站点被 SNI 重置、且需代理，所以只有
  // 结构校验、没有 live 用例（live 会恒红）；结构校验仍要跑，否则索引里带着
  // 一个字段写坏的定义没人拦（market_live_index_test 也已断言它必须被注册）。
  for (final path in const [
    'sources/wche_dm.json',
    'sources/ashan_yy.json',
  ]) {
    test('视频源 $path：DSL 校验', () {
      final d = decodeCustomSourceDef(File(path).readAsStringSync());
      expect(d, isNotNull);
      expect(d!.validate(), isEmpty);
    });
  }

  test('live 视频源 sources/wche_dm.json：列表 → 详情 → 剧集 → 播放地址',
      () async {
    final d = decodeCustomSourceDef(File('sources/wche_dm.json').readAsStringSync())!;
    final src = DslVideoSource(d);

    // 与首页一致：分类可以为空，空则用空串走默认列表
    final cats = await src.categories();
    expect(cats.length, greaterThan(1), reason: '分类抽取失败：分类浏览没有入口');
    final catId = cats.isEmpty ? '' : cats.first.id;

    final list = await src.listByCategory(catId, 1);
    expect(list.length, greaterThan(3), reason: '首屏列表为空：装进市场就是空页');
    expect(list.first.id.isNotEmpty, isTrue);
    expect(list.first.name.trim().isNotEmpty, isTrue);
    expect(list.first.pic, contains('http'), reason: '列表封面抽取失败');

    // 翻页必须真的换内容，否则「加载更多」反复拿到同一页
    final next = await src.listByCategory(catId, 2);
    expect(
        next.map((e) => e.id).toSet().intersection(list.map((e) => e.id).toSet()),
        isEmpty,
        reason: '分类第 2 页与第 1 页内容相同：分页无效');

    // 首条可能没有可用剧集（站点下架 / 线路空）：在前几条里找一部真能播的
    var episodes = 0;
    String? url;
    for (final item in list.take(5)) {
      final detail = await src.detail(item.id);
      expect(detail.video.name.trim().isNotEmpty, isTrue, reason: '标题抽取失败');
      if (detail.episodes.isEmpty) continue;
      episodes = detail.episodes.length;
      final first = detail.episodes.first;
      try {
        final u = await src.playUrl(item.id, first.season, first.episode);
        if (u.isNotEmpty) {
          url = u;
          break;
        }
      } catch (_) {
        // 这条线路取不到，换下一条
      }
    }
    expect(episodes, greaterThan(0), reason: '前 5 部都没有剧集列表');
    expect(url, isNotNull, reason: '前 5 部都取不到播放地址（可能藏在需要 JS 的播放器里）');
    expect(url, startsWith('http'), reason: '播放地址不是可用 URL');
    expect(url, isNot(contains('base64')), reason: '取到的是编码后的占位内容');
  }, skip: skip, timeout: const Timeout(Duration(seconds: 180)));
}
