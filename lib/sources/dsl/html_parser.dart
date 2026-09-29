/// 纯 Dart 迷你 HTML 解析器（零第三方依赖）。
///
/// 只为「自定义源 DSL」服务，不追求完整 HTML5 规范：
/// - 正确处理成对标签、自闭合标签（br/img/input/meta/link/hr 等 + `<xxx/>`）、
///   单/双引号/无引号属性、注释、script/style 内容（保留但标记为脚本节点，
///   选择器匹配时默认跳过，避免脚本字符串污染查询结果）。
/// - 产出轻量节点树 [HtmlNode]，配合 lib/sources/dsl/css_selector.dart 的
///   选择器查询使用。
library;

import 'css_selector.dart';
import '../source_result.dart';

/// 默认 parseHtml 输入上限（8 MB）。防第三方 DSL 源抓到超大页面让主
/// Isolate 解析时长时间挂起（ReDoS 之外最常见的解析 DoS 面）。
const int kDefaultMaxHtmlBytes = 8 * 1024 * 1024;

/// 安全构造 RegExp：pattern 非法（如 `[`）时抛 [SourceError.parse] 而非
/// 逃逸的 FormatException。DSL 里的正则字段是远端可控的，任何一处
/// `RegExp(xxx)` 都可能踩到用户粘贴的坏 pattern。
RegExp safeRegExp(String pattern, {bool dotAll = false}) {
  try {
    return dotAll ? RegExp(pattern, dotAll: true) : RegExp(pattern);
  } on FormatException catch (e) {
    throw SourceError.parse('非法正则：${e.message}');
  }
}

/// 校验 m3u8 重写的**替换值**是否安全。返回中文拒绝理由（null = 合法）。
///
/// 规则（值可以是主机名字符串如 "play.modujx16.com"，不必是完整 URL）：
/// 1. 若值里出现 `scheme://` 或 `scheme:` 形式，仅允许 http/https；
///    其他 scheme（file/data/folder/jar/ftp/gopher/ftps/smb/nfs）拒绝。
/// 2. 无 scheme 前缀的纯子串（主机名/端口/CORS）视为合法。
String? unsafeRewriteTarget(String v) {
  final t = v.trim();
  if (t.isEmpty) return null;
  // 黑名单 scheme：这些 scheme 无 `//`（如 data:、file: 无 // 时也危险），
  // 即使没有 `scheme://` 结构也要拒绝。其余无 `//` 的字符串（如
  // host.com:65）视为纯主机名/端口替换，放行。
  const bad = ['file', 'data', 'javascript', 'vbscript', 'folder', 'ftp'];
  final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):', caseSensitive: false)
      .firstMatch(t);
  if (m != null) {
    final scheme = m.group(1)!.toLowerCase();
    if (bad.contains(scheme)) {
      return '禁止 scheme $scheme（仅允许 http/https）';
    }
    // scheme:// 形式的非 http(s) 网络 scheme（如 gopher://、ws://）也拒绝；
    // 无 `//` 的（host.com:65）按纯主机名放行。
    if (t.length > m.end && t.startsWith('//', m.end)) {
      if (scheme != 'http' && scheme != 'https') {
        return '禁止 scheme $scheme（仅允许 http/https）';
      }
    }
  }
  return null;
}

/// HTML 节点：标签节点或文本节点。
class HtmlNode {
  /// 小写标签名；文本节点为空字符串。
  final String tag;

  /// 属性表（键小写，值保持原文）。
  final Map<String, String> attrs;

  /// 子节点（含文本节点）。
  final List<HtmlNode> children = [];

  /// 父节点（root 为 null）。
  HtmlNode? parent;

  /// 文本节点内容（tag 为空串时有效）。
  String text;

  /// 是否 script/style 节点（内容被包装为文本，不参与元素选择）。
  bool scriptLike;

  HtmlNode(this.tag, this.attrs, {this.text = '', this.scriptLike = false});

  bool get isText => tag.isEmpty;

  /// 首个同名子元素（非文本）。
  HtmlNode? firstChild(String tag) {
    for (final c in children) {
      if (!c.isText && c.tag == tag) return c;
    }
    return null;
  }

  /// 直接子元素列表。
  List<HtmlNode> get elementChildren =>
      children.where((c) => !c.isText).toList();

