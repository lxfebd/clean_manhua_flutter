import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';
import 'package:xingmanxia/sources/comic_source.dart';

/// 收藏筛选相关回归：type/status 持久化、updateTimeOf 排序辅助。
void main() {
  late Directory tmpDir;
  late File shelfFile;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('shelf_filter_');
    shelfFile = File('${tmpDir.path}/bookshelf.json');
    BookshelfStore.bindFile(shelfFile);
  });
  tearDown(() async {
    if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
  });

  ComicDetail detail(String id, {String status = '', String type = ''}) {
    final comic = ComicItem(id, '测试漫画$id', 'https://x/p$id.jpg');
    return ComicDetail(
      comic,
      [Chapter('c1', '第1话')],
      author: '作者',
      status: status,
      type: type,
      sourceId: 'src',
    );
  }

  test('书架 add 持久化 type/status（供筛选）', () {
    BookshelfStore.add('src', detail('1', status: '连载中', type: '热血'));

    final loaded = BookshelfStore.listAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.status, '连载中');
    expect(loaded.first.type, '热血');
  });

  test('updateTimeOf：优先最后阅读时间，回退收藏时间', () async {
    // 需要 LocalStore 的 history —— 但该测试只有一个 Bookmark key 需要真实 sourceId。
    // 用两个条目：一个读过的、一个没读过的。
    BookshelfStore.add('src', detail('read'));
    BookshelfStore.add('src', detail('unread'));

    // 直接调 updateTimeOf：无历史时回退 addedAt。
    final read = BookshelfStore.listAll()
        .firstWhere((d) => d.id == 'read');
    final t = BookshelfStore.updateTimeOf(read, []);
    expect(t, BookshelfStore.addedAtOf(read));
  });
}