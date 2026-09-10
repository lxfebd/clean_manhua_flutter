import 'dart:async';
import 'dart:io';

import '../../models/comic_item.dart';
import '../../net/http_client.dart';
import '../comic_source.dart' show Category;
import '../source_result.dart';
import '../video_source.dart';
import 'custom_source_def.dart';
import 'dsl_comic_source.dart' show DslDecrypt, dslGroup;
import 'html_parser.dart';

/// 自定义源 JSON DSL 的视频源实现。
///
/// 复用 [CustomSourceDef] 的 DSL 规则（分类/列表/搜索/详情）+ 通用解码链
/// （AES/Base64/替换），实现 [VideoSource] 接口。字段命名约定与
/// [DslComicSource] 完全一致，语义对齐：
/// - `categoryList` → [listByCategory]；`search` → [search]；
/// - `detail.title/cover/author/description/area/type/status` → 详情元信息；
/// - `detail.chapters`（CSS 选择器）→ 主线路剧集列表；
/// - `detail.chaptersRe`（正则）→ 剧集列表，组 1 = 标题、组 2 = 链接
///   （提取其中第一个数字作为集号）、可选组 3 = 线路号（如 S1 / 线路1），
///   线路号同时填充 [VideoDetail.sourceNames]；
/// - `detail.picListUrl` 复用为「播放地址」规则：请求该页后按
///   `picListCss`（取 [picAttr] 属性，默认 `src`）/ `picListRe`（组 1 = 地址）
///   抽取，结果第一个为可直接播放的 URL（m3u8/mp4/iframe 解析器页均可）。
///
/// 网络统一走全局 Net（http_client.dart），与内置视频源行为一致。
class DslVideoSource implements VideoSource {
  final CustomSourceDef def;

  DslVideoSource(this.def);

  @override
  String get id => def.id;

  @override
  String get name => def.name;

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

  // ---- 列表 / 搜索 ----
  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final rule = def.categoryListRule;
    if (rule == null || def.categoryListUrl == null) return const [];
    final url = _pageUrl(def.categoryListUrl!, categoryId, page);
    return _list(url, rule);
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
  Future<VideoDetail> detail(String videoId) async {
    final d = def.detailRule;
    if (d == null || def.detailUrl == null) {
      throw SourceError.service('该源未配置详情页规则');
    }
    final html = await _fetch(def.detailUrl!, null, d.baseDecrypt, videoId);
    final root = parseHtml(html);
    final cover = _queryAttr(root, d.cover, d.coverAttr, d.baseUrl);
    final item = ComicItem(
      videoId,
      d.title.isNotEmpty ? _queryText(root, d.title) : '',
      cover.isEmpty ? '' : _abs(def.detailUrl!, cover),
    )
      ..author = _queryText(root, d.author)
      ..content = _queryText(root, d.description)
      ..remarks = _queryText(root, d.status);
    final type = _queryText(root, d.type);
    final area = _queryText(root, d.area);

    final episodes = <VideoEpisode>[];
    final seen = <String>{};
    // 主线路：CSS 选择器抽取
    final nodes = d.chapters.isNotEmpty
        ? root.querySelectorAll(d.chapters)
        : <HtmlNode>[];
    for (final n in nodes) {
      final href = _epHref(n, d);
      if (href.isEmpty) continue;
      final idx = _epIndex(href);
      if (idx < 0) continue;
      // chapterTitle 留空时用链接文本（与 ComicSource 章节解析一致）
      final raw = d.chapterTitle.isEmpty
          ? n.innerText.trim()
          : _extract(n, d.chapterTitle);
      final label = raw.isEmpty ? '第${_pad(idx)}集' : raw;
      final key = '1-$idx';
      if (seen.add(key)) episodes.add(VideoEpisode(1, idx, label));
    }
    // 或 chaptersRe 正则（组1=标题 组2=链接 可选组3=线路号；支持命名组）
    Map<int, String>? sourceNames;
    if (episodes.isEmpty && d.chaptersRe.isNotEmpty) {
      final re = RegExp(d.chaptersRe);
      final names = <int, String>{};
      for (final m in re.allMatches(html)) {
        final href = dslGroup(m, re, 'href', 2);
        if (href.isEmpty) continue;
        final title = dslGroup(m, re, 'title', 1);
        if (title.isEmpty) continue;
        final seasonRaw = dslGroup(m, re, 'season', m.groupCount >= 3 ? 3 : 0);
        final season = _seasonNum(seasonRaw.trim());
        final idx = _epIndex(href);
        if (idx < 0) continue;
        final key = '$season-$idx';
        if (seen.add(key)) {
          episodes.add(VideoEpisode(season, idx, title.trim()));
        }
        if (seasonRaw.trim().isNotEmpty) {
          names.putIfAbsent(season, () => seasonRaw.trim());
        }
      }
      if (names.isNotEmpty) sourceNames = names;
    }
    episodes.sort((a, b) => a.season == b.season
        ? a.episode.compareTo(b.episode)
        : a.season.compareTo(b.season));

    return VideoDetail(
      item,
      episodes,
      description: item.content,
      cover: cover.isEmpty ? null : item.pic,
      area: area.isEmpty ? null : area,
      type: type.isEmpty ? null : type,
      sourceNames: sourceNames,
    );
  }