  /// 子树内全部元素（深度优先，用于后代选择器）。
  List<HtmlNode> descendants() {
    final out = <HtmlNode>[];
    void walk(HtmlNode n) {
      for (final c in n.children) {
        if (c.isText) continue;
        out.add(c);
        walk(c);
      }
    }

    walk(this);
    return out;
  }

  /// 子元素中选择器匹配结果。
  List<HtmlNode> querySelectorAll(String selector) {
    final s = CssSelector.parse(selector);
    if (s == null) return const [];
    final r = <HtmlNode>[];
    void walk(HtmlNode n) {
      for (final c in n.children) {
        if (c.isText || c.scriptLike) continue;
        if (s.matches(c)) r.add(c);
        walk(c);
      }
    }

    walk(this);
    return r;
  }

  /// 拼接元素内可见文本（去除 script/style）。
  String get innerText {
    final sb = StringBuffer();
    void walk(HtmlNode n) {
      for (final c in n.children) {
        if (c.isText) {
          sb.write(c.text);
        } else if (!c.scriptLike) {
          walk(c);
        }
      }
    }

    walk(this);
    return htmlUnescape(sb.toString());
  }

  HtmlNode copyShallow() =>
      HtmlNode(tag, Map<String, String>.from(attrs), text: text);
}

/// 解析 HTML 字符串为节点树。解析失败/空串返回空 root。
///
/// [maxBytes] 限制输入字符串长度（按字符计数），超过时抛
/// [SourceError.parse]。默认 8 MB；调用方如需更紧/更松可覆盖。
/// 第三方 DSL 源抓到的页面完全远端可控，超长输入会让解析阶段卡住主
/// Isolate，因此这里做硬上限。
HtmlNode parseHtml(String html, {int maxBytes = kDefaultMaxHtmlBytes}) {
  if (html.length > maxBytes) {
    throw SourceError.parse('页面过大（${html.length} > $maxBytes 字符），已拒绝解析');
  }
  final root = HtmlNode('', const {});
  final stack = <HtmlNode>[];
  var pos = 0;
  final len = html.length;

  // 常见自闭合标签
  const voidTags = {
    'br', 'img', 'hr', 'input', 'meta', 'link', 'area', 'base', 'col',
    'embed', 'source', 'track', 'wbr', '!doctype',
  };

  void appendText(String t) {
    if (t.isEmpty) return;
    final top = stack.isEmpty ? root : stack.last;
    top.children.add(HtmlNode('', const {}, text: t)
      ..parent = top);
  }

  while (pos < len) {
    final lt = html.indexOf('<', pos);
    if (lt < 0) {
      appendText(html.substring(pos));
      break;
    }
    if (lt > pos) appendText(html.substring(pos, lt));
    // 找标签结束位置（考虑引号内 > ）
    var gt = lt + 1;
    var inQuote = '';
    while (gt < len) {
      final ch = html[gt];
      if (inQuote.isNotEmpty) {
        if (ch == inQuote) inQuote = '';
      } else if (ch == '"' || ch == "'") {
        inQuote = ch;
      } else if (ch == '>') {
        break;
      }
      gt++;
    }
    if (gt >= len) {
      // 未闭合：按文本吞掉
      appendText(html.substring(lt));
      break;
    }
    final raw = html.substring(lt + 1, gt);
    pos = gt + 1;

    if (raw.startsWith('!--')) {
      // 注释：raw 已止于第一个 '>'（即 --> 的尾部）。若 raw 末尾是 '--' 则注释已闭合，
      // 否则继续找 '-->' 吞掉（注释内容可能含 '>'）。
      if (raw.endsWith('--')) {
        continue;
      }
      final end = html.indexOf('-->', pos);
      if (end >= 0) {
        pos = end + 3;
      } else {
        break;
      }
      continue;
    }
    if (raw.startsWith('!') || raw.startsWith('?')) continue; // doctype/声明忽略

    // 闭合标签：`</tag>` 必须优先判断（不能先 indexOf 分隔，否则 / 会被当成标签名分隔符）
    if (raw.startsWith('/')) {
      final closeName = raw.substring(1).toLowerCase().trim();
      if (closeName.isNotEmpty) {
        for (var i = stack.length - 1; i >= 0; i--) {
          if (stack[i].tag == closeName) {
            stack.removeRange(i, stack.length);
            break;
          }
        }
      }
      continue;
    }

    final tagEnd = raw.indexOf(RegExp(r'[\s/>]'));
    final tagName = (tagEnd < 0 ? raw : raw.substring(0, tagEnd))
        .toLowerCase()
        .trim();
    if (tagName.isEmpty) continue;

    final isVoid = voidTags.contains(tagName) || raw.endsWith('/');
    final node = HtmlNode(tagName, <String, String>{});
    // 解析属性
    _parseAttrs(raw, tagEnd < 0 ? raw.length : tagEnd, node.attrs);
    if (isVoid) {
      final top = stack.isEmpty ? root : stack.last;
      top.children.add(node..parent = top);
    } else {
      final top = stack.isEmpty ? root : stack.last;
      top.children.add(node..parent = top);
      if (tagName == 'script' || tagName == 'style') {
        // 脚本/样式：剩余到结束标签作为文本内容，不建子节点树
        node.scriptLike = true;
        final closeRe = RegExp('</$tagName\\s*>', caseSensitive: false);
        final m = closeRe.firstMatch(html.substring(pos));
        if (m != null) {
          node.text = html.substring(pos, pos + m.start);
          node.children.add(HtmlNode('', const {}, text: node.text)
            ..parent = node);
          pos += m.end;
        } else {
          // 脚本/样式未闭合（真实站点偶发）：把剩余内容按文本吞掉即可，
          // 继续解析后续内容——直接 break 会丢掉整份剩余文档。
          node.text = html.substring(pos);
          node.children.add(HtmlNode('', const {}, text: node.text)
            ..parent = node);
          pos = html.length;
        }
      } else {
        stack.add(node);
      }
    }
  }
  return root;
}

