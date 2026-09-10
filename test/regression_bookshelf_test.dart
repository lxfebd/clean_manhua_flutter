import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/bookshelf_store.dart';

/// 回归测试：验证「书架 JSON 损坏 → 备份原文件 + 从空开始」的修复（不再静默清空）。
/// 同时覆盖「文件缺失」与「合法 JSON 正常加载」两条路径，确保未引入回归。
void main() {
  late Directory tmpDir;
  late File shelfFile;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('bookshelf_regr_');
    shelfFile = File('${tmpDir.path}/bookshelf.json');
  });
  tearDown(() async {
    if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
  });

  /// 列出目录下所有 .corrupt-* 备份文件
  List<File> getBackups() => tmpDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('.corrupt-'))
      .toList();

  test('损坏 JSON：备份原文件并从空开始（不再静默清空）', () async {
    const garbage = '{这是损坏的 json,,, 不是合法 JSON';
    await shelfFile.writeAsString(garbage);

    BookshelfStore.bindFile(shelfFile);

    // 修复后：缓存应为空（而非崩溃），且原损坏文件被备份可追溯
    expect(BookshelfStore.listAll(), isEmpty,
        reason: '损坏 JSON 不应导致崩溃，缓存从空开始');
    final backups = getBackups();
    expect(backups, hasLength(1), reason: '应生成 1 个 .corrupt-* 备份文件');
    expect(backups.first.readAsStringSync(), garbage,
        reason: '备份内容应与损坏原文件一致，便于追溯');
  });

  test('文件缺失：空缓存，且不生成备份', () {
    // 文件不存在属于正常首启场景，不应误生成备份
    BookshelfStore.bindFile(shelfFile);
    expect(BookshelfStore.listAll(), isEmpty);
    expect(getBackups(), isEmpty);
  });

  test('合法 JSON：正常加载（无回归）', () async {
    const valid =
        '{"dm5|100":{"sourceId":"dm5","id":"100","name":"测试漫画","pic":"https://x/p.jpg","author":"作者","description":"简介","chapters":[{"id":"c1","title":"第1话"}],"addedAt":0}}';
    await shelfFile.writeAsString(valid);

    BookshelfStore.bindFile(shelfFile);

    expect(BookshelfStore.listAll(), hasLength(1),
        reason: '合法 JSON 应正常加载一条记录');
    expect(BookshelfStore.listAll().first.id, '100');
    expect(getBackups(), isEmpty, reason: '合法 JSON 不应生成备份');
  });
}
