import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/ashan_yingyuan_video_source.dart';

/// 实时网络测试：真实请求 www.dainyew.com（鞍山影院）。
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

/// 临时验证测试：默认跳过（站点对突发请求会限流，整测可挂满 5 分钟，
/// 破坏本地回归确定性）。需要真机验源时临时把 _skipLive 改成 false。
const bool _skipLive = true;

void main() {
  test('ashanyy video source live verification', () async {
    final src = AshanYingyuanVideoSource();

    try {
      await src.categories().timeout(const Duration(seconds: 20));
    } catch (e) {
      // ignore: avoid_print
      print('dainyew.com 网络不可达，跳过测试: $e');
      return;
    }

    // 1. 分类
    final cats = await src.categories();
    // ignore: avoid_print
    print('=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats, isNotEmpty);
    expect(cats.any((c) => c.id == '45'), isTrue);

    // 2. 分类列表：条目数、封面、备注、标题实体解码
    final c45 = await net(() => src.listByCategory('45', 1));
    // ignore: avoid_print
    print('\n=== cat 45 page1 ===\ncount=${c45.length}');
    for (final it in c45.take(5)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | pic=${it.pic} | rmk=${it.remarks}');
    }
    expect(c45.length, greaterThanOrEqualTo(10), reason: '分类列表应有约 30 条');
    // 标题必须已完成数字实体解码（站点用 &#22899; 形式编码中文）
    expect(c45.first.name.contains('&#'), isFalse,
        reason: '标题不应残留 HTML 数字实体，实际：${c45.first.name}');
    // 封面来自卡片 data-original（单条大正则无法跨 pic-tag 捕获，历史缺陷）
    expect(c45.first.pic, isNotEmpty, reason: '列表封面不应为空');
    expect(c45.first.pic, contains('upload/vod'));
    // 备注来自 pic-text（「更新至02集」）
    expect(c45.first.remarks, isNotNull, reason: '列表备注不应为空');

    // 3. 分页：两页首条不同
    final c45p2 = await net(() => src.listByCategory('45', 2));
    // ignore: avoid_print
    print('\n=== cat 45 page2 ===\ncount=${c45p2.length}');
    expect(c45p2, isNotEmpty, reason: '第 2 页不应为空（分页需生效）');
    expect(c45p2.first.id, isNot(c45.first.id),
        reason: '第 1/2 页首条不应相同（分页需生效）');

    // 4. 搜索：站点端点已失效，返回空（不再返回无关结果）
    final s = await src.search('火影', 1);
    // ignore: avoid_print
    print('\n=== search ===\ncount=${s.length}');
    expect(s, isEmpty, reason: '搜索端点已失效，应返回空列表');

    // 5. 详情（/mtv/ 命名空间，含两个频道共 22 集）
    final detail = await net(() => src.detail('/mtv/1228564.html'));
    // ignore: avoid_print
    print('\n=== detail ===\n'
        'id=${detail.video.id} name=${detail.video.name}\n'
        'area=${detail.area} year=${detail.year} type=${detail.type}\n'
        'cover=${detail.cover}\neps=${detail.episodes.length}\n'
        'descLen=${detail.description?.length ?? 0}');
    for (final e in detail.episodes.take(6)) {
      // ignore: avoid_print
      print('  s${e.season}ep${e.episode}: ${e.title}');
    }
    // h1 尾部有评分 span，标题必须只取第一个 span
    expect(detail.video.name.contains('5.0'), isFalse,
        reason: '标题不应混入评分数字，实际：${detail.video.name}');
    expect(detail.video.name, contains('文豪野犬'));
    expect(detail.cover, contains('upload/vod'),
        reason: '详情页封面应取 v-thumb 的真实图，实际：${detail.cover}');
    expect(detail.episodes.length, greaterThanOrEqualTo(20),
        reason: '应解析出 2 个频道共 22 集');
    expect(detail.episodes.first.season, isNot(2),
        reason: '「立即播放」按钮不应计入剧集');
    expect(detail.description, isNot(isEmpty));
    expect(detail.description, isNot(contains('...详情')),
        reason: '简介应取 #desc 完整文本而非截断串');
    expect(detail.area, isNotNull);
    expect(detail.type, isNotNull);

    // 6. 播放：m3u8 直链（player_aaaa 的 "url"，\/ 需还原）
    final play = await net(() => src.playUrl('/mtv/1228564.html', 1, 1));
    // ignore: avoid_print
    print('\n=== playUrl ===\n$play');
    expect(play, contains('m3u8'));
    expect(play.contains('\\/'), isFalse, reason: 'URL 中的反斜杠转义应已还原');
    expect(play.startsWith('https://'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
