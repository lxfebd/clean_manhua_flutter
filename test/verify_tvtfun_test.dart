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

/// 临时验证测试：真实请求 tvtfun.net，验证视频源
/// 分类分页 / 标签筛选 / 搜索 / 详情 / 播放 逻辑。
void main() {
  test('tvtfun video source live verification', () async {
    final src = TvTfunVideoSource();

    // 1. 分类
    final cats = await src.categories();
    // ignore: avoid_print
    print('=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats, isNotEmpty);
    expect(cats.any((c) => c.id == 'jp'), isTrue);
    expect(cats.any((c) => c.id.startsWith('tag_')), isTrue,
        reason: '应有 tag 标签分类（如 tag_恋爱）');
    expect(cats.any((c) => c.id.startsWith('year_')), isTrue,
        reason: '应有 year_ 年份分类（如 year_2026）');

    // 2. 全部列表（第 1 页）
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

    // 4. 地区分类（日本）
    final jp = await net(() => src.listByCategory('jp', 1));
    // ignore: avoid_print
    print('\n=== jp ===\ncount=${jp.length}');
    expect(jp, isNotEmpty);

    // 5. 标签分类（恋爱）
    final love = await net(() => src.listByCategory('tag_恋爱', 1));
    // ignore: avoid_print
    print('\n=== tag_恋爱 ===\ncount=${love.length}');
    for (final it in love.take(3)) {
      // ignore: avoid_print
      print('  ${it.name} | remarks=${it.remarks}');
    }
    expect(love, isNotEmpty, reason: '恋爱标签分类应有内容');

    // 5.5 年份筛选（year_2026）——服务端支持 year 查询参数，返回条目均应为 2026 年
    final y2026 = await net(() => src.listByCategory('year_2026', 1));
    // ignore: avoid_print
    print('\n=== year_2026 ===\ncount=${y2026.length}');
    for (final it in y2026.take(3)) {
      // ignore: avoid_print
      print('  ${it.name} | lang=${it.lang} | remarks=${it.remarks}');
    }
    expect(y2026, isNotEmpty, reason: '2026 年份筛选应有内容');

    // 6. 搜索（分页第 2 页）
    final s1 = await net(() => src.search('海贼', 1));
    final s2 = await net(() => src.search('海贼', 2));
    // ignore: avoid_print
    print('\n=== search 海贼 ===\npage1=${s1.length} page2=${s2.length}');
    expect(s1, isNotEmpty);
    // 搜索「海贼」命中《海贼王》，但大陆站用译名《航海王》，两者都算命中
    expect(s1.first.name.contains('海贼') || s1.first.name.contains('航海王'),
        isTrue, reason: '搜索「海贼」应命中《海贼王/航海王》，实际：${s1.first.name}');

    // 7. 详情
    final detail = await net(() => src.detail(all1.first.id));
    // ignore: avoid_print
    print('\n=== detail ===\nid=${detail.video.id} name=${detail.video.name} '
        'area=${detail.area} lang=${detail.lang} year=${detail.year} '
        'type=${detail.type} tags=${detail.tags.join('/')} '
        'eps=${detail.episodes.length} descLen=${detail.description?.length ?? 0}');
    for (final e in detail.episodes.take(5)) {
      // ignore: avoid_print
      print('  ep${e.episode}: ${e.title}');
    }
    expect(detail.episodes, isNotEmpty, reason: '详情页应解析出剧集');

    // 8. 播放 URL
    final play = await net(() => src.playUrl(all1.first.id, 1, 0));
    // ignore: avoid_print
    print('\n=== playUrl ===\n$play');
    expect(play, contains('/video/${all1.first.id}/play'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
