import 'package:xingmanxia/sources/mangadex_source.dart';

Future<void> main() async {
  final src = MangaDexSource();
  print('=== MangaDex 列表（热门） ===');
  final list = await src.listByCategory('trending', 1);
  for (final m in list.take(5)) {
    print('  • ${m.name}  (id=${m.id})  cover=${m.pic}');
  }
  if (list.isEmpty) {
    print('  (空)');
    return;
  }
  final id = list.first.id;
  print('\n=== MangaDex 搜索 "one punch" ===');
  final search = await src.search('one punch', 1);
  for (final m in search.take(3)) {
    print('  • ${m.name}  (id=${m.id})');
  }

  print('\n=== MangaDex 详情 (id=$id) ===');
  final detail = await src.detail(id);
  print('  ${detail.comic.name}  章节数=${detail.chapters.length}');
  for (final c in detail.chapters.take(5)) {
    print('    - ${c.title}');
  }
  if (detail.chapters.isEmpty) return;
  final cid = detail.chapters.first.id;
  print('\n=== MangaDex 章节图片 (chapter=$cid) ===');
  final pics = await src.chapterPics(cid);
  for (final u in pics.take(3)) {
    print('  $u');
  }
  print('  ...共 ${pics.length} 页');
}
