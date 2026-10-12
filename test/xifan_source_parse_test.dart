import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/xifan_video_source.dart';

/// 离线样本测试：用真实抓取的详情页 HTML 快照验证新站解析逻辑
/// （JSON-LD 元信息 / 剧集 epid / 线路名），不依赖网络。
///
/// 样本来源：2026-10-12 抓取 https://next.xifanacg.com/anime/588
/// （【我推的孩子】：日本/2023/TV动画 悬疑 漫画改 青年向 职场/7.4/11集）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final src = XifanVideoSource();

  test('detail 解析详情页 HTML：JSON-LD 元信息 + 剧集 epid', () async {
    final html = File('test/assets/xifan_detail_588.html').readAsStringSync();
    final detail = await src.detailForTest(html, '588');

    // JSON-LD 元信息
    expect(detail.video.name, contains('我推的孩子'),
        reason: 'JSON-LD name 应解析为标题，实际：${detail.video.name}');
    expect(detail.area, '日本', reason: 'countryOfOrigin 应为日本');
    expect(detail.year, '2023', reason: 'datePublished 年份应为 2023');
    expect(detail.video.score, '7.4', reason: 'aggregateRating 应为 7.4');
    expect(detail.tags, contains('悬疑'),
        reason: 'genre 里应保留题材标签，实际：${detail.tags.join('/')}');
    expect(detail.tags, isNot(contains('TV')),
        reason: 'genre 里的形式词 TV 不应混入题材标签');
    expect(detail.type, 'TV动画', reason: 'genre 里 TV 应映射为动画形式');
    expect(detail.sourceNames, isNotNull);
    expect(detail.sourceNames![1], contains('主线'),
        reason: '默认线路名应解析，实际：${detail.sourceNames}');

    // 剧集列表：11 集 + epid 递增
    expect(detail.episodes.length, 11,
        reason: '应解析出 11 集，实际：${detail.episodes.length}');
    expect(detail.episodes.first.episode, 1);
    expect(detail.episodes.first.epid, isNotNull,
        reason: '第 1 集应带 epid');
    expect(detail.episodes.last.episode, 11);
    expect(detail.episodes.last.epid, isNotNull);
    final epids = detail.episodes.map((e) => e.epid).toList();
    expect(epids.toSet().length, epids.length,
        reason: 'epid 不应重复（按钮与列表项同 epid 时只应保留一次）');
    // 第 1 集标题含子标题「母亲和孩子」
    expect(detail.episodes.first.title, contains('母亲和孩子'),
        reason: '剧集标题应含子标题，实际：${detail.episodes.first.title}');
  });

  test('playUrl 从缓存拼出播放页 URL', () async {
    final html = File('test/assets/xifan_detail_588.html').readAsStringSync();
    await src.detailForTest(html, '588');

    final url = await src.playUrl('588', 1, 2);
    expect(url, startsWith('https://next.xifanacg.com/anime/588/play/'),
        reason: '应返回新站播放页 URL，实际：$url');
    expect(url, contains('source='), reason: '播放 URL 应带线路参数');
  });

  test('搜索列表 JSON 映射：评分/集数 remarks', () {
    final items = src.itemsForTest([
      {
        'id': 588,
        'title': '【我推的孩子】',
        'cover_url': 'https://img2.xfmanga.top/x.jpg',
        'bangumi_score': 7.4,
        'view_count': 123456,
        'rank': 3,
        'is_finished': true,
        'total_episodes': 11,
        'current_episodes': 11,
      },
      {
        'id': 3240,
        'title': '【我推的孩子】 第三季',
        'cover_url': 'https://img2.xfmanga.top/y.jpg',
        'bangumi_score': 0,
        'view_count': 0,
        'is_finished': false,
        'total_episodes': 0,
        'current_episodes': 5,
      },
    ]);

    expect(items.length, 2);
    expect(items[0].id, '588');
    expect(items[0].name, '【我推的孩子】');
    expect(items[0].score, '7.4');
    expect(items[0].hits, '123456');
    expect(items[0].remarks, '全11集', reason: '完结应显示全N集');
    expect(items[1].remarks, '更新至5集', reason: '连载应显示更新至N集');
    expect(items[1].score, isNull, reason: '评分 0 不显示');
    expect(items[1].hits, isNull, reason: '播放 0 不显示');
  });

  test('列表标题原样保留（年份括号是重制版消歧标识）', () {
    // 站点上「福星小子(1981)」与「福星小子」(id=898, 2022) 是两部不同作品，
    // 清洗列表标题会让它们在列表里无法分辨。
    final items = src.itemsForTest([
      {'id': 3161, 'title': '福星小子(1981)', 'cover_url': 'a'},
      {'id': 898, 'title': '福星小子', 'cover_url': 'b'},
      {'id': 3162, 'title': '福星小子 OVA', 'cover_url': 'c'},
      {'id': 1, 'title': '少女与战车 剧场版', 'cover_url': 'd'},
    ]);
    expect(items.map((e) => e.name),
        ['福星小子(1981)', '福星小子', '福星小子 OVA', '少女与战车 剧场版']);
  });

  test('详情标题清洗：只作用于 <title> 兜底，去站点后缀与重复年份', () {
    // 实测新站 <title> 统一为「{标题} ({年份}) · 稀饭动漫 Next」。
    expect(XifanVideoSource.cleanTitleForTest('【我推的孩子】 (2023) · 稀饭动漫 Next'),
        '【我推的孩子】');
    expect(XifanVideoSource.cleanTitleForTest('福星小子 (2022) · 稀饭动漫 Next'),
        '福星小子');
    // 标题自带年份时只去掉尾部重复的那个，保留消歧标识（与 JSON-LD name 一致）。
    expect(XifanVideoSource.cleanTitleForTest('福星小子(1981) (1981) · 稀饭动漫 Next'),
        '福星小子(1981)');
    expect(
        XifanVideoSource.cleanTitleForTest('剧场版 鬼灭之刃 无限城篇 第一章 猗窝座再来 (2025) · 稀饭动漫 Next'),
        '剧场版 鬼灭之刃 无限城篇 第一章 猗窝座再来');
  });

  test('分类筛选 body 映射', () {
    expect(src.bodyForTest('all'), isNot(contains('filter_type_id')));
    expect(src.bodyForTest('serial')['filter_type_id'], 1);
    expect(src.bodyForTest('finished')['filter_type_id'], 2);
    expect(src.bodyForTest('tv')['filter_format'], 'tv');
    expect(src.bodyForTest('movie')['filter_format'], 'movie');
  });
}