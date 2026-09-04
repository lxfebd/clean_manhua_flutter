import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/anime1_video_source.dart';

/// 临时验证测试：真实请求 anime1.me，验证 Anime1 视频源
/// 目录分类 / 分页 / 搜索 / 详情（剧集解析）/ 播放（剧集页 URL）逻辑。
///
/// 注意：Anime1 为纯文本站（无封面/无简介），列表项 pic 为空属正常；
/// 播放走 WebView（CDN 直链需签名 Cookie），playUrl 返回剧集页 URL。
///
/// 默认跳过：真实网络源验证，源站波动时拖垮本地回归。
/// 需要验源时临时把 _skipLive 改成 false。
const bool _skipLive = true;
void main() {
  test('anime1 video source live verification', () async {
    final src = Anime1VideoSource();

    // 先探测网络连通性，不可达则跳过（CI 美国机房可能访问不了 anime1.me）
    try {
      await src.categories().timeout(const Duration(seconds: 15));
    } catch (e) {
      // ignore: avoid_print
      print('anime1.me 网络不可达，跳过测试: $e');
      return;
    }

    // 1. 分类：全部 + 連載中 + 年季度
    final cats = await src.categories();
    // ignore: avoid_print
    print('\n=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats, isNotEmpty);
    expect(cats.first.id, 'all');
    expect(cats.any((c) => c.id == 'ongoing'), isTrue,
        reason: '应有「連載中」分类');

    // 2. 全部列表第 1 页（20 条）
    final all1 = await src.listByCategory('all', 1);
    // ignore: avoid_print
    print('\n=== all page1 ===\ncount=${all1.length}');
    for (final it in all1.take(5)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | remarks=${it.remarks} | yname=${it.yname}');
    }
    expect(all1, isNotEmpty);
    expect(all1.length, lessThanOrEqualTo(20));
    expect(all1.first.name, isNotEmpty);
    expect(all1.first.id, isNotEmpty);

    // 3. 分页：第 1 页与第 2 页结果不同
    final all2 = await src.listByCategory('all', 2);
    // ignore: avoid_print
    print('\n=== all page2 ===\ncount=${all2.length}');
    expect(all2, isNotEmpty, reason: '第 2 页不应为空（分页需生效）');
    expect(all2.first.id, isNot(all1.first.id),
        reason: '第 1/2 页首条不应相同（分页需生效）');

    // 4. 連載中分类
    final ongoing = await src.listByCategory('ongoing', 1);
    // ignore: avoid_print
    print('\n=== ongoing ===\ncount=${ongoing.length}');
    expect(ongoing, isNotEmpty, reason: '連載中分类应有内容');

    // 5. 搜索
    final s = await src.search('間諜', 1);
    // ignore: avoid_print
    print('\n=== search 間諜 ===\ncount=${s.length}');
    expect(s, isNotEmpty);
    for (final it in s.take(3)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | remarks=${it.remarks}');
    }

    // 6. 详情（取第一条，解析剧集列表）
    final targetId = s.isNotEmpty ? s.first.id : all1.first.id;
    final detail = await src.detail(targetId);
    // ignore: avoid_print
    print('\n=== detail ===\nid=${detail.video.id} name=${detail.video.name} '
        'year=${detail.year} type=${detail.type} tags=${detail.tags.join('/')} '
        'eps=${detail.episodes.length}');
    for (final e in detail.episodes.take(5)) {
      // ignore: avoid_print
      print('  ep${e.episode}: ${e.title}');
    }
    expect(detail.episodes, isNotEmpty, reason: '详情页应解析出剧集');
    expect(detail.episodes.first.episode, 1);

    // 7. 播放 URL：返回剧集页 URL（WebView 播放，CDN 直链需 Cookie）
    final play = await src.playUrl(targetId, 1, detail.episodes.first.episode);
    // ignore: avoid_print
    print('\n=== playUrl ===\n$play');
    expect(play, matches(RegExp(r'^https://anime1\.me/\d+$')),
        reason: '应返回 anime1.me 剧集页 URL（WebView 播放）');
  }, timeout: const Timeout(Duration(minutes: 3)), skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
