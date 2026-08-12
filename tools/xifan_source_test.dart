// 端到端验证：直接调用真实 XifanVideoSource 代码（走 Net 真实网络）。
// 运行：flutter test test/xifan_source_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/xifan_video_source.dart' as xifan;
import 'package:xingmanxia/net/http_client.dart';

void main() {
  // 让每个用例真实联网，并打印关键结果供人工核对。
  test('Xifan 源端到端', () async {
    final src = xifan.XifanVideoSource();

    // 1) 分类
    final cats = await src.categories();
    print('[分类] ${cats.map((c) => "${c.id}:${c.name}").join(" / ")}');
    expect(cats.length, greaterThanOrEqualTo(4));

    // 2) 全部列表
    final all = await src.listByCategory('all', 1);
    print('[列表 all] 共 ${all.length} 条；首条='
        '${all.isNotEmpty ? "${all.first.id} / ${all.first.name} / ${all.first.pic}" : "空"}');
    expect(all, isNotEmpty);
    expect(all.first.id, isNotEmpty);
    expect(all.first.name, isNotEmpty);

    // 3) 番剧(TV) 过滤分类
    final tv = await src.listByCategory('tv', 1);
    print('[列表 tv] 共 ${tv.length} 条；首条='
        '${tv.isNotEmpty ? "${tv.first.id} / ${tv.first.name}" : "空"}');
    expect(tv, isNotEmpty);

    // 4) 搜索
    final hit = await src.search('魔法', 1);
    print('[搜索 魔法] 共 ${hit.length} 条；首条='
        '${hit.isNotEmpty ? "${hit.first.id} / ${hit.first.name}" : "空"}');
    expect(hit, isNotEmpty);

    // 5) 详情 + 剧集（用列表里第一个真实 id）
    final vid = all.first.id;
    await Future.delayed(const Duration(milliseconds: 600));
    final d = await src.detail(vid);
    print('[详情 $vid] 标题=${d.video.name} 封面=${d.cover != null ? "有" : "无"} '
        '地区=${d.area ?? "-"} 年份=${d.year ?? "-"} 类型=${d.type ?? "-"} '
        '剧集数=${d.episodes.length}');
    print('[剧集样本] ${d.episodes.take(4).map((e) => "s${e.season}e${e.episode}:${e.title}").join(" | ")}');
    expect(d.video.name, isNotEmpty);
    expect(d.episodes, isNotEmpty);

    // 6) 取第一集播放直链
    final ep = d.episodes.first;
    final url = await src.playUrl(vid, ep.season, ep.episode);
    print('[播放直链] season=${ep.season} ep=${ep.episode} -> $url');
    expect(url, anyOf(contains('.mp4'), contains('.m3u8')));

    // 7) 顺着直链真正取一段视频流（验证 CDN 可服务、非防盗链拦截）
    final reqHeaders = <String, String>{'Range': 'bytes=0-2047'};
    List<int> chunk;
    try {
      chunk = await Net.getBytes(url, headers: reqHeaders);
    } catch (e) {
      chunk = const <int>[];
      print('[取流] 异常：$e');
    }
    final isVideo = chunk.isNotEmpty;
    final mp4Magic = chunk.length >= 12 &&
        String.fromCharCodes(chunk.sublist(4, 8)) == 'ftyp';
    print('[取流] 字节数=${chunk.length} 疑似mp4(moov/ftyp)='
        '${mp4Magic ? "是" : "未知/非mp4"}');
    expect(isVideo, isTrue,
        reason: '播放直链应能取到视频流字节');

    // 8) 缓存命中（第二次同参数应立即返回同一 URL，不再抓播放页）
    final url2 = await src.playUrl(vid, ep.season, ep.episode);
    expect(url2, equals(url));
    print('[缓存] 二次调用返回相同直链：OK');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
