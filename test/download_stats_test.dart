import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/video_download_manager.dart';
import 'package:xingmanxia/ui/bookshelf_download_view.dart';

DownloadRecord _mkRecord({int done = 0, int total = 0, bool finished = false}) {
  return DownloadRecord(
    book: Bookmark(
      sourceId: 's',
      comicId: 'c',
      name: '测试书',
      pic: '',
    ),
    chapterId: 'ch',
    chapterTitle: '第 1 话',
    total: total,
    done: done,
    finished: finished,
    localKey: 's/c/ch',
  );
}

VideoDownloadTask _mkTask(String state, {int episode = 1}) {
  final t = VideoDownloadTask(
    sourceId: 'v',
    videoId: 'vid',
    title: '测试番',
    season: 1,
    episode: episode,
    url: 'https://example.com/e$episode.mp4',
  );
  t.state = state;
  return t;
}

void main() {
  group('totalMangaCachedPages', () {
    test('空表返回 0', () {
      expect(totalMangaCachedPages(const []), 0);
    });

    test('单条进行中任务只计已下载页数', () {
      expect(
          totalMangaCachedPages([_mkRecord(done: 12, total: 30)]), 12);
    });

    test('多条记录累加已下载页数', () {
      expect(
          totalMangaCachedPages([
            _mkRecord(done: 5, total: 10),
            _mkRecord(done: 20, total: 20, finished: true),
            _mkRecord(done: 0, total: 0),
          ]),
          25);
    });
  });

  group('totalAnimeDoneEpisodes', () {
    test('空表返回 0', () {
      expect(totalAnimeDoneEpisodes(const []), 0);
    });

    test('仅统计 state == done 的任务', () {
      expect(
          totalAnimeDoneEpisodes([
            _mkTask('done'),
            _mkTask('downloading'),
            _mkTask('failed'),
            _mkTask('canceled'),
          ]),
          1);
    });

    test('多部番剧已完成集数累加', () {
      expect(
          totalAnimeDoneEpisodes([
            _mkTask('done', episode: 3),
            _mkTask('done', episode: 1),
            _mkTask('downloading', episode: 5),
          ]),
          2);
    });
  });
}
