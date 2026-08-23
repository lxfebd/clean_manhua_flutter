import 'package:xingmanxia/sources/dm5_source.dart';

Future<void> main() async {
  final src = Dm5Source();
  print('=== 动漫屋 排行榜 ===');
  final list = await src.rank(1);
  for (final m in list.take(5)) {
    print('  - ${m.name}  (id=${m.id})  cover=${m.pic}');
  }
  if (list.isEmpty) {
    print('  (空)');
    return;
  }
  final id = list.first.id;
  print('\n=== 动漫屋 搜索 "海贼王" ===');
  final search = await src.search('海贼王', 1);
  for (final m in search.take(3)) {
    print('  - ${m.name}  (id=${m.id})');
  }

  print('\n=== 动漫屋 详情 (id=$id) ===');
  final detail = await src.detail(id);
  print('  ${detail.comic.name}  章节数=${detail.chapters.length}');
  for (final c in detail.chapters.take(5)) {
    print('    - ${c.title}');
  }
  if (detail.chapters.isEmpty) return;
  final cid = detail.chapters.first.id;
  print('\n=== 动漫屋 章节图片 (chapter=$cid) ===');
  final pics = await src.chapterPics(cid);
  print('  共 ${pics.length} 页');
  for (final u in pics.take(3)) {
    print('  $u');
  }
}