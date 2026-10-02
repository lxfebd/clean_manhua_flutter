import 'dart:async';

import '../../models/comic_item.dart';
import '../novel_source.dart';
import '../source_result.dart';
import 'custom_source_def.dart';
import 'dsl_engine_mixin.dart';
import 'html_parser.dart';

/// 自定义源 JSON DSL 的小说源实现（最小可行版）。
///
/// 复用 [CustomSourceDef] 的 DSL 规则实现 [NovelSource]：目前覆盖
/// `search`（列表）+ `detail`（详情 + 章节目录）+ `chapterContent`（正文章节）。
/// 由于 [CustomSourceDef] 的字段命名偏漫画/视频语义，小说映射约定如下：
/// - 章节列表：`detail.chapters` CSS（复用漫画章节容器语义）或
///   `detail.chaptersRe` 正则（组 1 = 标题、组 2 = 链接）；
/// - 章节目录每条目 id 复用漫画章节规则：[章节链接相对路径的去前导斜杠形式]，
///   形如 `novel/1.html`，由 `contentUrl` 模板自行拼接成完整 URL；
/// - 正文：`detail.picListUrl` 复用为「正文章节页 URL」（支持 `{id}` 占位符，
///   即章节 id），按 `picListCss`（CSS 段落容器）或 `picListRe`（正则，
///   组 1 = 段落）抽取段落；可用 `picListDecrypt` 解码、`picFilter` 过滤
///   （不命中的段落跳过）。
///
/// 未实现（接口默认/空实现，jobs/shelf 走本地书架）：
/// - `rank`：返回空列表。
/// - 上下章导航：返回 null。
///
/// 网络统一走全局 Net（http_client.dart）。
class DslNovelSource extends NovelSource with DslEngineMixin {
  @override
  final CustomSourceDef def;

  DslNovelSource(this.def);

  @override
  String get id => def.id;

  @override
  String get name => def.name;

  @override
  bool get requiresLogin => def.requiresLogin;

  // ---- 分类导航（与漫画/视频引擎同一套 categories/listByCategory 通道）----
  @override
  Future<List<Category>> categories() async {
    final rule = def.categoriesRule;
    final url = def.categoriesUrl;
    if (rule == null || url == null) return const [];
    final html = await fetchHtml(url, null, rule.decrypt, '', 'dsl-novel');
    final root = parseHtml(html);
    if (rule.selector.isNotEmpty) {
      final els = root.querySelectorAll(rule.selector);
      final list = <Category>[];
      for (final e in els) {
        // 与 comic 引擎一致：itemName/itemUrl 支持 `text`/`innerText` 虚拟属性
        // （走 extract），href 是 HTML 属性（attr）。
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
    }
    return const [];
  }

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final rule = def.categoryListRule;
    if (rule == null || def.categoryListUrl == null) return const [];
    final url = pageUrl(def.categoryListUrl!, categoryId, page);
    return _runList(url, rule);
  }

  @override
  Future<List<ComicItem>> rank(int page) async => const [];

