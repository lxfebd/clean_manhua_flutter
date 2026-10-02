import 'dart:convert';

import '../../models/comic_item.dart';
import '../../net/aes_cbc.dart';
import '../comic_source.dart';
import '../source_config.dart';
import '../source_result.dart';
import 'custom_source_def.dart';
import 'dsl_engine_mixin.dart';
import 'html_parser.dart';

/// 自定义源 JSON DSL 的漫画源实现。
///
/// 一份 DSL 定义（[CustomSourceDef]）实例化一个 [DslComicSource]，完整实现
/// [ComicSource] 接口：分类/列表/排行/搜索/详情/章节图，全部由「基础 URL +
/// CSS 或正则规则 + 可选解码（AES/Base64/替换）」声明式驱动，无需写 Dart 代码。
///
/// 数据流向（以「详情页章节图」为例）：
/// `chapterPics` → GET `picListUrl` → 响应 → 按 `picList.decrypt` 解码
/// → 按 `picList.pics`（CSS 或正则）抽取图片地址 → 按 `picList.replace` 修正
/// → 按 `picList.picFilter` 过滤 → 返回。
///
/// 网络统一走 Net（http_client.dart），域名可被 SourceConfigStore 的用户配置覆盖，
/// 与其他内置源行为一致（走同一代理/降级链）。
class DslComicSource extends ComicSource with DslEngineMixin {
  @override
  final CustomSourceDef def;

  DslComicSource(this.def);

  @override
  String get id => def.id;

  @override
  String get name => def.name;

  @override
  bool get requiresLogin => def.requiresLogin;

  // ---- 分类 ----
  @override
  Future<List<Category>> categories() async {
    final rule = def.categoriesRule;
    final url = def.categoriesUrl;
    if (rule == null || url == null) return const [];
    return runRule(url, rule, (els) {
      final list = <Category>[];
      for (final e in els) {
        final href = extract(e, rule.url.isNotEmpty ? rule.url : 'href');
        final name = rule.itemName != null && rule.itemName!.isNotEmpty
            ? extract(e, rule.itemName!)
            : e.innerText.trim();
        final id = rule.itemUrl != null && rule.itemUrl!.isNotEmpty
            ? extract(e, rule.itemUrl!)
            : href;
        list.add(Category(id.isEmpty ? href : id, name.isEmpty ? href : name));
      }
      return list;
    }, (_) => const <Category>[], 'dsl-comic');
  }

