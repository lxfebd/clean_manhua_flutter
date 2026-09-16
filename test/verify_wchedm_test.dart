import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/wche_dm_video_source.dart';

/// 实时网络测试：真实请求 www.16dns.com（风车动漫）。
///
/// [net] 每次请求前间隔 3s 降温，失败最多重试 5 次。
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

/// 临时验证测试：默认跳过。2026-09-12 实测站点 Cloudflare 节点对当前网络
/// 强制断连（TCP RST + 握手超时），无法验证；站点恢复后把 _skipLive 改成
/// false 再跑。解析逻辑已用存留的真实 HTML 离线验证过（列表 47/49/52 条、
/// 详情标题/封面/2 集/简介、播放页 m3u8 全对）。
const bool _skipLive = true;

void main() {
  test('wchedm video source live verification', () async {
    final src = WcheDmVideoSource();

    try {
      await src.categories().timeout(const Duration(seconds: 20));
    } catch (e) {
      // ignore: avoid_print
      print('16dns.com 网络不可达，跳过测试: $e');
      return;
    }

    // 1. 分类
    final cats = await src.categories();
    // ignore: avoid_print
    print('=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats, isNotEmpty);
    expect(cats.any((c) => c.id == '1666'), isTrue);

    // 2. 分类列表：条目数、封面、标题解码。
    // 页顶固定推荐区 10 张卡片两页重复，故只要求条目数达标，不按首条判分页。
    final c1666 = await net(() => src.listByCategory('1666', 1));
    // ignore: avoid_print
    print('\n=== cat 1666 page1 ===\ncount=${c1666.length}');
    for (final it in c1666.take(5)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | pic=${it.pic}');
    }
    expect(c1666.length, greaterThanOrEqualTo(30), reason: '列表应有约 47 条');
    expect(c1666.first.name.contains('&#'), isFalse,
        reason: '标题不应残留 HTML 数字实体，实际：${c1666.first.name}');
    // 封面来自 data-original（主列表区）或内联 background url（推荐区）
    expect(c1666.first.pic, isNotEmpty, reason: '列表封面不应为空');
    expect(c1666.first.pic, startsWith('http'));

    // 3. 分页：两页应各有独有条目（首条来自固定推荐区，不可用于判断）
    final c1666p2 = await net(() => src.listByCategory('1666', 2));
    // ignore: avoid_print
    print('\n=== cat 1666 page2 ===\ncount=${c1666p2.length}');
    final ids1 = c1666.map((e) => e.id).toSet();
    final onlyP2 = c1666p2.where((e) => !ids1.contains(e.id)).length;
    expect(onlyP2, greaterThan(0),
        reason: '第 2 页应有独有条目（实测 37 个），实际 $onlyP2');

    // 4. 搜索：站点端点已失效，返回空
    final s = await src.search('火影', 1);
    // ignore: avoid_print
    print('\n=== search ===\ncount=${s.length}');
    expect(s, isEmpty, reason: '搜索端点已失效，应返回空列表');

    // 5. 详情
    final detail = await net(() => src.detail('16613476'));
    // ignore: avoid_print
    print('\n=== detail ===\n'
        'id=${detail.video.id} name=${detail.video.name}\n'
        'area=${detail.area} year=${detail.year} type=${detail.type}\n'
        'cover=${detail.cover}\neps=${detail.episodes.length}\n'
        'descLen=${detail.description?.length ?? 0}');
    for (final e in detail.episodes) {
      // ignore: avoid_print
      print('  s${e.season}ep${e.episode}: ${e.title}');
    }
    // h1 尾部有评分 span（如 6.0），标题必须只取裸文本部分。
    // 注意该作品标题本身含「...」，故不能断言「不含小数点」。
    expect(
      RegExp(r'\d+\.\d+$').hasMatch(detail.video.name),
      isFalse,
      reason: '标题不应以评分数字结尾，实际：${detail.video.name}',
    );
    expect(detail.video.name, contains('套套'));
    expect(detail.cover, contains('upload/vod'));
    // 剧集号是 0 基（-0-0 即第 01 集），标题由站点给出
    expect(detail.episodes, isNotEmpty, reason: '详情页应解析出剧集');
    expect(detail.episodes.first.episode, isZero,
        reason: '16dns 剧集号是 0 基，首集应为 0');
    expect(detail.episodes.first.title, isNotEmpty);
    expect(detail.area, isNotNull);

    // 6. 播放：m3u8 直链在 `var now="…"`
    final play = await net(() => src.playUrl('16613476', 1, 0));
    // ignore: avoid_print
    print('\n=== playUrl ===\n$play');
    expect(play, contains('m3u8'));
    expect(play.startsWith('https://'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
