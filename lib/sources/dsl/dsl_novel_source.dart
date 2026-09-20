import 'dart:async';
import 'dart:io';

import '../../models/comic_item.dart';
import '../../net/error_logger.dart';
import '../../net/http_client.dart';
import '../novel_source.dart';
import '../source_config.dart';
import '../source_result.dart';
import 'custom_source_def.dart';
import 'dsl_comic_source.dart' show DslDecrypt, dslGroup;
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
class DslNovelSource extends NovelSource {
  final CustomSourceDef def;

  DslNovelSource(this.def);

  @override
  String get id => def.id;

  @override
  String get name => def.name;

  @override
  bool get requiresLogin => def.requiresLogin;

  @override
  bool get isEnabled => true;

  @override
  SourceTier get tier => SourceTier.fallback;

  @override
  Future<ConnectionStatus> health() async => ConnectionStatus.unknown;

  // ---- 分类导航（与漫画/视频引擎同一套 categories/listByCategory 通道）----
  @override
  Future<List<Category>> categories() async {
    final rule = def.categoriesRule;
    final url = def.categoriesUrl;
    if (rule == null || url == null) return const [];
    final html = await _fetch(url, null, rule.decrypt, '');
    final root = parseHtml(html);
    if (rule.selector.isNotEmpty) {
      final els = root.querySelectorAll(rule.selector);
      final list = <Category>[];
      for (final e in els) {
        // 与 comic 引擎一致：itemName/itemUrl 支持 `text`/`innerText` 虚拟属性
        // （走 _extract），href 是 HTML 属性（_attr）。
        final href = _extract(e, rule.url.isNotEmpty ? rule.url : 'href');
        final name = rule.itemName != null && rule.itemName!.isNotEmpty
            ? _extract(e, rule.itemName!)
            : e.innerText.trim();
        final id = rule.itemUrl != null && rule.itemUrl!.isNotEmpty
            ? _extract(e, rule.itemUrl!)
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
    final url = def.categoryListUrl!
        .replaceAll('{page}', '$page')
        .replaceAll('{categoryId}', categoryId);
    return _runList(url, rule);
  }

  @override
  Future<List<ComicItem>> rank(int page) async => const [];

  // ---- 搜索（复用列表规则）----
  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final rule = def.searchRule;
    if (rule == null || def.searchUrl == null) return const [];
    final url = def.searchUrl!
        .replaceAll('{page}', '$page')
        .replaceAll('{keyword}', Uri.encodeQueryComponent(keyword));
    return _runList(url, rule);
  }

  // ---- 详情（章节目录）----
  @override
  Future<NovelDetail> detail(String novelId) async {
    final d = def.detailRule;
    if (d == null || def.detailUrl == null) {
      throw SourceError.service('该源未配置详情页规则');
    }
    final html = await _fetch(def.detailUrl!, null, d.baseDecrypt, novelId);
    final root = parseHtml(html);
    final cover = _queryAttr(root, d.cover, d.coverAttr);
    final item = ComicItem(
      novelId,
      d.title.isNotEmpty ? _queryText(root, d.title) : '',
      cover.isEmpty ? '' : _abs(def.detailUrl!, cover),
    )..author = _queryText(root, d.author);

    final chapters = <NovelChapter>[];
    // CSS：章节容器
    final nodes = d.chapters.isNotEmpty
        ? root.querySelectorAll(d.chapters)
        : <HtmlNode>[];
    var idx = 0;
    for (final n in nodes) {
      var href = _attr(n, d.chapterUrl);
      if (href.isEmpty && d.chapterUrlRe.isNotEmpty) {
        final m = RegExp(d.chapterUrlRe).firstMatch(n.innerText);
        if (m != null) href = m.group(1) ?? m.group(0)!;
      }
      if (href.isEmpty) continue;
      final cid = _extractId(href, novelId);
      if (cid.isEmpty) continue;
      final title = _opt(n, d.chapterTitle).isNotEmpty
          ? _opt(n, d.chapterTitle)
          : n.innerText.trim();
      if (title.isEmpty) continue;
      chapters.add(NovelChapter(cid, title, index: idx++));
    }
    // 或正则：组 1 = 标题、组 2 = 链接（支持命名组 href/title）
    if (chapters.isEmpty && d.chaptersRe.isNotEmpty) {
      final re = RegExp(d.chaptersRe);
      for (final m in re.allMatches(html)) {
        final title = dslGroup(m, re, 'title', 1);
        if (title.isEmpty) continue;
        final href = dslGroup(m, re, 'href', 2);
        if (href.isEmpty) continue;
        final cid = _extractId(href, novelId);
        if (cid.isEmpty) continue;
        chapters.add(NovelChapter(cid, title.trim(), index: idx++));
      }
    }

    return NovelDetail(
      item,
      chapters,
      description: d.description.isNotEmpty ? _queryText(root, d.description) : null,
      author: (item.author == null || item.author!.isEmpty) ? null : item.author,
      area: d.area.isNotEmpty ? _queryText(root, d.area) : null,
      type: d.type.isNotEmpty ? _queryText(root, d.type) : null,
      status: d.status.isNotEmpty ? _queryText(root, d.status) : null,
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
    final html = await _fetch(d.picListUrl, null, d.picListDecrypt, chapterId);
    final root = parseHtml(html);
    final paragraphs = <String>[];
    final nodes = d.picListCss.isNotEmpty
        ? root.querySelectorAll(d.picListCss)
        : <HtmlNode>[];
    if (nodes.isNotEmpty) {
      for (final n in nodes) {
        final t = n.innerText.trim();
        if (t.isEmpty) continue;
        if (d.picFilter.isNotEmpty && !RegExp(d.picFilter).hasMatch(t)) continue;
        paragraphs.add(t);
      }
    } else if (d.picListRe.isNotEmpty) {
      final re = RegExp(d.picListRe);
      for (final m in re.allMatches(html)) {
        final t = (m.group(1) ?? '').trim();
        if (t.isEmpty) continue;
        if (d.picFilter.isNotEmpty && !RegExp(d.picFilter).hasMatch(t)) continue;
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

  // ---- 工具 ----
  Future<String> _fetch(String url, String? page, String? decrypt, String id) async {
    final u = url.replaceAll('{id}', id).replaceAll('{page}', page ?? '1');
    try {
      // 优先 Cronet（Android 上 Chromium 网络栈，指纹类浏览器），
      // 规避部分站点对 dart:io HttpClient 指纹的 Cloudflare 质询 403；
      // 非 Android / Cronet 不可用时会自动回退 dart:io。
      final html = await Net.getCronet(u, headers: def.headers);
      if (decrypt == null || decrypt.isEmpty) return html;
      return DslDecrypt.apply(decrypt, html);
    } on SourceError {
      rethrow;
    } catch (e) {
      ErrorLogger.instance.warn('[dsl-novel] fetch failed ($id): $e');
      if (e is SocketException || e is TimeoutException) {
        throw SourceError.network('网络请求失败，请检查网络后重试');
      }
      if (e is FormatException) throw SourceError.parse('页面数据解析失败');
      if (e is HttpException) throw SourceError.service('站点服务异常');
      throw SourceError.unknown('请求失败');
    }
  }

  Future<List<ComicItem>> _runList(String url, DslListRule rule) async {
    final html = await _fetch(url, null, rule.decrypt, '');
    final root = parseHtml(html);
    List<HtmlNode> els;
    if (rule.selector.isNotEmpty) {
      els = root.querySelectorAll(rule.selector);
    } else if (rule.regex.isNotEmpty) {
      // 正则行式：每个匹配包装成虚拟节点，attrs['r1']..'rn' = 捕获组
      final re = RegExp(rule.regex);
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
      final name = _extract(e, rule.name);
      if (name.isEmpty) continue;
      final id = _extractId(_extract(e, rule.id), '');
      if (id.isEmpty) continue;
      final pic = _extract(e, rule.pic);
      items.add(ComicItem(id, name, pic.isEmpty ? '' : _abs(url, pic))
        ..author = _opt(e, rule.author)
        ..content = _opt(e, rule.content));
    }
    return items;
  }

  String _extract(HtmlNode e, String field) {
    final f = field.trim();
    if (f.isEmpty) return e.innerText.trim();
    if (f.contains('|')) {
      final idx = f.indexOf('|');
      final sel = f.substring(0, idx).trim();
      final attr = f.substring(idx + 1).trim();
      final sub = _firstSub(e, sel);
      if (sub == null) return '';
      if (attr == 'text' || attr == 'innerText') return sub.innerText.trim();
      if (attr.isNotEmpty) return sub.attrs[attr.toLowerCase()] ?? '';
      return sub.innerText.trim();
    }
    final direct = e.attrs[f.toLowerCase()];
    if (direct != null) return direct;
    final sub = e.querySelectorAll(f);
    if (sub.isNotEmpty) return sub.first.innerText.trim();
    return e.innerText.trim();
  }

  HtmlNode? _firstSub(HtmlNode e, String selector) {
    final list = e.querySelectorAll(selector);
    return list.isEmpty ? null : list.first;
  }

  String _attr(HtmlNode e, String field) {
    if (field.isEmpty) return '';
    return e.attrs[field.toLowerCase()] ?? '';
  }

  String _opt(HtmlNode e, String? field) {
    if (field == null || field.isEmpty) return '';
    return _extract(e, field);
  }

  String _queryText(HtmlNode root, String selector) {
    if (selector.isEmpty) return '';
    final els = root.querySelectorAll(selector);
    if (els.isEmpty) return '';
    return els.first.innerText.trim();
  }

  String _queryAttr(HtmlNode root, String selector, String attr) {
    if (selector.isEmpty) return '';
    final els = root.querySelectorAll(selector);
    if (els.isEmpty) return '';
    if (attr.isNotEmpty) return els.first.attrs[attr.toLowerCase()] ?? '';
    return els.first.innerText.trim();
  }

  String _extractId(String href, String novelId) {
    var s = href.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('/')) {
      s = '${def.baseUrl}$s';
    } else if (!s.startsWith('http://') && !s.startsWith('https://')) {
      final base = Uri.tryParse(def.baseUrl);
      if (base != null) s = base.resolve(s).toString();
    }
    final uri = Uri.tryParse(s);
    if (uri == null) return s;
    var path = uri.path;
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    return path;
  }

  String _abs(String fromUrl, String url) {
    final u = url.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('http://') || u.startsWith('https://') || u.startsWith('data:')) {
      return u;
    }
    final base = Uri.tryParse(fromUrl);
    if (base == null) return u;
    if (u.startsWith('//')) return '${base.scheme}:$u';
    if (u.startsWith('/')) {
      return '${base.scheme}://${base.authority}$u';
    }
    return base.resolve(u).toString();
  }
}