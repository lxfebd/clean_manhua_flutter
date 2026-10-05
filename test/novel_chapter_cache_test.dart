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

  test('cachedChapterIds 返回已缓存章节 id 集合', () async {
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch1', NovelContent('ch1', '甲', const ['a']));
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch2', NovelContent('ch2', '乙', const ['b']));
    final ids = await NovelChapterCache.cachedChapterIds('src1', 'novel1');
    expect(ids, {'ch1', 'ch2'});
  });

  test('cachedChapterIds 不同小说互相隔离 + 无缓存返回空', () async {
    await NovelChapterCache.write(
        'src1', 'novel1', 'ch1', NovelContent('ch1', '甲', const ['a']));
    expect(
        await NovelChapterCache.cachedChapterIds('src1', 'novel2'), isEmpty);
    expect(await NovelChapterCache.cachedChapterIds('src1', 'novel1'),
        {'ch1'});
  });

  group('pruneDirectory 配额清理', () {
    test('总量在配额内不动任何文件', () async {
      final root = Directory('${tmp.path}/cache')..createSync(recursive: true);
      final a = File('${root.path}/a.json')..writeAsStringSync('12345');
      await a.setLastModified(DateTime(2020));
      expect(await NovelChapterCache.pruneDirectory(root, 100), 0);
      expect(await a.exists(), isTrue);
    });

    test('超配额按最旧优先删除到配额内', () async {
      final root = Directory('${tmp.path}/cache')..createSync(recursive: true);
      final old = File('${root.path}/old.json')
        ..writeAsStringSync('1' * 10);
      await old.setLastModified(DateTime(2020));
      final mid = File('${root.path}/mid.json')
        ..writeAsStringSync('2' * 10);
      await mid.setLastModified(DateTime(2021));
      final fresh = File('${root.path}/fresh.json')
        ..writeAsStringSync('3' * 10);
      await fresh.setLastModified(DateTime(2022));

      // 配额 15 < 总量 30：删最旧 10 字节后剩 20 仍超 → 再删 10 字节。
      final removed = await NovelChapterCache.pruneDirectory(root, 15);
      expect(removed, 2);
      expect(await old.exists(), isFalse);
      expect(await mid.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
    });

    test('配额小到删光也正常返回', () async {
      final root = Directory('${tmp.path}/cache')..createSync(recursive: true);
      File('${root.path}/a.json').writeAsStringSync('1' * 10);
      File('${root.path}/b.json').writeAsStringSync('2' * 10);
      final removed = await NovelChapterCache.pruneDirectory(root, 1);
      expect(removed, 2);
    });

    test('嵌套子目录的文件也被统计清理', () async {
      final root = Directory('${tmp.path}/cache')..createSync(recursive: true);
      final sub = Directory('${root.path}/src/novel')..createSync(recursive: true);
      final deep = File('${sub.path}/ch.json')..writeAsStringSync('1' * 20);
      await deep.setLastModified(DateTime(2020));
      final top = File('${root.path}/top.json')..writeAsStringSync('2' * 20);
      await top.setLastModified(DateTime(2021));
      final removed = await NovelChapterCache.pruneDirectory(root, 25);
      expect(removed, 1); // 只删最旧的 deep（20B），剩 top 20B ≤ 25
      expect(await deep.exists(), isFalse);
      expect(await top.exists(), isTrue);
    });

    test('目录不存在返回 0 不抛', () async {
      final removed = await NovelChapterCache.pruneDirectory(
          Directory('${tmp.path}/nope'), 100);
      expect(removed, 0);
    });
  });
}