/// 解析标签体 [raw]（不含 < >）的属性，写入 [out]。
/// [nameEnd] 是标签名结束位置（用于跳过标签名）。
void _parseAttrs(String raw, int nameEnd, Map<String, String> out) {
  final re = RegExp(r'''([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?''');
  for (final m in re.allMatches(raw.substring(nameEnd))) {
    final key = m.group(1)!;
    final val = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
    out[key.toLowerCase()] = htmlUnescape(val);
  }
}

/// 常见命名实体表（站点高频字符）。
const Map<String, String> _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00a0',
  'hellip': '\u2026',
  'mdash': '\u2014',
  'ndash': '\u2013',
  'lsquo': '\u2018',
  'rsquo': '\u2019',
  'ldquo': '\u201c',
  'rdquo': '\u201d',
  'times': '\u00d7',
  'divide': '\u00f7',
  'middot': '\u00b7',
  'trade': '\u2122',
  'copy': '\u00a9',
  'reg': '\u00ae',
  'laquo': '\u00ab',
  'raquo': '\u00bb',
  'deg': '\u00b0',
  'plusmn': '\u00b1',
  'prime': '\u2032',
};

final RegExp _numDecEntityRe = RegExp(r'&#([0-9]+);');
final RegExp _numHexEntityRe = RegExp(r'&#x([0-9a-fA-F]+);');
final RegExp _namedEntityRe = RegExp(r'&([a-zA-Z]+);');

/// 解码 HTML 实体（数字十进制 / 十六进制 / 命名），单次扫描不回溯。
///
/// 鞍山影院等站点全页用数字实体转义中文（`&#28909;&#37324;`），
/// 不解码则列表标题与详情字段都是乱码数字串。
String htmlUnescape(String s) {
  if (s.isEmpty || !s.contains('&')) return s;
  s = s.replaceAllMapped(_numDecEntityRe, (m) {
    final code = int.tryParse(m.group(1)!);
    return (code == null || code > 0x10ffff) ? m.group(0)! : String.fromCharCode(code);
  });
  s = s.replaceAllMapped(_numHexEntityRe, (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return (code == null || code > 0x10ffff) ? m.group(0)! : String.fromCharCode(code);
  });
  return s.replaceAllMapped(_namedEntityRe, (m) {
    final v = _namedEntities[m.group(1)!.toLowerCase()];
    return v ?? m.group(0)!;
  });
}