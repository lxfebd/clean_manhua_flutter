import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/novel_source.dart';
import 'package:xingmanxia/ui/detail_providers.dart';

/// 回归：迭代轮7 小说详情页「继续阅读」续读入口（对齐漫画详情页）。
///
/// 覆盖 [resolveNovelResumeChapter]（detail_providers 层，R3 删页面转发壳） 纯函数：
/// - 有该小说历史 → 返回历史章节（从章节列表里匹配）+ 滚动偏移；
/// - 历史章节已从源移除 → 用历史条目构造兜底章节；
/// - 无该小说历史 → null（「继续阅读」按钮不显示）；
/// - 历史按时间倒序，多部作品/多章节时取最近读到的；
/// - 其他作品的历史不影响。
void main() {
  final chapters = [
    NovelChapter('ch1', '第一章'),
    NovelChapter('ch2', '第二章'),
    NovelChapter('ch3', '第三章'),
  ];

  HistoryEntry hist({
    required String sourceId,
    required String novelId,
    required String chapterId,
    required String chapterTitle,
    required int ts,
    double offset = 0,
  }) =>
      HistoryEntry(
        book: Bookmark(
            sourceId: sourceId, comicId: novelId, name: '书', pic: ''),
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        timestamp: ts,
        scrollOffset: offset,
      );

  test('有历史：返回章节列表里的目标章节 + 偏移', () {
    final r = resolveNovelResumeChapter(
      history: [
        hist(
            sourceId: 'src',
            novelId: 'novel1',
            chapterId: 'ch2',
            chapterTitle: '第二章',
            ts: 200,
            offset: 0.618),
      ],
      chapters: chapters,
      sourceId: 'src',
      novelId: 'novel1',
    );
    expect(r, isNotNull);
    expect(r!.chapter.id, 'ch2');
    expect(r.chapter.title, '第二章');
    expect(r.offset, 0.618);
  });

  test('历史章节已从源移除：用历史条目构造兜底', () {
    final r = resolveNovelResumeChapter(
      history: [
        hist(
            sourceId: 'src',
            novelId: 'novel1',
            chapterId: 'ch99',
            chapterTitle: '第九十九章',
            ts: 100),
      ],
      chapters: chapters,
      sourceId: 'src',
      novelId: 'novel1',
    );
    expect(r, isNotNull);
    expect(r!.chapter.id, 'ch99');
    expect(r.chapter.title, '第九十九章');
  });

  test('无该小说历史：返回 null（不显示按钮）', () {
    final r = resolveNovelResumeChapter(
      history: [
        hist(
            sourceId: 'other',
            novelId: 'other',
            chapterId: 'ch1',
            chapterTitle: '第一章',
            ts: 999),
      ],
      chapters: chapters,
      sourceId: 'src',
      novelId: 'novel1',
    );
    expect(r, isNull);
  });

  test('多部作品历史：取本作品最近一次（按时间倒序）', () {
    final r = resolveNovelResumeChapter(
      history: [
        // 其他作品更新
        hist(
            sourceId: 'src',
            novelId: 'other',
            chapterId: 'chX',
            chapterTitle: 'X',
            ts: 300),
        // 本作品较旧
        hist(
            sourceId: 'src',
            novelId: 'novel1',
            chapterId: 'ch1',
            chapterTitle: '第一章',
            ts: 100),
        // 本作品最新
        hist(
            sourceId: 'src',
            novelId: 'novel1',
            chapterId: 'ch3',
            chapterTitle: '第三章',
            ts: 200,
            offset: 0.5),
      ],
      chapters: chapters,
      sourceId: 'src',
      novelId: 'novel1',
    );
    expect(r, isNotNull);
    expect(r!.chapter.id, 'ch3');
    expect(r.offset, 0.5);
  });

  test('同作品多条历史（同章节重复记录）：取倒序第一条命中', () {
    final r = resolveNovelResumeChapter(
      history: [
        hist(
            sourceId: 'src',
            novelId: 'novel1',
            chapterId: 'ch2',
            chapterTitle: '第二章',
            ts: 100,
            offset: 0.2),
        hist(
            sourceId: 'src',
            novelId: 'novel1',
            chapterId: 'ch1',
            chapterTitle: '第一章',
            ts: 200,
            offset: 0.8),
      ],
      chapters: chapters,
      sourceId: 'src',
      novelId: 'novel1',
    );
    // history() 已按时间倒序；倒序遍历取到 ch1（最新读到的）。
    expect(r, isNotNull);
    expect(r!.chapter.id, 'ch1');
    expect(r.offset, 0.8);
  });
}
