import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/novel_shelf_store.dart';
import 'package:xingmanxia/sources/novel_source.dart';

/// 修复 P1-4「小说无更新检查」回归测试。
///
/// 覆盖 NovelShelfStore 新增的更新基线 API（ShelfUpdater 阶段二消费）：
///   1. 首次检查（last=-1）不报更新，只置基线——避免"加书后第一轮必报更新"
///   2. 章节数增长后 hasUpdate/newChapterCount 生效
///   3. 章节数不变（或源端缩水）不报更新
///   4. 对不在书架的 id 写基线不抛异常（源端 sid 校验失败的旁路安全）
void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_novel_update');
    NovelShelfStore.bindFile(File('${tmp.path}/novel_shelf.json'));
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() {
    NovelShelfStore.bindFile(File('${tmp.path}/novel_shelf.json'));
    NovelShelfStore.importData({}); // 清空上个用例的残留
  });

  NovelDetail novelOf(String id, String name, int chapterCount) {
    final chapters = [
      for (var i = 0; i < chapterCount; i++)
        NovelChapter('$id/ch$i', '第${i + 1}章', index: i),
    ];
    return NovelDetail(
      ComicItem(id, name, '')..author = '作者',
      chapters,
      sourceId: 'biquge',
    );
  }

  test('首次检查（last=-1）：不报更新，只置基线', () {
    NovelShelfStore.add('biquge', novelOf('n1', '剑来', 10));
    // 加入书架时没有写 lastChapters → 基线 -1
    expect(NovelShelfStore.lastSeenChapters('biquge', 'n1'), -1);
    // ShelfUpdater 阶段二语义：last<0 时先置基线、不进 updated 列表
    NovelShelfStore.setLastSeenChapters('biquge', 'n1', 10);
    expect(NovelShelfStore.hasUpdate('biquge', 'n1', 10), isFalse);
    expect(NovelShelfStore.newChapterCount('biquge', 'n1', 10), 0);
  });

  test('章节数增长：hasUpdate 为真且计数正确', () {
    NovelShelfStore.add('biquge', novelOf('n2', '夜的命名术', 100));
    NovelShelfStore.setLastSeenChapters('biquge', 'n2', 100);
    // 源端更新到 105 章
    expect(NovelShelfStore.hasUpdate('biquge', 'n2', 105), isTrue);
    expect(NovelShelfStore.newChapterCount('biquge', 'n2', 105), 5);
    // 检查完成后推进基线 → 下一轮不再报同一批更新
    NovelShelfStore.setLastSeenChapters('biquge', 'n2', 105);
    expect(NovelShelfStore.hasUpdate('biquge', 'n2', 105), isFalse);
  });

  test('章节数不变或缩水：不报更新', () {
    NovelShelfStore.add('biquge', novelOf('n3', '赤心巡天', 50));
    NovelShelfStore.setLastSeenChapters('biquge', 'n3', 50);
    expect(NovelShelfStore.hasUpdate('biquge', 'n3', 50), isFalse);
    // 源端重组目录导致章节数变少：同样不报
    expect(NovelShelfStore.hasUpdate('biquge', 'n3', 40), isFalse);
    expect(NovelShelfStore.newChapterCount('biquge', 'n3', 40), 0);
  });

  test('不在书架的 id：写基线静默返回，不抛异常', () {
    expect(
      () => NovelShelfStore.setLastSeenChapters('biquge', 'ghost', 10),
      returnsNormally,
    );
    expect(NovelShelfStore.lastSeenChapters('biquge', 'ghost'), -1);
  });

  test('基线持久化：重载 store 后仍在（重启恢复）', () async {
    NovelShelfStore.add('biquge', novelOf('n4', '深海余烬', 30));
    NovelShelfStore.setLastSeenChapters('biquge', 'n4', 30);
    // 防抖写盘 300ms 合并：等它落盘后从文件重载
    await Future<void>.delayed(const Duration(milliseconds: 500));
    NovelShelfStore.bindFile(File('${tmp.path}/novel_shelf.json'));
    expect(NovelShelfStore.lastSeenChapters('biquge', 'n4'), 30);
  });
}