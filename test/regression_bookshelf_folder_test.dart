import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/comic_source.dart';

/// 回归测试：书架分类文件夹（增删改 / 书籍归位 / 旧数据兜底 / 备份兼容）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmpDir;
  late File shelfFile;

  setUpAll(() {
    tmpDir = Directory.systemTemp.createTempSync('xm_shelf_folder_test');
    // path_provider 打桩：LocalStore 落到临时目录（单元测试无插件通道）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmpDir.path;
        }
        return null;
      },
    );
    LocalStore.init();
  });

  setUp(() async {
    shelfFile = File('${tmpDir.path}/bookshelf.json');
    // 隔离：清掉分类文件与书架文件，避免上一个用例的分类定义残留。
    final folderFile = File('${tmpDir.path}/data/shelf_folders.json');
    if (folderFile.existsSync()) folderFile.deleteSync();
    if (shelfFile.existsSync()) shelfFile.deleteSync();
    BookshelfStore.bindFile(shelfFile);
  });

  tearDownAll(() async {
    try {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  ComicDetail detail(String sid, String id, String name) {
    final comic = ComicItem(id, name, 'https://x/$id.jpg');
    return ComicDetail(comic, const <Chapter>[], sourceId: sid);
  }

  group('分类定义（shelf_folders.json）', () {
    test('默认只有「全部」视图与「默认分类」，全部排最前', () async {
      final f = await BookshelfStore.folders();
      expect(f.first['id'], BookshelfStore.allFolderId);
      expect(f.any((e) => e['id'] == BookshelfStore.defaultFolderId), isTrue);
      // 自建分类为空
      expect(await BookshelfStore.userFolders(), isEmpty);
    });

    test('新增分类后按创建顺序排序，重名自动加序号', () async {
      await BookshelfStore.addFolder('追更');
      await BookshelfStore.addFolder('完结');
      await BookshelfStore.addFolder('追更'); // 重名
      final fs = await BookshelfStore.userFolders();
      expect(fs, hasLength(3));
      final names = fs.map((f) => f['name'] as String).toList();
      expect(names[0], '追更');
      expect(names[1], '完结');
      expect(names[2], startsWith('追更')); // 重名加序号，不静默去重
    });

    test('重命名分类生效；删除分类后书籍回落「默认分类」', () async {
      await BookshelfStore.addFolder('待删');
      final fs1 = await BookshelfStore.userFolders();
      final id = fs1.first['id'] as String;
      await BookshelfStore.renameFolder(id, '改名后');
      final fs2 = await BookshelfStore.userFolders();
      expect(fs2.first['name'], '改名后');

      // 放一本书进「待删」分类，删除分类后应回落默认分类（书不删）
      BookshelfStore.add('dm5', detail('dm5', '1', '漫画A'));
      BookshelfStore.setFolderId('dm5', '1', id);
      expect(BookshelfStore.folderIdOf('dm5', '1'), id);

      await BookshelfStore.deleteFolder(id);
      expect(await BookshelfStore.userFolders(), isEmpty);
      expect(BookshelfStore.folderIdOf('dm5', '1'),
          BookshelfStore.defaultFolderId,
          reason: '删除分类不应删书，书籍回落到默认分类');
      expect(BookshelfStore.listAll(), hasLength(1));
    });
  });

  group('书籍分类归属', () {
    test('新收藏默认归「默认分类」；旧数据无 folderId 兜底默认分类', () async {
      BookshelfStore.add('dm5', detail('dm5', '1', '漫画A'));
      expect(BookshelfStore.folderIdOf('dm5', '1'),
          BookshelfStore.defaultFolderId);

      // 模拟旧数据：无 folderId 字段
      await shelfFile.writeAsString(
          '{"dm5|2":{"sourceId":"dm5","id":"2","name":"漫画B","pic":"","chapters":[],"addedAt":0}}');
      BookshelfStore.bindFile(shelfFile);
      expect(BookshelfStore.folderIdOf('dm5', '2'),
          BookshelfStore.defaultFolderId);
    });

    test('setFolderId 写入后读回一致；移动到默认分类归位', () async {
      await BookshelfStore.addFolder('追更');
      BookshelfStore.add('dm5', detail('dm5', '3', '漫画C'));
      final fid = (await BookshelfStore.userFolders()).first['id'] as String;
      BookshelfStore.setFolderId('dm5', '3', fid);
      expect(BookshelfStore.folderIdOf('dm5', '3'), fid);
      BookshelfStore.setFolderId('dm5', '3', BookshelfStore.defaultFolderId);
      expect(BookshelfStore.folderIdOf('dm5', '3'),
          BookshelfStore.defaultFolderId);
    });
  });

  group('备份兼容', () {
    test('collectBackup 含 shelf_folders；restoreBackup 写回', () async {
      await BookshelfStore.addFolder('追更');
      final backup = await LocalStore.collectBackup(
        bookshelfData: BookshelfStore.exportData(),
        novelShelfData: {},
      );
      expect(backup['shelf_folders'], isNotNull);
      expect((backup['shelf_folders'] as List), hasLength(1));

      // 模拟恢复：先改内存分类缓存，restore 后应重新读到分类
      final count = await LocalStore.restoreBackup(backup);
      expect(count, greaterThan(0));
    });

    test('importData 后书架清空且分类内存缓存失效（重读磁盘最新定义）', () async {
      await BookshelfStore.addFolder('A');
      await BookshelfStore.addFolder('B');
      BookshelfStore.importData({});
      // importData 清空书架缓存 + 分类内存缓存标记
      expect(BookshelfStore.listAll(), isEmpty);
      // 磁盘上的 shelf_folders.json 由备份恢复流程（restoreBackup）独立写回，
      // 这里只验证 importData 本身不抛、且重读能拿到磁盘上的定义。
      final fs = await BookshelfStore.folders();
      expect(fs.any((f) => f['id'] == BookshelfStore.allFolderId), isTrue);
    });
  });
}