  // ---- 列表 / 排行 / 搜索 ----
  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final rule = def.categoryListRule;
    if (rule == null || def.categoryListUrl == null) return const [];
    final url = pageUrl(def.categoryListUrl!, categoryId, page);
    return _list(url, rule);
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    final rule = def.rankRule;
    if (rule == null || def.rankUrl == null) return const [];
    return _list(pageUrl(def.rankUrl!, null, page), rule);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final rule = def.searchRule;
    if (rule == null || def.searchUrl == null) return const [];
    return _list(pageUrl(def.searchUrl!, null, page, keyword: keyword), rule);
  }

  Future<List<ComicItem>> _list(String url, DslListRule rule) async {
    return runRule(url, rule, (els) {
      final items = <ComicItem>[];
      for (final e in els) {
        final name = extract(e, rule.name);
        if (name.isEmpty) continue;
        final id = extractId(extract(e, rule.id), '');
        if (id.isEmpty) continue;
        final pic = extract(e, rule.pic);
        items.add(ComicItem(id, name, pic.isEmpty ? '' : abs(url, pic))
          ..yname = opt(e, rule.yname)
          ..score = opt(e, rule.score)
          ..hits = opt(e, rule.hits)
          ..rank = opt(e, rule.rank)
          ..author = opt(e, rule.author)
          ..content = opt(e, rule.content)
          ..picFallback = (rule.picFallback?.isNotEmpty ?? false)
              ? abs(url, extract(e, rule.picFallback ?? ''))
              : null);
      }
      return items;
    }, (els) => const [], 'dsl-comic');
  }

  // ---- 详情 ----
  @override
  Future<ComicDetail> detail(String comicId) async {
    final d = def.detailRule;
    if (d == null || def.detailUrl == null) {
      throw SourceError.service('该源未配置详情页规则');
    }
    final html =
        await fetchHtml(def.detailUrl!, null, d.baseDecrypt, comicId, 'dsl-comic');
    final root = parseHtml(html);
    final cover = queryAttr(root, d.cover, d.coverAttr);
    final item = ComicItem(comicId, d.title.isNotEmpty ? queryText(root, d.title) : '', cover.isEmpty ? '' : abs(def.detailUrl!, cover))
      ..author = queryText(root, d.author)
      ..content = queryText(root, d.description);

    // 章节：CSS 选择器抽取，或正则
    final chapters = <Chapter>[];
    if (d.chapters.isNotEmpty) {
      final nodes = root.querySelectorAll(d.chapters);
      final hrefRe = d.chapterUrlRe.isNotEmpty
          ? safeRegExp(d.chapterUrlRe)
          : null;
      for (final n in nodes) {
        var href = attr(n, d.chapterUrl);
        if (href.isEmpty && hrefRe != null) {
          final m = hrefRe.firstMatch(n.innerText);
          // 避免 group(1) 越界：无捕获组正则写成 `/.../` 时 groupCount==0，
          // Dart 的 Match.group 对越界抛 RangeError 而非返回 null。有捕获组
          // 用组 1（通常是 href），否则退回整个匹配串。
          if (m != null) {
            href = m.groupCount >= 1 ? (m.group(1) ?? m.group(0)!) : m.group(0)!;
          }
        }
        if (href.isEmpty) continue;
        final cid = extractId(href, comicId);
        if (cid.isEmpty) continue;
        final title = attr(n, d.chapterTitle).isNotEmpty
            ? attr(n, d.chapterTitle)
            : n.innerText.trim();
        if (title.isEmpty) continue;
        chapters.add(Chapter(cid, title));
      }
    }
    if (chapters.isEmpty && d.chaptersRe.isNotEmpty) {
      final re = safeRegExp(d.chaptersRe);
      for (final m in re.allMatches(html)) {
        // 与 novel 引擎一致：组 1 = 标题、组 2 = 链接；支持命名组 href/title。
        final title = dslGroup(m, re, 'title', 1);
        if (title.isEmpty) continue;
        final href = dslGroup(m, re, 'href', 2);
        if (href.isEmpty) continue;
        final cid = extractId(href, comicId);
        if (cid.isEmpty) continue;
        chapters.add(Chapter(cid, title.trim()));
      }
    }

    return ComicDetail(item, chapters,
        sourceId: id,
        description: item.content,
        author: item.author);
  }

  // ---- 章节图片 ----
  @override
  Future<List<String>> chapterPics(String chapterId) async {
    final d = def.detailRule;
    if (d == null || d.picListUrl.isEmpty) return const [];
    final html =
        await fetchHtml(d.picListUrl, null, d.picListDecrypt, chapterId, 'dsl-comic');
    final root = parseHtml(html);
    final nodes = d.picListCss.isNotEmpty
        ? root.querySelectorAll(d.picListCss)
        : <HtmlNode>[];
    final urls = <String>[];
    if (nodes.isNotEmpty) {
      for (final n in nodes) {
        var u = attr(n, d.picAttr);
        if (u.isEmpty) u = n.attrs['src'] ?? '';
        if (u.isEmpty) u = n.innerText.trim();
        if (u.isNotEmpty) urls.add(u);
      }
    } else if (d.picListRe.isNotEmpty) {
      final re = safeRegExp(d.picListRe);
      for (final m in re.allMatches(html)) {
        final u = m.group(1) ?? '';
        if (u.isNotEmpty) urls.add(u);
      }
    }
    // 过滤 + 修正
    final filtered = <String>[];
    for (var u in urls) {
      if (d.picFilter.isNotEmpty) {
        final re = safeRegExp(d.picFilter);
        if (!re.hasMatch(u)) continue;
      }
      u = applyReplace(u, d.picReplace);
      if (u.isNotEmpty && !filtered.contains(u)) filtered.add(abs(d.picListUrl, u));
    }
    return filtered;
  }
}
