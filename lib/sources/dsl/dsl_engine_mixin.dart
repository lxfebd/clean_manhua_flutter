import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../net/aes_cbc.dart';
import '../../net/error_logger.dart';
import '../source_http.dart';
import '../source_result.dart';
import 'custom_source_def.dart';
import 'html_parser.dart';

/// 自定义源 JSON DSL 的共享解析引擎（comic/video/novel 三源逐字节相同的
/// 抓取与字段抽取方法收拢于此，消除三份拷贝）。
///
/// 抽取范围只含「工具方法」：网络抓取、URL 组装、HTML 字段抽取、列表元素
/// 定位（CSS/正则 → 虚拟节点）。各源自身的业务方法（categories/list/detail
/// 的规则编排）仍留在各自类里，调用这些工具完成抓取与抽取。
mixin DslEngineMixin {
  /// 当前 DSL 定义（各源持有）。
  CustomSourceDef get def;

  /// 抓取并按 [decrypt] 解码页面文本。统一出口：所有网络都在这里，失败抛 SourceError。
  ///
  /// [tag] 是日志标签（如 `dsl-comic`），区分三源。
  ///
  /// R3（P1-16）：统一走 [SourceHttp.getUrl]——完整 URL + 配置（hostsFor/
  /// 单源代理）+ 熔断 + 瞬时失败重试都不再绕过。内部 [Net.getCronet] 的
  /// Cronet 优先逻辑保留在 Net 层（代理场景自动跳 dart:io）。
  Future<String> fetchHtml(
    String url,
    String? page,
    String? decrypt,
    String id,
    String tag,
  ) async {
    final u = url.replaceAll('{id}', id).replaceAll('{page}', page ?? '1');
    try {
      final html = await SourceHttp.getUrl(
        def.id,
        u,
        headers: def.headers,
      );
      if (decrypt == null || decrypt.isEmpty) return html;
      return DslDecrypt.apply(decrypt, html);
    } on SourceError {
      rethrow;
    } catch (e) {
      // 统一归约为结构化错误（与 [withCircuit] 同语义），原错进日志。
      ErrorLogger.instance.warn('[$tag] fetch failed ($id): $e');
      if (e is SocketException || e is TimeoutException) {
        throw SourceError.network('网络请求失败，请检查网络后重试');
      }
      if (e is FormatException) throw SourceError.parse('页面数据解析失败');
      if (e is HttpException) throw SourceError.service('站点服务异常');
      throw SourceError.unknown('请求失败');
    }
  }

  /// 组装分页 URL：替换 {page} 与可选 {keyword}。
  String pageUrl(String url, String? categoryId, int page,
      {String? keyword}) {
    return url
        .replaceAll('{page}', '$page')
        .replaceAll('{categoryId}', categoryId ?? '')
        .replaceAll('{keyword}', Uri.encodeQueryComponent(keyword ?? ''));
  }

  /// 从链接里抽取条目 id：相对路径补 [CustomSourceDef.baseUrl]，返回
  /// 去掉前导斜杠的路径（{id} 由详情/章节图 URL 模板自行拼接）。
  String extractId(String href, String fallbackId) {
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

  /// 相对 URL 解析为绝对地址（兼容 // 协议相对与 / 根相对）。
  String abs(String fromUrl, String url) {
    final u = url.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('http://') || u.startsWith('https://') ||
        u.startsWith('data:')) {
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

  /// 顺次应用替换规则（如 CDN 域名替换）。
  String applyReplace(String s, Map<String, String>? rules) {
    if (rules == null || rules.isEmpty) return s;
    var out = s;
    rules.forEach((k, v) {
      out = out.replaceAll(k, v);
    });
    return out;
  }

  /// 统一字段抽取。规则字段值支持三种形态：
  /// - `selector|attr`：先按选择器取子元素，再取该元素属性（如 `img|src`、`a|href`）；
  /// - 纯属性名且条目元素直接拥有（如 `href`、`data-id`）；
  /// - 选择器（标签/类/id/属性）：取第一个匹配子元素的文本；空 → 条目自身文本。
  String extract(HtmlNode e, String field) {
    final f = field.trim();
    if (f.isEmpty) return e.innerText.trim();
    if (f.contains('|')) {
      final idx = f.indexOf('|');
      final sel = f.substring(0, idx).trim();
      final attr = f.substring(idx + 1).trim();
      final sub = firstSub(e, sel);
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

  /// 在元素内按选择器查第一个匹配（后代任意层级）。
  HtmlNode? firstSub(HtmlNode e, String selector) {
    final list = e.querySelectorAll(selector);
    return list.isEmpty ? null : list.first;
  }

  /// 取元素属性（小写键）；选择器形式原样返回空，交给 [extract] 处理文本。
  String attr(HtmlNode e, String field) {
    if (field.isEmpty) return '';
    return e.attrs[field.toLowerCase()] ?? '';
  }

  /// 可选字段抽取（String?），空返回 ''。
  String opt(HtmlNode e, String? field) {
    if (field == null || field.isEmpty) return '';
    return extract(e, field);
  }

  /// 在 [root] 中按 [selector] 取首个元素，再按 [attr] 取属性（空则取文本）。
  String queryAttr(HtmlNode root, String selector, String attr) {
    if (selector.isEmpty) return '';
    final els = root.querySelectorAll(selector);
    if (els.isEmpty) return '';
    if (attr.isNotEmpty) return els.first.attrs[attr.toLowerCase()] ?? '';
    return els.first.innerText.trim();
  }

  /// 取 [root] 中首个匹配 [selector] 的文本。
  String queryText(HtmlNode root, String selector) {
    if (selector.isEmpty) return '';
    final els = root.querySelectorAll(selector);
    if (els.isEmpty) return '';
    return els.first.innerText.trim();
  }

  /// 通用「查询→映射」执行器：抓取、解码、按 CSS/正则定位元素、应用映射。
  ///
  /// 正则行式把每个匹配包装成虚拟节点（attrs['r1']..'rn' = 捕获组），
  /// 供 [map] 复用统一抽取逻辑。
  Future<T> runRule<T>(
    String url,
    DslListRule rule,
    T Function(List<HtmlNode>) map,
    T Function(List<HtmlNode>) empty,
    String tag,
  ) async {
    final html = await fetchHtml(url, null, rule.decrypt, '', tag);
    final root = parseHtml(html);
    List<HtmlNode> els;
    if (rule.selector.isNotEmpty) {
      els = root.querySelectorAll(rule.selector);
    } else if (rule.regex.isNotEmpty) {
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
    return els.isEmpty ? empty(els) : map(els);
  }
}

/// 网页抓取后的响应解码链（Base64/Hex/AES/替换/URI 解码/正则替换）。
/// 由 DSL 的 `decrypt` 字段声明，幂等组合。
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
          final re = safeRegExp(body.substring(0, sepIdx), dotAll: true);
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

/// 正则匹配串抽取：优先命名组（`(?<name>...)`），不存在时回退按位取 [position]。
/// DSL 的 `chaptersRe`/`chapters` 规则可能给出顺序不确定的捕获组（如
/// `<a href="...">标题</a>` 既有 href 又有标题），命名组让规则作者明确声明
/// 各字段，避免依赖组顺序。
String dslGroup(RegExpMatch m, RegExp re, String name, int position) {
  if (re.pattern.contains('?<$name>')) {
    try {
      final v = m.namedGroup(name);
      if (v != null) return v;
    } catch (_) {
      // 该命名组不存在（pattern 变体差异），回退按位
    }
  }
  if (position <= m.groupCount) {
    final v = m.group(position);
    if (v != null) return v;
  }
  return '';
}
