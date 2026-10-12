import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/xifan_video_source.dart';

/// 实时网络测试：真实请求 next.xifanacg.com（稀饭动漫 Next）。
///
/// [net] 每次请求前间隔 3s 降温，失败最多重试 5 次——站点偶发慢响应。
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

/// 临时验证测试：真实请求稀饭动漫新站，验证 xifan 源迁移后的
/// 分类分页 / 搜索 / 详情（JSON-LD + 剧集 epid）/ 播放（播放页 URL）逻辑。
///
/// 默认跳过：真实网络源验证，源站波动时拖垮本地回归。
/// 需要验源时临时把 _skipLive 改成 false。
const bool _skipLive = true;
void main() {
  test('xifan video source live verification (next.xifanacg.com)', () async {
    final src = XifanVideoSource();

    // 先探测网络连通性，不可达则跳过。
    try {
      await src.categories().timeout(const Duration(seconds: 20));
    } catch (e) {
      // ignore: avoid_print
      print('next.xifanacg.com 网络不可达，跳过测试: $e');
      return;
    }

    // 1. 分类
    final cats = await src.categories();
    // ignore: avoid_print
    print('\n=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats, isNotEmpty);
    expect(cats.first.id, 'all');

    // 2. 全部列表（第 1 页）——含评分/集数 remarks
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

    // 3. 分页：第 1 页与第 2 页结果不同
    final all2 = await net(() => src.listByCategory('all', 2));
    // ignore: avoid_print
    print('\n=== all page2 ===\ncount=${all2.length}');
    expect(all2, isNotEmpty, reason: '第 2 页不应为空（分页需生效）');
    expect(all2.first.id, isNot(all1.first.id),
        reason: '第 1/2 页首条不应相同（分页需生效）');

    // 4. 分类筛选（完结旧番 / 剧场版）
    final finished = await net(() => src.listByCategory('finished', 1));
    // ignore: avoid_print
    print('\n=== finished ===\ncount=${finished.length}');
    expect(finished, isNotEmpty, reason: '完结旧番分类应有内容');

    // 5. 搜索
    final s1 = await net(() => src.search('我推的孩子', 1));
    // ignore: avoid_print
    print('\n=== search 我推的孩子 ===\ncount=${s1.length}');
    expect(s1, isNotEmpty, reason: '搜索「我推的孩子」应有结果');
    expect(
        s1.any((it) => it.name.contains('我推的孩子')),
        isTrue,
        reason: '搜索结果应含《我推的孩子》，实际首条：${s1.first.name}');

    // 6. 详情（588 = 我推的孩子）：JSON-LD 元信息 + 剧集 epid
    final detail = await net(() => src.detail('588'));
    // ignore: avoid_print
    print('\n=== detail 588 ===\nname=${detail.video.name} '
        'area=${detail.area} year=${detail.year} type=${detail.type} '
        'lang=${detail.lang} score=${detail.video.score} '
        'tags=${detail.tags.join('/')} line=${detail.sourceNames} '
        'eps=${detail.episodes.length}');
    for (final e in detail.episodes.take(4)) {
      // ignore: avoid_print
      print('  ep${e.episode}: ${e.title} epid=${e.epid}');
    }
    expect(detail.video.name, contains('我推的孩子'),
        reason: '详情标题应为《我推的孩子》，实际：${detail.video.name}');
    expect(detail.area, '日本', reason: '地区应为日本');
    expect(detail.year, '2023', reason: '年份应为 2023');
    expect(detail.episodes, isNotEmpty, reason: '详情页应解析出剧集');
    expect(detail.episodes.first.epid, isNotNull,
        reason: '剧集应带 epid（playUrl 拼播放页用）');
    expect(detail.tags, isNotEmpty, reason: 'genre 应拆出题材标签');

    // 7. 播放 URL：详情后 playUrl 应从缓存直接拼播放页地址
    final play = await net(() => src.playUrl('588', 1, 1));
    // ignore: avoid_print
    print('\n=== playUrl(588,1,1) ===\n$play');
    expect(play, startsWith('https://next.xifanacg.com/anime/588/play/'),
        reason: '应返回新站播放页 URL，实际：$play');
    expect(play, contains('source='), reason: '播放 URL 应带线路参数');

    // 8. 无缓存路径：新实例未 detail 时 playUrl 也能自愈（重新请求详情）
    final src2 = XifanVideoSource();
    final play2 = await net(() => src2.playUrl('588', 1, 1));
    // ignore: avoid_print
    print('\n=== playUrl no-cache ===\n$play2');
    expect(play2, contains('/anime/588/play/'), reason: '无缓存也应能拼出播放页');
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _skipLive ? '真实网络验证，默认跳过' : false);
}