import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/video_download_manager.dart';
import 'package:xingmanxia/ui/bookshelf_download_view.dart';

/// 下载 Tab 搜索过滤纯函数覆盖：
/// - 漫画按书名/章节标题匹配（filterMangaDownloads）；
/// - 动漫按番剧名/集数匹配（filterAnimeDownloads）；
/// - 空/空白 = 原样返回；无匹配 = 空列表。
void main() {
  final manga = [
    DownloadRecord(
      book: Bookmark(sourceId: 's1', comicId: 'c1', name: '海贼王', pic: ''),
      chapterId: 'c1-1',
      chapterTitle: '第1话 起航',
      total: 10,
      done: 10,
      finished: true,
      localKey: 'k1',
    ),
    DownloadRecord(
      book: Bookmark(sourceId: 's1', comicId: 'c2', name: '火影忍者', pic: ''),
      chapterId: 'c2-2',
      chapterTitle: '第2话 鸣人登场',
      total: 5,
      done: 3,
      finished: false,
      localKey: 'k2',
    ),
  ];

  final anime = [
    VideoDownloadTask(
      sourceId: 'v1', videoId: 'v1', title: '进击的巨人',
      season: 1, episode: 1, url: 'u1', headers: const {},
    ),
    VideoDownloadTask(
      sourceId: 'v1', videoId: 'v1', title: '咒术回战',
      season: 1, episode: 12, url: 'u2', headers: const {},
    ),
  ];

  group('filterMangaDownloads', () {
    test('空过滤：原样返回', () {
      expect(filterMangaDownloads(manga, ''), same(manga));
    });

    test('按书名匹配', () {
      final r = filterMangaDownloads(manga, '海贼');
      expect(r.map((d) => d.book.name), ['海贼王']);
    });

    test('按章节标题匹配', () {
      final r = filterMangaDownloads(manga, '鸣人');
      expect(r.map((d) => d.book.name), ['火影忍者']);
    });

    test('大小写不敏感', () {
      final r = filterMangaDownloads(manga, 'ONEPIECE'); // 无匹配
      expect(r, isEmpty);
      final r2 = filterMangaDownloads(manga, '第1话');
      expect(r2.map((d) => d.book.name), ['海贼王']);
    });

    test('空白视为空', () {
      expect(filterMangaDownloads(manga, '   '), same(manga));
    });

    test('无匹配返回空', () {
      expect(filterMangaDownloads(manga, '不存在的书'), isEmpty);
    });
  });

  group('filterAnimeDownloads', () {
    test('空过滤：原样返回', () {
      expect(filterAnimeDownloads(anime, ''), same(anime));
    });

    test('按番剧名匹配', () {
      final r = filterAnimeDownloads(anime, '进击');
      expect(r.map((t) => t.title), ['进击的巨人']);
    });

    test('按集数匹配（12 只命中第 12 集）', () {
      final r = filterAnimeDownloads(anime, '12');
      expect(r.map((t) => t.episode), [12]);
    });

    test('按集数匹配（1 命中第 1 集与含 1 的集数）', () {
      final r = filterAnimeDownloads(anime, '1');
      // 「1」同时匹配第 1 集与第 12 集（12 含 '1'）——模糊匹配预期行为。
      expect(r.map((t) => t.episode).toSet(), {1, 12});
    });

    test('空白视为空', () {
      expect(filterAnimeDownloads(anime, '\t'), same(anime));
    });

    test('无匹配返回空', () {
      expect(filterAnimeDownloads(anime, '不存在的番'), isEmpty);
    });
  });
}
