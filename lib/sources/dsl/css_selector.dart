import 'html_parser.dart';

/// 迷你 CSS 选择器（零第三方依赖），供自定义源 DSL 查询 HTML。
///
/// 支持语法（对齐实际站点常见用法）：
/// - `div` / `ul li`：标签（后代用空格，限定任意深度）
/// - `.class` / `#id`
/// - `[href]` / `[href="x"]` / `[href^="x"]` / `[href$="x"]` / `[href*="x"]`
/// - 复合：`div.book-item a.title[href]`
///
/// 不支持：子选择器 `>`、相邻/兄弟、伪类、逗号分组（多选择器请拆多条规则，
/// 或 DSL 层用分号分隔后逐条查询）。
class CssSelector {
  /// 解析后的复合段列表（每段是一层，如 `div .item` → [div, .item]）。
  final List<Map<String, dynamic>> parts;

  const CssSelector(this.parts);

  /// 解析选择器字符串；语法错误返回 null。
  static CssSelector? parse(String selector) {
    final s = selector.trim();
    if (s.isEmpty) return null;
    final rawParts = s.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (rawParts.isEmpty) return null;
    final parts = <Map<String, dynamic>>[];
    for (final raw in rawParts) {
      final p = _parsePart(raw);
      if (p == null) return null;
      parts.add(p);
    }
    return CssSelector(parts);
  }

  static Map<String, dynamic>? _parsePart(String raw) {
    // 逐 token：标签、.class、#id、[attr...]
    final tag = <String>[];
    final classes = <String>[];
    String? id;
    final attrs = <Map<String, String>>[];

    var i = 0;
    var hasTag = false;
    while (i < raw.length) {
      final ch = raw[i];
      if (ch == '.') {
        final j = _scan(raw, i + 1, RegExp(r'[a-zA-Z0-9_-]'));
        if (j < 0) return null;
        classes.add(raw.substring(i + 1, j));
        i = j;
      } else if (ch == '#') {
        final j = _scan(raw, i + 1, RegExp(r'[a-zA-Z0-9_-]'));
        if (j < 0) return null;
        id = raw.substring(i + 1, j);
        i = j;
      } else if (ch == '[') {
        final end = raw.indexOf(']', i + 1);
        if (end < 0) return null;
        final body = raw.substring(i + 1, end).trim();
        final a = _parseAttr(body);
        if (a == null) return null;
        attrs.add(a);
        i = end + 1;
      } else if (ch == '>' || ch == '+' || ch == '~' || ch == ':') {
        return null; // 不支持
      } else {
        final j = _scan(raw, i, RegExp(r'[a-zA-Z0-9_-]'));
        if (j < 0) return null;
        tag.add(raw.substring(i, j));
        hasTag = true;
        i = j;
      }
    }
    return {
      'tag': hasTag ? tag.join().toLowerCase() : '',
      'class': classes,
      'id': id,
      'attrs': attrs,
    };
  }

  static int _scan(String s, int from, RegExp re) {
    var i = from;
    while (i < s.length && re.hasMatch(s[i])) {
      i++;
    }
    return i == from ? -1 : i;
  }

  static Map<String, String>? _parseAttr(String body) {
    final m = RegExp(
      r'''^([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*(?:([~*^$]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s]+)))?$''',
    ).firstMatch(body);
    if (m == null) return null;
    final key = m.group(1)!.toLowerCase();
    final op = m.group(2);
    final val = m.group(3) ?? m.group(4) ?? m.group(5) ?? '';
    return {'key': key, 'op': op ?? '', 'val': val};
  }

  /// 该节点是否命中选择器（多层段匹配整个祖先链）。
  bool matches(HtmlNode node) {
    if (parts.isEmpty) return false;
    // 从最内层段开始，沿祖先链匹配
    var cur = node;
    for (var k = parts.length - 1; k >= 0; k--) {
      if (k == parts.length - 1) {
        // 最内层段必须命中当前节点
        if (!_matchOne(cur, parts[k])) return false;
      } else {
        // 外层段：沿祖先链向上找一个命中的
        var ancestor = cur.parent;
        var found = false;
        while (ancestor != null) {
          if (_matchOne(ancestor, parts[k])) {
            found = true;
            cur = ancestor;
            break;
          }
          ancestor = ancestor.parent;
        }
        if (!found) return false;
      }
    }
    return true;
  }

  static bool _matchOne(HtmlNode node, Map<String, dynamic> part) {
    if (node.isText) return false;
    final tag = part['tag'] as String;
    if (tag.isNotEmpty && node.tag != tag) return false;
    final id = part['id'] as String?;
    if (id != null && (node.attrs['id'] ?? '') != id) return false;
    final classes = part['class'] as List<String>;
    if (classes.isNotEmpty) {
      final own = (node.attrs['class'] ?? '').split(RegExp(r'\s+'));
      for (final c in classes) {
        if (!own.contains(c)) return false;
      }
    }
    for (final a in part['attrs'] as List<Map<String, String>>) {
      if (!_matchAttr(node, a)) return false;
    }
    return true;
  }

  static bool _matchAttr(HtmlNode node, Map<String, String> a) {
    final key = a['key']!;
    final op = a['op']!;
    final val = a['val']!;
    final actual = node.attrs[key];
    if (actual == null) return false;
    switch (op) {
      case '':
        return true;
      case '=':
        return actual == val;
      case '^=':
        return actual.startsWith(val);
      case '\$=':
        return actual.endsWith(val);
      case '*=':
        return actual.contains(val);
      case '~=':
        return actual.split(RegExp(r'\s+')).contains(val);
      default:
        return false;
    }
  }
}