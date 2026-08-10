import '../models/comic_item.dart';
import '../net/novel_shelf_store.dart';
import 'source_config.dart';
import 'source_result.dart';

/// 小说数据源统一接口（多源聚合核心契约）。
///
/// 与 [ComicSource] 对齐：条目复用 [ComicItem]，详情/章节模型定义在同文件内。
/// 唯一的语义差异是漫画按「图片页」阅读，小说按「文本段落」阅读，
/// 因此 [chapterContent] 返回 [NovelContent]（段落列表 + 上下章导航）而非图片 URL。
abstract class NovelSource {
  String get id;
  String get name;

  /// 是否需要登录。默认 false，子类可覆盖。
  bool get requiresLogin => false;

  /// 是否启用。默认 true。
  bool get isEnabled => true;

  /// 源优先级层级。默认 fallback。
  SourceTier get tier => SourceTier.fallback;

  /// 轻量连通性探测。默认 unknown。
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
  Future<NovelDetail> detail(String novelId);

  /// 章节正文：返回段落列表与上下章导航。
  Future<NovelContent> chapterContent(String chapterId);

  // 书架统一走本地存储，按 sourceId 分组。
  Future<void> toggleBookshelf(NovelDetail detail) async {
    if (NovelShelfStore.contains(id, detail.id)) {
      NovelShelfStore.remove(id, detail.id);
    } else {
      NovelShelfStore.add(id, detail);
    }
  }

  Future<List<NovelDetail>> bookshelf() async => NovelShelfStore.listBySource(id);

  Future<bool> isInBookshelf(String novelId) async =>
      NovelShelfStore.contains(id, novelId);
}

/// 通用分类（与漫画源共用结构）。
class Category {
  final String id;
  final String name;
  Category(this.id, this.name);
}

/// 小说章节（id 由具体源定义，通常是章节序号或 slug）。
class NovelChapter {
  final String id;
  final String title;
  final int index;
  NovelChapter(this.id, this.title, {this.index = 0});
}

/// 小说详情：封面/元信息 + 章节目录。
class NovelDetail {
  ComicItem comic;
  List<NovelChapter> chapters;
  String? description;
  String? author;
  String? area;
  String? type;
  String? status;
  NovelDetail(
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

/// 章节正文：段落列表 + 上下章导航，供阅读器渲染。
class NovelContent {
  final String chapterId;
  final String title;
  final List<String> paragraphs;
  final String? prevChapterId;
  final String? nextChapterId;
  NovelContent(
    this.chapterId,
    this.title,
    this.paragraphs, {
    this.prevChapterId,
    this.nextChapterId,
  });
}
