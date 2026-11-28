import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/local_store.dart';

/// 阶段三 P2-17 / P2-21 验收。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xm_p2').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') return tempDir;
        return null;
      },
    );
    LocalStore.resetForTest();
  });
  tearDown(() {
    LocalStore.resetForTest();
    if (tempDir != null) {
      try {
        Directory(tempDir!).deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('P2-17 下载淘汰必须同时删文件', () {
    Bookmark bookOf(int i) => Bookmark(
          sourceId: 'dm5',
          comicId: 'c$i',
          name: '作品$i',
          pic: '',
          author: '',
        );

    DownloadRecord recOf(int i) => DownloadRecord(
          book: bookOf(i),
          chapterId: 'ch$i',
          chapterTitle: '第$i话',
          total: 1,
          done: 1,
          finished: true,
          localKey: 'dm5/c$i/ch$i',
        );

    test('插入第 201 条完成后，最旧记录与其章节目录一起消失', () async {
      // 为每条记录建一个真实的章节目录 + 图片文件，模拟下载完成后的磁盘状态。
      for (var i = 0; i < 201; i++) {
        final r = recOf(i);
        final dir = Directory(
            '$tempDir${Platform.pathSeparator}data${Platform.pathSeparator}'
            'downloads${Platform.pathSeparator}${r.localKey.replaceAll('/', Platform.pathSeparator)}');
        dir.createSync(recursive: true);
        File('${dir.path}${Platform.pathSeparator}0.img')
            .writeAsBytesSync([1, 2, 3]);
        await LocalStore.upsertDownload(r);
      }

      final records = await LocalStore.downloads();
      expect(records.length, lessThanOrEqualTo(200));
      expect(records.any((r) => r.localKey == recOf(0).localKey), isFalse,
          reason: '最旧的已完成记录应被淘汰');

      final evictedDir = Directory(
          '$tempDir${Platform.pathSeparator}data${Platform.pathSeparator}'
          'downloads${Platform.pathSeparator}dm5${Platform.pathSeparator}'
          'c0${Platform.pathSeparator}ch0');
      expect(evictedDir.existsSync(), isFalse,
          reason: 'P2-17：记录淘汰后章节目录必须同时删除，否则成为 UI 不可见孤儿文件');

      // 最新一条应仍在，且文件也在（不能误删）。
      expect(records.any((r) => r.localKey == recOf(200).localKey), isTrue);
      final keptDir = Directory(
          '$tempDir${Platform.pathSeparator}data${Platform.pathSeparator}'
          'downloads${Platform.pathSeparator}dm5${Platform.pathSeparator}'
          'c200${Platform.pathSeparator}ch200');
      expect(keptDir.existsSync(), isTrue);
    });
  });

  group('P2-21 FileProvider 只开放下载目录', () {
    String readPaths() {
      try {
        return File('android/app/src/main/res/xml/file_paths.xml')
            .readAsStringSync();
      } catch (_) {
        return '';
      }
    }

    test('不再暴露 files/cache/external-files 根目录', () {
      // 去掉 XML 注释：注释里会解释「不要再回到 path="."」，不能误判成配置。
      final xml = readPaths().replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
      expect(xml.isNotEmpty, isTrue, reason: '找不到 file_paths.xml');
      expect(xml.contains('path="."'), isFalse,
          reason: 'path="." 会把整个应用私有目录授权出去');
      expect(xml.contains('<cache-path'), isFalse);
      expect(xml.contains('<external-files-path'), isFalse);
    });

    test('开放路径与 LocalStore.downloadDir 实际位置一致', () {
      final xml = readPaths();
      // downloadDir = <appSupport>/data/downloads，files-path 根是 <appSupport>。
      expect(xml.contains('path="data/downloads/"'), isTrue,
          reason: '若写成 downloads/，FileProvider 会映射到 <appSupport>/downloads，'
              '而真实文件在 <appSupport>/data/downloads，安装时会拿不到 URI');
    });
  });

  group('P2-02 搜索页小按钮命中区', () {
    String read(String p) {
      try {
        return File(p).readAsStringSync();
      } catch (_) {
        return '';
      }
    }

    test('筛选胶囊 / 清空 / 历史标签都使用 44dp TapTargetMin', () {
      final widgets = read('lib/ui/unified_search_widgets.dart');
      final page = read('lib/ui/unified_search_page.dart');
      expect(widgets.isNotEmpty && page.isNotEmpty, isTrue);

      // _FilterChipBtn：InkWell 内必须套 TapTargetMin(height: 44)。
      final chipStart = widgets.indexOf('class _FilterChipBtn');
      expect(chipStart, greaterThan(0));
      final chip = widgets.substring(chipStart);
      expect(chip.contains('TapTargetMin('), isTrue);
      expect(chip.contains('height: 44'), isTrue,
          reason: '筛选胶囊原来只有 vertical:4 的 padding，短边远低于 44dp');

      // 清空按钮与历史 ActionChip 同理。
      final clearIdx = page.indexOf("'清空',");
      expect(clearIdx, greaterThan(0));
      final clearCtx = page.substring(clearIdx - 500, clearIdx);
      expect(clearCtx.contains('TapTargetMin('), isTrue,
          reason: '清空按钮必须用 TapTargetMin 扩大命中区');
      final chipIdx = page.indexOf('ActionChip(');
      expect(chipIdx, greaterThan(0));
      final historyCtx = page.substring(chipIdx - 400, chipIdx);
      expect(historyCtx.contains('TapTargetMin('), isTrue,
          reason: '历史标签的点击/长按命中区也必须扩大');
    });
  });
}
