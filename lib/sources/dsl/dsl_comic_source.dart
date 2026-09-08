import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/comic_item.dart';
import '../../net/aes_cbc.dart';
import '../../net/http_client.dart';
import '../comic_source.dart';
import '../source_config.dart';
import '../source_result.dart';
import 'custom_source_def.dart';
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
class DslComicSource extends ComicSource {
  final CustomSourceDef def;

  DslComicSource(this.def);

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

  // ---- 分类 ----
  @override
  Future<List<Category>> categories() async {
    final rule = def.categoriesRule;
    final url = def.categoriesUrl;
    if (rule == null || url == null) return const [];
    return _runRule(url, rule, (els) {
      final list = <Category>[];
      for (final e in els) {
        final href = _attr(e, rule.url.isNotEmpty ? rule.url : 'href');
        final name = rule.itemName != null && rule.itemName!.isNotEmpty
            ? _attr(e, rule.itemName!)
            : e.innerText.trim();
        final id = rule.itemUrl != null && rule.itemUrl!.isNotEmpty
            ? _attr(e, rule.itemUrl!)
            : href;
        list.add(Category(id.isEmpty ? href : id, name.isEmpty ? href : name));
      }
      return list;
    }, (_) => const <Category>[]);
  }

  // ---- 列表 / 排行 / 搜索 ----
  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final rule = def.categoryListRule;
    if (rule == null || def.categoryListUrl == null) return const [];
    final url = _pageUrl(def.categoryListUrl!, categoryId, page);
    return _list(url, rule);
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    final rule = def.rankRule;
    if (rule == null || def.rankUrl == null) return const [];
    return _list(_pageUrl(def.rankUrl!, null, page), rule);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    final rule = def.searchRule;
    if (rule == null || def.searchUrl == null) return const [];
    return _list(_pageUrl(def.searchUrl!, null, page, keyword: keyword), rule);
  }

  Future<List<ComicItem>> _list(String url, DslListRule rule) async {
    return _runRule(url, rule, (els) {
      final items = <ComicItem>[];
      for (final e in els) {
        final name = _extract(e, rule.name);
        if (name.isEmpty) continue;
        final id = _extractId(_extract(e, rule.id), '');
        if (id.isEmpty) continue;
        final pic = _extract(e, rule.pic);
        items.add(ComicItem(id, name, pic.isEmpty ? '' : _abs(url, pic))
          ..yname = _opt(e, rule.yname)
          ..score = _opt(e, rule.score)
          ..hits = _opt(e, rule.hits)
          ..rank = _opt(e, rule.rank)
          ..author = _opt(e, rule.author)
          ..content = _opt(e, rule.content)
          ..picFallback = (rule.picFallback?.isNotEmpty ?? false)
              ? _abs(url, _extract(e, rule.picFallback ?? ''))
              : null);
      }
      return items;
    }, (els) => const []);
  }

  // ---- 详情 ----
  @override
  Future<ComicDetail> detail(String comicId) async {
    final d = def.detailRule;
    if (d == null || def.detailUrl == null) {
      throw SourceError.service('该源未配置详情页规则');
    }
    final html = await _fetch(def.detailUrl!, null, d.baseDecrypt, comicId);
    final root = parseHtml(html);
    final cover = _queryAttr(root, d.cover, d.coverAttr, d.baseUrl);
    final item = ComicItem(comicId, d.title.isNotEmpty ? _queryText(root, d.title) : '', cover.isEmpty ? '' : _abs(def.detailUrl!, cover))
      ..author = _queryText(root, d.author)
      ..content = _queryText(root, d.description);

    // 章节：CSS 选择器抽取，或正则
    final chapters = <Chapter>[];
    if (d.chapters.isNotEmpty) {
      final nodes = root.querySelectorAll(d.chapters);
      final hrefRe = d.chapterUrlRe.isNotEmpty
          ? RegExp(d.chapterUrlRe)
          : null;
      for (final n in nodes) {
        var href = _attr(n, d.chapterUrl);
        if (href.isEmpty && hrefRe != null) {
          final m = hrefRe.firstMatch(n.innerText);
          if (m != null) href = m.group(1) ?? m.group(0)!;
        }
        if (href.isEmpty) continue;
        final cid = _extractId(href, comicId);
        if (cid.isEmpty) continue;
        final title = _attr(n, d.chapterTitle).isNotEmpty
            ? _attr(n, d.chapterTitle)
            : n.innerText.trim();
        if (title.isEmpty) continue;
        chapters.add(Chapter(cid, title));
      }
    }
    if (chapters.isEmpty && d.chaptersRe.isNotEmpty) {
      final re = RegExp(d.chaptersRe);
      for (final m in re.allMatches(html)) {
        final title = m.group(1) ?? '';
        final href = m.group(2) ?? '';
        if (title.isEmpty || href.isEmpty) continue;
        final cid = _extractId(href, comicId);
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
    final html = await _fetch(d.picListUrl, null, d.picListDecrypt, chapterId);
    final root = parseHtml(html);
    final nodes = d.picListCss.isNotEmpty
        ? root.querySelectorAll(d.picListCss)
        : <HtmlNode>[];
    final urls = <String>[];
    if (nodes.isNotEmpty) {
      for (final n in nodes) {
        var u = _attr(n, d.picAttr);
        if (u.isEmpty) u = n.attrs['src'] ?? '';
        if (u.isEmpty) u = n.innerText.trim();
        if (u.isNotEmpty) urls.add(u);
      }
    } else if (d.picListRe.isNotEmpty) {
      final re = RegExp(d.picListRe);
      for (final m in re.allMatches(html)) {
        final u = m.group(1) ?? '';
        if (u.isNotEmpty) urls.add(u);
      }
    }
    // 过滤 + 修正
    final filtered = <String>[];
    for (var u in urls) {
      if (d.picFilter.isNotEmpty) {
        if (!RegExp(d.picFilter).hasMatch(u)) continue;
      }
      u = _applyReplace(u, d.picReplace);
      if (u.isNotEmpty && !filtered.contains(u)) filtered.add(_abs(d.picListUrl, u));
    }
    return filtered;
  }

  // ---- 工具 ----

  /// 抓取并按 [decrypt] 解码页面文本。统一出口：所有网络都在这里，失败抛 SourceError。
  Future<String> _fetch(String url, String? page, String? decrypt, String id) async {
    final u = url.replaceAll('{id}', id).replaceAll('{page}', page ?? '1');
    try {
      final html = await Net.get(u, headers: def.headers);
      if (decrypt == null || decrypt.isEmpty) return html;
      return DslDecrypt.apply(decrypt, html);
    } on SourceError {
      rethrow;
    } catch (e) {
      // 统一归约为结构化错误（对齐 runCatching 的语义）
      if (e is SocketException || e is TimeoutException) {
        throw SourceError.network('$e');
      }
      if (e is FormatException) throw SourceError.parse('$e');
      if (e is HttpException) throw SourceError.service('$e');
      throw SourceError.unknown('$e');
    }
  }
  /// 组装分页 URL：替换 {page} 与可选 {keyword}。
  String _pageUrl(String url, String? categoryId, int page, {String? keyword}) {
    return url
        .replaceAll('{page}', '$page')
        .replaceAll('{categoryId}', categoryId ?? '')
        .replaceAll('{keyword}', Uri.encodeQueryComponent(keyword ?? ''));
  }

  String _extractId(String href, String comicId) {
    var s = href.trim();
    if (s.isEmpty) return '';
    // 相对路径 → 补 baseUrl（保留 query）
    if (s.startsWith('/')) {
      s = '${def.baseUrl}$s';
    } else if (!s.startsWith('http://') && !s.startsWith('https://')) {
      final base = Uri.tryParse(def.baseUrl);
      if (base != null) s = base.resolve(s).toString();
    }
    final uri = Uri.tryParse(s);
    if (uri == null) return s;
    // 返回去掉前导斜杠的路径：{id} 由详情/章节图 URL 模板自行拼接。
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

  String _applyReplace(String s, Map<String, String>? rules) {
    if (rules == null || rules.isEmpty) return s;
    var out = s;
    rules.forEach((k, v) {
      out = out.replaceAll(k, v);
    });
    return out;
  }

  /// 统一字段抽取：规则字段值可以是——
  /// - 属性名（如 'href' / 'src' / 'data-id'）：取元素该属性；
  /// - 子选择器（以 `.` / `#` / `[` / 标签 开头）：在元素内做子查询取首匹配；
  /// - 空：取元素文本（innerText）。
  /// 统一字段抽取。规则字段值支持三种形态：
/// - `selector|attr`：先按选择器取子元素，再取该元素属性（如 `img|src`、`a|href`）；
/// - 纯属性名且条目元素直接拥有（如 `href`、`data-id`）；
/// - 选择器（标签/类/id/属性）：取第一个匹配子元素的文本；空 → 条目自身文本。
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

  // 在元素内按选择器查第一个匹配（后代任意层级）
  HtmlNode? _firstSub(HtmlNode e, String selector) {
    final list = e.querySelectorAll(selector);
    return list.isEmpty ? null : list.first;
  }

  // 取元素属性（小写键）；选择器形式原样返回空，交给 _extract 处理文本
  String _attr(HtmlNode e, String field) {
    if (field.isEmpty) return '';
    return e.attrs[field.toLowerCase()] ?? '';
  }

  // 可选字段抽取（String?），空返回 ''
  String _opt(HtmlNode e, String? field) {
    if (field == null || field.isEmpty) return '';
    return _extract(e, field);
  }

  /// 在 [root] 中按 [selector] 取首个元素，再按 [attr] 取属性（空则取文本）。
  String _queryAttr(HtmlNode root, String selector, String attr, String fallbackUrl) {
    if (selector.isEmpty) return '';
    final els = root.querySelectorAll(selector);
    if (els.isEmpty) return '';
    if (attr.isNotEmpty) return els.first.attrs[attr.toLowerCase()] ?? '';
    return els.first.innerText.trim();
  }

  String _queryText(HtmlNode root, String selector) {
    if (selector.isEmpty) return '';
    final els = root.querySelectorAll(selector);
    if (els.isEmpty) return '';
    return els.first.innerText.trim();
  }

  /// 通用「查询→映射」执行器：抓取、解码、按 CSS/正则定位元素、应用映射。
  Future<T> _runRule<T>(
    String url,
    DslListRule rule,
    T Function(List<HtmlNode>) map,
    T Function(List<HtmlNode>) empty,
  ) async {
    final html = await _fetch(url, null, rule.decrypt, '');
    final root = parseHtml(html);
    List<HtmlNode> els;
    if (rule.selector.isNotEmpty) {
      els = root.querySelectorAll(rule.selector);
    } else if (rule.regex.isNotEmpty) {
      // 正则行式：把每个匹配包装成虚拟节点，供 map 复用统一抽取逻辑
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
        final n = HtmlNode('', const {}, text: g.join('|'));
        for (var i = 0; i < g.length; i++) {
          n.attrs['r${i + 1}'] = g[i];
        }
        return n;
      }).toList();
    } else {
      els = const [];
    }
    return els.isEmpty ? empty(els) : map(els);
  }
}

