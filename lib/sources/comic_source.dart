import '../models/comic_item.dart';
import '../net/bookshelf_store.dart';
import '../net/local_store.dart';
import 'source_base.dart';

/// 漫画数据源统一接口（多源聚合核心契约）。
abstract class ComicSource extends AppSource {
  /// 分类列表。
  Future<List<Category>> categories();

  /// 按分类分页列表。
  Future<List<ComicItem>> listByCategory(String categoryId, int page);

  /// 排行榜。
  Future<List<ComicItem>> rank(int page);

  /// 搜索。
  Future<List<ComicItem>> search(String keyword, int page);

  /// 详情：返回章节列表。
  Future<ComicDetail> detail(String comicId);

  /// 章节图片 URL 列表。
  Future<List<String>> chapterPics(String chapterId);

  // 书架统一走本地存储，按 sourceId 分组。
  Future<void> toggleBookshelf(ComicDetail detail) async {
    if (BookshelfStore.contains(id, detail.id)) {
      BookshelfStore.remove(id, detail.id);
    } else {
      BookshelfStore.add(id, detail);
    }
  }

  Future<List<ComicDetail>> bookshelf() async => BookshelfStore.listBySource(id);

  Future<bool> isInBookshelf(String comicId) async =>
      BookshelfStore.contains(id, comicId);
}

class Chapter {
  final String id;
  final String title;
  Chapter(this.id, this.title);
}

class ComicDetail {
  ComicItem comic;
  List<Chapter> chapters;
  String? description;
  String? author;
  String? area;
  String? type;
  String? status;
  /// 所属源 id。书架统一视图由 BookshelfStore 填充（存储里每本书自带 sourceId），
  /// UI 直接用它定位源，不要用 comicId 全局反查——跨源同名 id 会取错源。
  String? sourceId;
  ComicDetail(
    this.comic,
    this.chapters, {
    this.description,
    this.author,
    this.area,
    this.type,
    this.status,
    this.sourceId,
  });

  String get id => comic.id;
  String get name => comic.name;
  String? get pic => comic.pic.isEmpty ? null : comic.pic;

  /// 本作品对应的收藏/历史条目（详情页历史查找/记录用统一构造）。
  /// 作者来自详情页抓取结果（[author]），优于条目自身可能为空的值。
  Bookmark bookmarkFor(String sourceId) =>
      Bookmark.fromComic(sourceId, comic).copyWith(author: author);
}
