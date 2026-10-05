import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:xingmanxia/net/novel_chapter_cache.dart';
import 'package:xingmanxia/sources/novel_source.dart';

/// 用内存实现替换 path_provider：NovelChapterCache 的读写落在此目录。
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final Directory dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir.path;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('novel_cache_test_');
    PathProviderPlatform.instance =
        _FakePathProvider(tmp) as PathProviderPlatform;
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('write 后 read 回读到相同字段', () async {
    await NovelChapterCache.write(
      'src1',
      'novel1',
      'ch1',
      NovelContent(
        'ch1',
        '第一章',
        const ['第一段', '第二段'],
        prevChapterId: 'ch0',
        nextChapterId: 'ch2',
      ),
    );
    final c = await NovelChapterCache.read('src1', 'novel1', 'ch1');
    expect(c, isNotNull);
    expect(c!.chapterId, 'ch1');
    expect(c.title, '第一章');
    expect(c.paragraphs, ['第一段', '第二段']);
    expect(c.prevChapterId, 'ch0');
    expect(c.nextChapterId, 'ch2');
  });

  test('不同章节/书目互相隔离', () async {
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch1', NovelContent('ch1', '甲', const ['a']));
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch2', NovelContent('ch2', '乙', const ['b']));
    await NovelChapterCache.write(
        'src1', 'novel2', 'ch1', NovelContent('ch1', '丙', const ['c']));
    expect(
        (await NovelChapterCache.read('src1', 'novel1', 'ch1'))!.title, '甲');
    expect(
        (await NovelChapterCache.read('src1', 'novel1', 'ch2'))!.title, '乙');
    expect(
        (await NovelChapterCache.read('src1', 'novel2', 'ch1'))!.title, '丙');
  });

  test('未写缓存时 read 返回 null', () async {
    expect(await NovelChapterCache.read('src1', 'novel1', 'missing'), isNull);
  });

  test('delete 后 read 返回 null', () async {
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch1', NovelContent('ch1', '甲', const ['a']));
    await NovelChapterCache.delete('src1', 'novel1', 'ch1');
    expect(await NovelChapterCache.read('src1', 'novel1', 'ch1'), isNull);
  });

  test('重写覆盖旧内容', () async {
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch1', NovelContent('ch1', '旧', const ['old']));
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch1',
        NovelContent('ch1', '新', const ['new'], nextChapterId: 'ch2'));
    final c = await NovelChapterCache.read('src1', 'novel1', 'ch1');
    expect(c!.title, '新');
    expect(c.paragraphs, ['new']);
    expect(c.nextChapterId, 'ch2');
  });

  test('损坏缓存文件 read 返回 null 不抛', () async {
    final dir = Directory(
        '${tmp.path}/novel_cache/src1/novel1'); // 用与 _file 相同的编码路径
    await dir.create(recursive: true);
    await File('${dir.path}/ch1.json').writeAsString('not json');
    expect(await NovelChapterCache.read('src1', 'novel1', 'ch1'), isNull);
  });
}
