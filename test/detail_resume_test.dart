import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/ui/detail_page.dart';

/// 回归：第8轮 P1-4 详情页「开始阅读」改为续读上次章节（commit 8eb54e3）。
///
/// 覆盖 [DetailPage.resolveResumeChapter] 纯函数：
/// - 有该作品历史 → 返回历史章节（从章节列表里匹配）；
/// - 历史章节已从源移除 → 用历史条目构造兜底章节；
/// - 无该作品历史 → null（= 回退第 1 话）；
/// - 历史按时间倒序，多部作品/多章节时取最近读到的；
/// - 其他作品的历史不影响。
void main() {
  final chapters = [
    Chapter('ch1', '第1话'),
    Chapter('ch2', '第2话'),
    Chapter('ch3', '第3话'),
  ];

  HistoryEntry hist({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String chapterTitle,
    required int ts,
  }) =>
      HistoryEntry(
        book: Bookmark(
            sourceId: sourceId, comicId: comicId, name: '书', pic: ''),
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        timestamp: ts,
      );

  test('有历史：返回章节列表里的目标章节', () {
    final r = DetailPage.resolveResumeChapter(
      history: [
        hist(
            sourceId: 'src',
            comicId: 'comic1',
            chapterId: 'ch2',
            chapterTitle: '第2话',
            ts: 200),
      ],
      chapters: chapters,
      sourceId: 'src',
      comicId: 'comic1',
    );
    expect(r, isNotNull);
    expect(r!.id, 'ch2');
    expect(r.title, '第2话');
  });

  test('历史章节已从源移除：用历史条目构造兜底', () {
    final r = DetailPage.resolveResumeChapter(
      history: [
        hist(
            sourceId: 'src',
            comicId: 'comic1',
            chapterId: 'ch99',
            chapterTitle: '第99话',
            ts: 100),
      ],
      chapters: chapters,
      sourceId: 'src',
      comicId: 'comic1',
    );
    expect(r, isNotNull);
    expect(r!.id, 'ch99');
    expect(r.title, '第99话');
  });

  test('无该作品历史：返回 null（回退第 1 话）', () {
    final r = DetailPage.resolveResumeChapter(
      history: [
        hist(
            sourceId: 'other',
            comicId: 'other',
            chapterId: 'ch1',
            chapterTitle: '第1话',
            ts: 999),
      ],
      chapters: chapters,
      sourceId: 'src',
      comicId: 'comic1',
    );
    expect(r, isNull);
  });

  test('多部作品历史：取本作品最近一次（按时间倒序）', () {
    final r = DetailPage.resolveResumeChapter(
      history: [
        // 其他作品更新
        hist(
            sourceId: 'src',
            comicId: 'other',
            chapterId: 'chX',
            chapterTitle: 'X',
            ts: 300),
        // 本作品较旧
        hist(
            sourceId: 'src',
            comicId: 'comic1',
            chapterId: 'ch1',
            chapterTitle: '第1话',
            ts: 100),
        // 本作品最新
        hist(
            sourceId: 'src',
            comicId: 'comic1',
            chapterId: 'ch3',
            chapterTitle: '第3话',
            ts: 200),
      ],
      chapters: chapters,
      sourceId: 'src',
      comicId: 'comic1',
    );
    expect(r, isNotNull);
    expect(r!.id, 'ch3');
  });

  test('同作品多条历史（同章节重复记录）：取倒序第一条命中', () {
    final r = DetailPage.resolveResumeChapter(
      history: [
        hist(
            sourceId: 'src',
            comicId: 'comic1',
            chapterId: 'ch2',
            chapterTitle: '第2话',
            ts: 100),
        hist(
            sourceId: 'src',
            comicId: 'comic1',
            chapterId: 'ch1',
            chapterTitle: '第1话',
            ts: 200),
      ],
      chapters: chapters,
      sourceId: 'src',
      comicId: 'comic1',
    );
    // history() 已按时间倒序；倒序遍历取到 ch1（最新读到的）。
    expect(r, isNotNull);
    expect(r!.id, 'ch1');
  });
}