/// 网页抓取：直接使用全局 Net（http_client.dart），统一走代理/降级链。
///
/// 简易站点名 → 头部附加（UA）。
class DslDecrypt {
  static String apply(String spec, String input) {
    final parts = spec.split('|');
    var out = input;
    for (final p in parts) {
      final t = p.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('b64')) {
        out = utf8.decode(base64Decode(out));
      } else if (t.startsWith('hex')) {
        out = utf8.decode(_hexToBytes(out));
      } else if (t.startsWith('aes:')) {
        final rest = t.substring(4).split(',');
        final key = utf8.encode(rest.isEmpty ? '' : rest[0]);
        final iv = rest.length > 1 ? utf8.encode(rest[1]) : key;
        final raw = base64Decode(out);
        final dec = AesCbc.decryptCbc(raw, key, iv);
        out = utf8.decode(dec, allowMalformed: true);
      } else if (t.startsWith('replace:')) {
        final kv = t.substring(8);
        final idx = kv.indexOf('>');
        if (idx > 0) {
          out = out.replaceAll(kv.substring(0, idx), kv.substring(idx + 1));
        }
      } else if (t.startsWith('decode:')) {
        out = Uri.decodeComponent(out);
      } else if (t.startsWith('re:')) {
        final body = t.substring(3);
        final sepIdx = body.indexOf('|');
        if (sepIdx > 0) {
          final re = RegExp(body.substring(0, sepIdx), dotAll: true);
          final rep = body.substring(sepIdx + 1);
          out = out.replaceAll(re, rep);
        }
      }
    }
    return out;
  }

  static Uint8List _hexToBytes(String hex) {
    final s = hex.replaceAll(' ', '');
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i + 1 < s.length; i += 2) {
      out[i ~/ 2] = int.parse(s.substring(i, i + 2), radix: 16);
    }
    return out;
  }
}