  // 单行取章的 href：优先按 chapterUrlRe 从文章文本抽，再按 chapterUrl 属性。
  String _epHref(HtmlNode n, DslDetailRule d) {
    var href = _attr(n, d.chapterUrl);
    if (href.isEmpty && d.chapterUrlRe.isNotEmpty) {
      final m = RegExp(d.chapterUrlRe).firstMatch(n.innerText);
      if (m != null) href = m.group(1) ?? m.group(0)!;
    }
    return href;
  }

  // 按 href 里最后一个数字取集号（如 /play/{videoId}/{ep}.html → ep；
  // -1 = 取不到）。
  int _epIndex(String href) {
    final re = RegExp(r'(\d+)');
    int? last;
    for (final m in re.allMatches(href)) {
      last = int.tryParse(m.group(1) ?? '');
    }
    return last ?? -1;
  }

  // 抽取线路号：纯数字直接用；含 's'/'线路'/'第' 则取其后的数字。
  int _seasonNum(String raw) {
    if (raw.isEmpty) return 1;
    final direct = int.tryParse(raw);
    if (direct != null) return direct < 1 ? 1 : direct;
    final m = RegExp(r'(\d+)').firstMatch(raw);
    return m == null ? 1 : (int.tryParse(m.group(1) ?? '1') ?? 1);
  }

  // ---- 播放地址（复用「章节图」规则）----
  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    final d = def.detailRule;
    if (d == null || d.picListUrl.isEmpty) {
      throw SourceError.service('该源未配置播放地址规则（picListUrl）');
    }
    final seasonUrl = d.picListUrl
        .replaceAll('{season}', '$season')
        .replaceAll('{episode}', '$episode');
    final html = await _fetch(seasonUrl, '$episode', d.picListDecrypt, videoId);
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
    final filtered = <String>[];
    for (var u in urls) {
      if (d.picFilter.isNotEmpty) {
        if (!RegExp(d.picFilter).hasMatch(u)) continue;
      }
      u = _applyReplace(u, d.picReplace);
      if (u.isNotEmpty) filtered.add(_abs(seasonUrl, u));
    }
    if (filtered.isEmpty) {
      throw SourceError.parse('未匹配到播放地址');
    }
    return filtered.first;
  }

  // ---- 工具 ----
  Future<String> _fetch(String url, String? page, String? decrypt, String id) async {
    final u = url.replaceAll('{id}', id).replaceAll('{page}', page ?? '1');
    try {
      final html = await Net.get(u, headers: def.headers);
      if (decrypt == null || decrypt.isEmpty) return html;
      return DslDecrypt.apply(decrypt, html);
    } on SourceError {
      rethrow;
    } catch (e) {
      if (e is SocketException || e is TimeoutException) {
        throw SourceError.network('$e');
      }
      if (e is FormatException) throw SourceError.parse('$e');
      if (e is HttpException) throw SourceError.service('$e');
      throw SourceError.unknown('$e');
    }
  }

  String _pageUrl(String url, String? categoryId, int page, {String? keyword}) {
    return url
        .replaceAll('{page}', '$page')
        .replaceAll('{categoryId}', categoryId ?? '')
        .replaceAll('{keyword}', Uri.encodeQueryComponent(keyword ?? ''));
  }

  String _extractId(String href, String comicId) {
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

  String _applyReplace(String s, Map<String, String>? rules) {
    if (rules == null || rules.isEmpty) return s;
    var out = s;
    rules.forEach((k, v) {
      out = out.replaceAll(k, v);
    });
    return out;
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

  /// 通用「查询→映射」执行器：抓取、解码、按 CSS/正则定位元素，应用映射。
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
      // 正则行式：每个匹配包装成虚拟节点，供 map 复用统一抽取逻辑
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
    return els.isEmpty ? empty(els) : map(els);
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}
