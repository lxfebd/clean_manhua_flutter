import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/xbiquge_novel_source.dart';

/// 临时验证测试：真实请求 xbiquge.bz，验证新源解析逻辑。
///
/// 注意：xbiquge.bz 是中文小说站，GitHub Actions（美国机房）可能无法访问。
/// 网络不可达时自动跳过，不阻断 CI。
/// 默认跳过：真实网络源验证，源站波动时拖垮本地回归。
/// 需要验源时临时把 _skipLive 改成 false。
const bool _skipLive = true;
void main() {
  test('xbiquge novel source live verification', () async {
    final src = XbiqugeNovelSource();

    // 先探测网络连通性（categories 是本地硬编码不发请求，用 rank 探测真实网络）
    try {
      await src.rank(1).timeout(const Duration(seconds: 15));
    } catch (e) {
      // ignore: avoid_print
      print('xbiquge.bz 网络不可达，跳过测试: $e');
      return;
    }

    final cats = await src.categories();
    // ignore: avoid_print
    print('=== categories ===\n${cats.map((c) => '${c.id}:${c.name}').join(' | ')}');
    expect(cats, isNotEmpty);

    final rank = await src.rank(1);
    // ignore: avoid_print
    print('\n=== rank (homepage) ===\ncount=${rank.length}');
    for (final it in rank.take(5)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | ${it.pic}');
    }
    expect(rank, isNotEmpty);

    final list = await src.listByCategory('1', 1);
    // ignore: avoid_print
    print('\n=== listByCategory 1/1 ===\ncount=${list.length}');
    for (final it in list.take(5)) {
      // ignore: avoid_print
      print('  ${it.id} | ${it.name} | ${it.pic}');
    }
    expect(list, isNotEmpty);

    final detail = await src.detail(list.first.id);
    // ignore: avoid_print
    print('\n=== detail ===\nid=${detail.id} name=${detail.name} '
        'pic=${detail.pic} author=${detail.author} chapters=${detail.chapters.length}');
    for (final c in detail.chapters.take(5)) {
      // ignore: avoid_print
      print('  ${c.index}: ${c.id} | ${c.title}');
    }
    expect(detail.chapters, isNotEmpty);

    final ch = detail.chapters.first;
    final content = await src.chapterContent(ch.id);
    // ignore: avoid_print
    print('\n=== chapterContent ===\ntitle=${content.title} '
        'paras=${content.paragraphs.length} prev=${content.prevChapterId} '
        'next=${content.nextChapterId}');
    for (final p in content.paragraphs.take(6)) {
      // ignore: avoid_print
      print('  | $p');
    }
    expect(content.paragraphs, isNotEmpty);
    expect(content.title, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)), skip: _skipLive ? '真实网络验证，默认跳过' : false);
}
