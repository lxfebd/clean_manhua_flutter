import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/tvtfun_video_source.dart';

/// 实时网络测试：tvtfun.net 对突发请求偶发限流/慢响应导致单次请求超时。
/// [net] 在每次请求前间隔 3s 降温，并对失败做有限次重试（上限 5 次）。
Future<T> net<T>(Future<T> Function() fn, {int times = 5}) async {
  Object? last;
  for (var i = 0; i < times; i++) {
    await Future.delayed(const Duration(seconds: 3));
    try {
      return await fn();
    } catch (e) {
      last = e;
    }
  }
  throw last!;
}

/// 临时验证测试：真实请求 tvtfun.net，验证重构后的视频源
/// 分类分页 / 筛查维度筛选 / 搜索 / 详情 / 播放页 逻辑。
///
/// **2026-11-04 站点改版**：旧 `/api/videos*` 全 404，本源改用从 Nuxt
/// SSR 载荷逆向出的 `/api/client/*` 接口。本测试即新接口契约的实网回归。
///
/// 默认跳过（源站"半通"时限流会让整测挂满 5 分钟，破坏本地回归确定性）。
/// 需要真机验源时临时把 _skipLive 改成 false。
const bool _skipLive = true;
void main() {
  test('tvtfun video source live verification', () async {
    final src = TvTfunVideoSource();

    // 先探测网络连通性，不可达则跳过（CI 美国机房可能访问不了 tvtfun.net）
    try {
      await src.categories().timeout(const Duration(seconds: 20));
    } catch (e) {
      // ignore: avoid_print
      print('tvtfun.net 网络不可达，跳过测试: $e');
      return;
    }

    // 1. 分类：来自 /api/client/site-modules/video-filter
    final cats = await src.categories();
    // ignore: avoid_print
    print('=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats, isNotEmpty);
    expect(cats.any((c) => c.id == 'all'), isTrue);
    expect(cats.any((c) => c.id.startsWith('tag:')), isTrue,
        reason: '应有 tag: 标签分类（来自 video-filter 的 tag 维度）');
    expect(cats.any((c) => c.id.startsWith('year:')), isTrue,
        reason: '应有 year: 年份分类');
    expect(cats.any((c) => c.id.startsWith('area:')), isTrue,
        reason: '应有 area: 地区分类');

    // 2. 全部列表（第 1 页）—— /api/client/anime?page=1&pageSize=30
    final all1 = await net(() => src.listByCategory('all', 1));
    // ignore: avoid_print
    print('\n=== all page1 ===\ncount=${all1.length}');
    for (final it in all1.take(5)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | score=${it.score} | remarks=${it.remarks}');
    }
    expect(all1, isNotEmpty);
    expect(all1.first.name, isNotEmpty);
    expect(all1.first.pic, isNotEmpty);

    // 3. 分页：第 1 页与第 2 页首条不同
    final all2 = await net(() => src.listByCategory('all', 2));
    // ignore: avoid_print
    print('\n=== all page2 ===\ncount=${all2.length}');
    expect(all2, isNotEmpty, reason: '第 2 页不应为空（分页需生效）');
    expect(all2.first.id, isNot(all1.first.id),
        reason: '第 1/2 页首条不应相同（分页需生效）');

    // 4. 地区筛选（area=日本）
    final jp = await net(() => src.listByCategory('area:日本', 1));
    // ignore: avoid_print
    print('\n=== area:日本 ===\ncount=${jp.length}');
    expect(jp, isNotEmpty, reason: '日本地区筛选应有内容');

    // 5. 年份筛选（year=2026）
    final y2026 = await net(() => src.listByCategory('year:2026', 1));
    // ignore: avoid_print
    print('\n=== year:2026 ===\ncount=${y2026.length}');
    expect(y2026, isNotEmpty, reason: '2026 年份筛选应有内容');

    // 6. 标签筛选（用 video-filter 给出的真实 tag slug，避免硬编码中文猜测）
    final tagCat = cats.firstWhere((c) => c.id.startsWith('tag:'));
    final tagList = await net(() => src.listByCategory(tagCat.id, 1));
    // ignore: avoid_print
    print('\n=== ${tagCat.id} (${tagCat.name}) ===\ncount=${tagList.length}');
    expect(tagList, isNotEmpty, reason: '标签筛选应有内容');

    // 7. 搜索（/api/client/anime?keyword=）
    final s1 = await net(() => src.search('进击', 1));
    // ignore: avoid_print
    print('\n=== search 进击 ===\ncount=${s1.length}');
    expect(s1, isNotEmpty, reason: '搜索「进击」应有命中');
    expect(s1.first.name.contains('进击'), isTrue,
        reason: '搜索「进击」应命中《进击的巨人》系，实际：${s1.first.name}');

    // 8. 详情（/api/client/anime/{slug}，剧集在 seasons[].episodes[] 内）
    final detail = await net(() => src.detail(all1.first.id));
    // ignore: avoid_print
    print('\n=== detail ===\nid=${detail.video.id} name=${detail.video.name} '
        'area=${detail.area} year=${detail.year} type=${detail.type} '
        'tags=${detail.tags.take(5).join('/')} '
        'eps=${detail.episodes.length} descLen=${detail.description?.length ?? 0}');
    for (final e in detail.episodes.take(5)) {
      // ignore: avoid_print
      print('  s${e.season} ep${e.episode}: ${e.title}');
    }
    expect(detail.episodes, isNotEmpty, reason: '详情应解析出剧集');
    expect(detail.video.name, isNotEmpty);

    // 8.1 集号唯一性：站点 number 字段有重复（特别篇/重制与正片共用集号），
    // 本源按 season 内连续序号编号。若此处出现重复，播放映射必然串集。
    final firstSeason = detail.episodes.first.season;
    final nums = detail.episodes
        .where((e) => e.season == firstSeason)
        .map((e) => e.episode)
        .toList();
    // ignore: avoid_print
    print('\n=== 集号唯一性（season $firstSeason）===\ncount=${nums.length} '
        'unique=${nums.toSet().length}');
    expect(nums.toSet().length, nums.length,
        reason: '同一 season 内集号必须唯一，否则 playUrl 的缓存键会互相覆盖导致串集');

    // 8.2 播放映射：第 1 集应落到该番剧 watchPath 末段 1（不被同号集覆盖）
    final firstPlay = await net(() => src.playUrl(detail.video.id, firstSeason, 1));
    // ignore: avoid_print
    print('\n=== 首集播放页 ===\n$firstPlay');
    expect(firstPlay, contains('/watch/${detail.video.id}/1'),
        reason: '首集应映射到 watchPath 末段 1，而不是被其它同号集覆盖');

    // 9. 播放：返回站内 watch 页（非直链 → 播放器走 WebView 通道）
    final play = await net(() => src.playUrl(all1.first.id, 1, 1));
    // ignore: avoid_print
    print('\n=== playUrl ===\n$play');
    expect(play, contains('/watch/'),
        reason: '改版后播放键是 /watch/{slug}/{ep}，由 WebView 承载验证与播放');
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
