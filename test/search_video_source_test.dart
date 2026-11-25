import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_result.dart';
import 'package:xingmanxia/sources/video_source.dart';
import 'package:xingmanxia/ui/search_providers.dart';

/// P1-12 统一搜索接入动漫源的最小回归（不联网）。
///
/// 旧实现 sweep 只扫漫画+小说，「全局搜索」名不副实；现在视频源也进同一条流式
/// 管线，并用 [SourceResult.videoSource] 区分「点下去该进哪个详情页」。
class FakeVideoSource extends VideoSource {
  final String id0;
  final bool fail;
  List<ComicItem> Function(String kw, int page)? onSearch;
  FakeVideoSource(this.id0, {this.fail = false, this.onSearch});

  @override
  String get id => id0;
  @override
  String get name => 'fake-$id0';
  @override
  SourceTier get tier => SourceTier.primary;

  @override
  Future<List<Category>> categories() async => const [];
  @override
  Future<List<ComicItem>> listByCategory(String c, int page) async => const [];
  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    if (fail) throw const SourceParse('选择器未命中');
    if (onSearch != null) return onSearch!(keyword, page);
    return [ComicItem('$keyword-1', '番剧1', '')];
  }
  @override
  Future<VideoDetail> detail(String videoId) async =>
      VideoDetail(ComicItem(videoId, 'fake', ''), const []);
  @override
  Future<String> playUrl(String v, int s, int e) async => '';
}

void main() {
  group('SourceResult 的媒体类型区分（P1-12）', () {
    test('视频源 → isVideo 且 id/name 取视频源', () {
      final v = FakeVideoSource('vidok');
      final r = SourceResult(videoSource: v, items: const [], page: 1);
      expect(r.isVideo, isTrue);
      expect(r.isNovel, isFalse);
      expect(r.sourceId, 'vidok');
      expect(r.sourceName, 'fake-vidok');
    });

    test('漫画源 → 既不是 novel 也不是 video', () {
      final c = _NoopComic();
      final r = SourceResult(source: c, items: const [], page: 1);
      expect(r.isVideo, isFalse);
      expect(r.isNovel, isFalse);
      expect(r.sourceId, c.id);
    });

    test('三种来源必须至少带一个（assert）', () {
      expect(
        () => SourceResult(items: const [], page: 1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('searchVideoSource / safeSearchVideo', () {
    test('成功 → ok=true、条目透传', () async {
      final src = FakeVideoSource('vidok');
      final r = await searchVideoSource(src, '咒术', 1);
      expect(r.ok, isTrue);
      expect(r.items, hasLength(1));
      final (items, failed) = await safeSearchVideo(src, '咒术', 1);
      expect(failed, isFalse);
      expect(items, hasLength(1));
    });

    test('失败 → 带分类明细且不抛', () async {
      final src = FakeVideoSource('vidfail', fail: true);
      final r = await searchVideoSource(src, '咒术', 1);
      expect(r.ok, isFalse);
      expect(r.failure, isNotNull);
      expect(r.failure!.kind, SearchFailKind.parse,
          reason: '视频源解析失败要归到 parse，UI 才能提示「源站可能改版」');
      final (items, failed) = await safeSearchVideo(src, '咒术', 1);
      expect(failed, isTrue);
      expect(items, isEmpty);
    });

    test('失败明细带源 id/name（UI 展示「哪个源、为什么」）', () async {
      final src = FakeVideoSource('vidfail', fail: true);
      final r = await searchVideoSource(src, 'x', 1);
      expect(r.failure!.sourceId, 'vidfail');
      expect(r.failure!.label, contains('fake-vidfail'));
    });
  });
}

/// 仅用于「漫画结果」分支的最小实现（不联网）。
class _NoopComic extends ComicSource {
  @override
  String get id => 'comicx';
  @override
  String get name => 'fake-comic';
  @override
  SourceTier get tier => SourceTier.primary;
  @override
  Future<List<Category>> categories() async => const [];
  @override
  Future<List<ComicItem>> listByCategory(String c, int p) async => const [];
  @override
  Future<List<ComicItem>> rank(int p) async => const [];
  @override
  Future<List<ComicItem>> search(String k, int p) async => const [];
  @override
  Future<ComicDetail> detail(String id) async =>
      ComicDetail(ComicItem(id, 'fake', ''), const []);
  @override
  Future<List<String>> chapterPics(String c) async => const [];
}