  // ---- 搜索（复用列表规则）----
  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final rule = def.searchRule;
    if (rule == null || def.searchUrl == null) return const [];
    final url = pageUrl(def.searchUrl!, null, page, keyword: keyword);
    return _runList(url, rule);
  }

  // ---- 详情（章节目录）----
  @override
  Future<NovelDetail> detail(String novelId) async {
    final d = def.detailRule;
    if (d == null || def.detailUrl == null) {
      throw SourceError.service('该源未配置详情页规则');
    }
    final html =
        await fetchHtml(def.detailUrl!, null, d.baseDecrypt, novelId, 'dsl-novel');
    final root = parseHtml(html);
    final cover = queryAttr(root, d.cover, d.coverAttr);
    final item = ComicItem(
      novelId,
      d.title.isNotEmpty ? queryText(root, d.title) : '',
      cover.isEmpty ? '' : abs(def.detailUrl!, cover),
    )..author = queryText(root, d.author);

    final chapters = <NovelChapter>[];
    // CSS：章节容器
    final nodes = d.chapters.isNotEmpty
        ? root.querySelectorAll(d.chapters)
        : <HtmlNode>[];
    var idx = 0;
    for (final n in nodes) {
      var href = attr(n, d.chapterUrl);
      if (href.isEmpty && d.chapterUrlRe.isNotEmpty) {
        final m = safeRegExp(d.chapterUrlRe).firstMatch(n.innerText);
        if (m != null) {
        // 无捕获组正则 group(1) 越界抛异常，判 groupCount 再取
        href = m.groupCount >= 1 ? (m.group(1) ?? m.group(0)!) : m.group(0)!;
      }
      }
      if (href.isEmpty) continue;
      final cid = extractId(href, novelId);
      if (cid.isEmpty) continue;
      final title = opt(n, d.chapterTitle).isNotEmpty
          ? opt(n, d.chapterTitle)
          : n.innerText.trim();
      if (title.isEmpty) continue;
      chapters.add(NovelChapter(cid, title, index: idx++));
    }
    // 或正则：组 1 = 标题、组 2 = 链接（支持命名组 href/title）
    if (chapters.isEmpty && d.chaptersRe.isNotEmpty) {
      final re = safeRegExp(d.chaptersRe);
      for (final m in re.allMatches(html)) {
        final title = dslGroup(m, re, 'title', 1);
        if (title.isEmpty) continue;
        final href = dslGroup(m, re, 'href', 2);
        if (href.isEmpty) continue;
        final cid = extractId(href, novelId);
        if (cid.isEmpty) continue;
        chapters.add(NovelChapter(cid, title.trim(), index: idx++));
      }
    }

    return NovelDetail(
      item,
      chapters,
      description: d.description.isNotEmpty ? queryText(root, d.description) : null,
      author: (item.author == null || item.author!.isEmpty) ? null : item.author,
      area: d.area.isNotEmpty ? queryText(root, d.area) : null,
      type: d.type.isNotEmpty ? queryText(root, d.type) : null,
      status: d.status.isNotEmpty ? queryText(root, d.status) : null,
      sourceId: id,
    );
  }

  // ---- 章节正文（复用「章节图」规则）----
  @override
  Future<NovelContent> chapterContent(String chapterId) async {
    final d = def.detailRule;
    if (d == null || d.picListUrl.isEmpty) {
      throw SourceError.service('该源未配置正文章节页规则（picListUrl）');
    }
    final html = await fetchHtml(
        d.picListUrl, null, d.picListDecrypt, chapterId, 'dsl-novel');
    final root = parseHtml(html);
    final paragraphs = <String>[];
    final nodes = d.picListCss.isNotEmpty
        ? root.querySelectorAll(d.picListCss)
        : <HtmlNode>[];
    if (nodes.isNotEmpty) {
      for (final n in nodes) {
        final t = n.innerText.trim();
        if (t.isEmpty) continue;
        if (d.picFilter.isNotEmpty && !safeRegExp(d.picFilter).hasMatch(t)) continue;
        paragraphs.add(t);
      }
    } else if (d.picListRe.isNotEmpty) {
      final re = safeRegExp(d.picListRe);
      for (final m in re.allMatches(html)) {
        final t = (m.group(1) ?? '').trim();
        if (t.isEmpty) continue;
        if (d.picFilter.isNotEmpty && !safeRegExp(d.picFilter).hasMatch(t)) continue;
        paragraphs.add(t);
      }
    }
    if (paragraphs.isEmpty) {
      // 兜底：用整个正文容器的 innerText 按空行分段。
      final t = root.innerText.trim();
      if (t.isNotEmpty) {
        paragraphs.addAll(t
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty));
      }
    }
    return NovelContent(chapterId, '', paragraphs);
  }

  // ---- 列表组装（复用 mixin 的字段抽取工具）----
  Future<List<ComicItem>> _runList(String url, DslListRule rule) async {
    final html = await fetchHtml(url, null, rule.decrypt, '', 'dsl-novel');
    final root = parseHtml(html);
    List<HtmlNode> els;
    if (rule.selector.isNotEmpty) {
      els = root.querySelectorAll(rule.selector);
    } else if (rule.regex.isNotEmpty) {
      // 正则行式：每个匹配包装成虚拟节点，attrs['r1']..'rn' = 捕获组
      final re = safeRegExp(rule.regex);
      final groups = <List<String>>[];
      for (final m in re.allMatches(html)) {
        final g = <String>[];
        for (var i = 1; i <= m.groupCount; i++) {
          g.add(m.group(i) ?? '');
        }
        groups.add(g);
      }
      els = groups.map((g) {
        final n = HtmlNode('', {}, text: g.join('|'));
        for (var i = 0; i < g.length; i++) {
          n.attrs['r${i + 1}'] = g[i];
        }
        return n;
      }).toList();
    } else {
      els = const [];
    }
    final items = <ComicItem>[];
    for (final e in els) {
      final name = extract(e, rule.name);
      if (name.isEmpty) continue;
      final id = extractId(extract(e, rule.id), '');
      if (id.isEmpty) continue;
      final pic = extract(e, rule.pic);
      items.add(ComicItem(id, name, pic.isEmpty ? '' : abs(url, pic))
        ..author = opt(e, rule.author)
        ..content = opt(e, rule.content));
    }
    return items;
  }
}