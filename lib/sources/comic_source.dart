import '../models/comic_item.dart';
import '../net/bookshelf_store.dart';
import 'source_config.dart';
import 'source_result.dart';

/// 漫画数据源统一接口（多源聚合核心契约）。
abstract class ComicSource {
  String get id;
  String get name;

  /// 是否需要登录（哔咔等）。默认 false，子类可覆盖。
  bool get requiresLogin => false;

  /// 是否启用（可由源管理页/配置控制）。默认 true。
  bool get isEnabled => true;

  /// 源优先级层级。默认 fallback。
  SourceTier get tier => SourceTier.fallback;

  /// 轻量连通性探测，结果可缓存用于「源状态灯」。默认 unknown（子类可覆盖实现真实探测）。
  Future<ConnectionStatus> health() async => ConnectionStatus.unknown;

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
class Category {
  final String id;
  final String name;
  Category(this.id, this.name);
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
  ComicDetail(
    this.comic,
    this.chapters, {
    this.description,
    this.author,
    this.area,
    this.type,
    this.status,
  });

  String get id => comic.id;
  String get name => comic.name;
  String? get pic => comic.pic.isEmpty ? null : comic.pic;
}
