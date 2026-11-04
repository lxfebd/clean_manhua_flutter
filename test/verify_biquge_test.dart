import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/biquge_novel_source.dart';

/// 笔趣阁（biquge365.net）实网验证。
///
/// 2026-11-04 换站重写：旧站 tobiquge.com 已被江苏反诈页接管（302 →
/// js96110.com.cn）、xbiquge.com 超时，且无同模板镜像存活；本源改到
/// `biquge365.net`（经典笔趣阁模板）。本测试锁定新站契约：
/// 分类 → 列表 → 详情（章节）→ 正文（清洗广告/分页标记）→ 上下章。
///
/// 默认跳过；需要验源时把 _skipLive 改成 false。
const bool _skipLive = true;

Future<T> net<T>(Future<T> Function() fn, {int times = 3}) async {
  Object? last;
  for (var i = 0; i < times; i++) {
    await Future.delayed(const Duration(seconds: 2));
    try {
      return await fn();
    } catch (e) {
      last = e;
    }
  }
  throw last!;
}

void main() {
  test('biquge novel source live verification (biquge365.net)', () async {
    final src = BiqugeNovelSource();

    // 1. 分类（8 个，来自首页 /sort/{id}_1/）
    final cats = await net(() => src.categories());
    // ignore: avoid_print
    print('=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats.length, 8);
    expect(cats.any((c) => c.name == '玄幻魔法'), isTrue);

    // 2. 列表（分类第 1 页）
    final list = await net(() => src.listByCategory('1', 1));
    // ignore: avoid_print
    print('\n=== list cat=1 page=1 ===\ncount=${list.length}');
    for (final it in list.take(5)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | pic=${it.pic.isEmpty ? "(无)" : "有"}');
    }
    expect(list, isNotEmpty, reason: '分类列表应有书籍');
    expect(list.first.id, matches(RegExp(r'^\d+$')));
    expect(list.first.name, isNotEmpty);

    // 3. 分页（第 2 页与第 1 页不同）
    final list2 = await net(() => src.listByCategory('1', 2));
    // ignore: avoid_print
    print('\n=== list cat=1 page=2 ===\ncount=${list2.length}');
    expect(list2, isNotEmpty, reason: '第 2 页不应为空（分页需生效）');
    expect(list2.first.id, isNot(list.first.id));

    // 4. 详情（章节目录）
    final detail = await net(() => src.detail(list.first.id));
    // ignore: avoid_print
    print('\n=== detail ===\nid=${detail.comic.id} name=${detail.comic.name} '
        'author=${detail.comic.author} '
        'cover=${detail.comic.pic.isEmpty ? "(无)" : "有"} '
        'chapters=${detail.chapters.length}');
    for (final c in detail.chapters.take(3)) {
      // ignore: avoid_print
      print('  ${c.id} | ${c.title}');
    }
    expect(detail.chapters, isNotEmpty, reason: '详情应解析出章节目录');
    expect(detail.comic.name, isNotEmpty);
    // 目录里不应混入功能按钮
    expect(detail.chapters.any((c) => c.title == '开始阅读'), isFalse,
        reason: '「开始阅读」是按钮不是章节，应被过滤');

    // 5. 正文（清洗广告 / 分页标记 / 翻页提示）
    //    站点有的首章是极短的公告/感言（几十字也正常），故断言改为
    //    「前 3 章里至少一章有实质正文」，不对单章设死板下限。
    var maxLen = 0;
    var probe = await net(() => src.chapterContent(detail.chapters.first.id));
    var best = probe;
    for (final c in detail.chapters.take(3)) {
      final cc = await net(() => src.chapterContent(c.id));
      final len = cc.paragraphs.join('\n').length;
      // ignore: avoid_print
      print('  chapter ${c.title}: paras=${cc.paragraphs.length} len=$len');
      if (len > maxLen) {
        maxLen = len;
        best = cc;
      }
      probe = cc;
    }
    // ignore: avoid_print
    print('\n=== chapterContent ===\nbest title=${best.title} '
        'paras=${best.paragraphs.length} maxLen=$maxLen '
        'prev=${best.prevChapterId} next=${best.nextChapterId}');
    for (final p in best.paragraphs.take(3)) {
      // ignore: avoid_print
      print('  | ${p.length > 60 ? p.substring(0, 60) : p}');
    }
    expect(maxLen, greaterThan(200),
        reason: '前 3 章里至少一章应有实质正文（>200 字）；'
            '若全是短公告，说明正文解析或该站书库有问题');
    expect(best.paragraphs, isNotEmpty, reason: '正文应有段落');

    final joined = best.paragraphs.join('\n');
    expect(joined.contains('一秒记住'), isFalse,
        reason: '站方广告行必须被清洗');
    expect(joined.contains('第1/2页') || joined.contains('第2/2页'), isFalse,
        reason: '分页标记必须被清洗');
    expect(joined.contains('本章未完'), isFalse,
        reason: '翻页提示必须被清洗');
    expect(joined.contains('&nbsp;'), isFalse, reason: 'HTML 实体应已解码');

    // 6. 搜索：站点自身 SQL 报错，明确返回空（UI 兜底），不应抛异常
    final sr = await src.search('海贼', 1);
    // ignore: avoid_print
    print('\n=== search ===\ncount=${sr.length}（站点搜索服务端报错，预期 0）');
    expect(sr, isEmpty);

    // probe 变量保留用于调试输出（避免未使用告警）
    expect(probe.chapterId, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)),
      skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
