import '../models/comic_item.dart';
import 'comic_source.dart';
import 'source_http.dart';

/// 动漫屋源（www.dm5.com / m.dm5.com）。
///
/// 使用移动版 m.dm5.com 解析，章节图片通过内嵌 packer 混淆的 newImgs 数组获取。
/// 图片 CDN 直链，无需二次签名。
class Dm5Source extends ComicSource {
  static const String _base = 'https://m.dm5.com';

  @override
  String get id => 'dm5';
  @override
  String get name => '动漫屋';

  @override
  Future<List<Category>> categories() async => [
        Category('all', '全部'),
        Category('rexue', '热血'),
        Category('kehuan', '科幻'),
        Category('xuanhuan', '玄幻'),
        Category('xiuzhen', '修真'),
        Category('qinggan', '情感'),
        Category('xiju', '喜剧'),
        Category('xuanyi', '悬疑'),
        Category('kongbu', '恐怖'),
        Category('yanqing', '言情'),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    if (categoryId == 'all') {
      return rank(page);
    }
    return _parseSearchList(await SourceHttp.getUrl('dm5',
        '$_base/search?title=${Uri.encodeQueryComponent(categoryId)}&page=$page'));
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    final html = await SourceHttp.getUrl('dm5', '$_base/manhua-rank/?page=$page');
    return _parseRankList(html);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    return _parseSearchList(await SourceHttp.getUrl('dm5',
        '$_base/search?title=${Uri.encodeQueryComponent(keyword)}&page=$page'));
  }

  @override
  Future<ComicDetail> detail(String comicId) async {
    final body = await SourceHttp.getUrl('dm5', '$_base/manhua-$comicId/');
    var title = _first(_titleRe, body) ?? comicId;
    // 去掉 "漫画_30连载中_在线漫画_动漫屋" 尾巴
    title = title.split('漫画_').first.trim();
    if (title.isEmpty) title = comicId;
    // 封面选第一个 visible 漫画图片
    var cover = _first(_mhfmImgRe, body);
    cover ??= _first(_detailImgRe, body);
    var desc = _first(_descRe, body);
    // desc 两种属性顺序，取非空那个
    final dm = _descRe.firstMatch(body);
    if (dm != null) {
      desc = (dm.group(1)?.isNotEmpty ?? false) ? dm.group(1) : dm.group(2);
    }
    // 章节列表：<li><a href="/mXXXXXX/" title="" class="chapteritem">第XX话</a></li>
    final chapters = <Chapter>[];
    for (final m in _chapterRe.allMatches(body)) {
      final cid = m.group(1)!.split('/')[1].replaceFirst('m', '');
      chapters.add(Chapter(cid, _unescape(m.group(2) ?? '')));
    }
    // 状态：<span class="detail-list-title-1">连载中</span>
    var status = '';
    final st = _statusRe.firstMatch(body);
    if (st != null) status = st.group(1) ?? '';
    return ComicDetail(
      ComicItem(comicId, title, cover ?? ''),
      chapters,
      description: desc,
      status: status,
    );
  }

  static final RegExp _imgUrlRe = RegExp(r"'(https?://[^']+)'");
  static final RegExp _trimSlashRe = RegExp(r'^/|/$');

  @override
  Future<List<String>> chapterPics(String chapterId) async {
    final body = await SourceHttp.getUrl('dm5', '$_base/m$chapterId/');
    final packer = _extractPacker(body);
    if (packer == null) return const <String>[];
    final decoded = _decodePacker(packer.$1, packer.$2, packer.$3, packer.$4);
    if (decoded.isEmpty) return const <String>[];
    final urls = <String>[];
    for (final m in _imgUrlRe.allMatches(decoded)) {
      urls.add(m.group(1)!);
    }
    return urls;
  }

  // ---- 搜索页解析 ----
  // <li><div class="book-list-cover"><a href="/manhua-X/"><img src="..." alt="名称"></a></div></li>
  static final _searchRe = RegExp(
      r'<li>.*?book-list-cover.*?'
      r'<a href="(/manhua-[^"]+)"[^>]*>.*?'
      r'<img[^>]+src="([^"]+)"[^>]+alt="([^"]*)"[^>]*>',
      dotAll: true);

  List<ComicItem> _parseSearchList(String html) {
    final items = <ComicItem>[];
    for (final m in _searchRe.allMatches(html)) {
      final slug = m.group(1)!.replaceAll(_trimSlashRe, '').replaceAll('manhua-', '');
      items.add(ComicItem(slug, _unescape(m.group(3)!), m.group(2)!));
    }
    return items;
  }

  // ---- 排行榜页解析 ----
  // <a href="/manhua-X/"><li><div class="rank-list-cover"><img src="..." alt="名称"></div>...</li></a>
  static final _rankRe = RegExp(
      r'<a href="(/manhua-[^"]+)"[^>]*>.*?'
      r'<li>.*?rank-list-cover.*?'
      r'<img[^>]+src="([^"]+)"[^>]+alt="([^"]*)"[^>]*>',
      dotAll: true);

  List<ComicItem> _parseRankList(String html) {
    final items = <ComicItem>[];
    for (final m in _rankRe.allMatches(html)) {
      final slug = m.group(1)!.replaceAll(_trimSlashRe, '').replaceAll('manhua-', '');
      items.add(ComicItem(slug, _unescape(m.group(3)!), m.group(2)!));
    }
    return items;
  }

  // ---- 正则 ----

  static final _titleRe = RegExp(r'<title>([^<]*)</title>');
  // 详情页封面：<img src="mhfm*.cdndm5.com/.../..._180x240_20.jpg"（第一个 visible 漫画封面）
  static final _detailImgRe = RegExp(
      r'<img[^>]+src="(https://mhfm\d+yd?\.cdndm5\.com/[^"]*?_\d+x\d+_\d+\.[a-z]+)"');
  static final _mhfmImgRe = RegExp(
      r'<img[^>]+src="(https://mhfm\d+yd?\.cdndm5\.com/[^"]+)"');
  // 描述：<meta content="..." name="description"> 或 <meta name="description" content="...">
  static final _descRe = RegExp(
      r'<meta[^>]+(?:content="([^"]{30,})"[^>]+name="description"|name="description"[^>]+content="([^"]{30,})")');
  // 章节列表：<a href="/mXXXXXX/" title="" class="chapteritem">第XX话</a>
  static final _chapterRe = RegExp(
      r'<a\s+href="(/m\d+/)"[^>]*class="chapteritem"[^>]*>([^<]+)</a>');
  // 状态：<span class="detail-list-title-1">连载中</span>
  static final _statusRe = RegExp(
      r'class="detail-list-title-1"[^>]*>([^<]+)</span>');

  // ---- Packer 解混淆 ----

  /// 从页面中提取 packer 参数：(p, a, c, k)
  ///
  /// 不用正则匹配 eval 参数（p 含大量 `\'` 转义，正则的 `'(.*?)'` 会提前截断导致匹配失败）。
  /// 改为精确字符串解析，对齐 Python 参考实现（tool/test_dm5_packer6.py）：
  /// 定位 `eval(function(p,a,c,k,e,d)` 后找 `}(`，对括号内的 `('p',a,c,'k'.split('|'),...)`
  /// 做引号配对 + 逗号分隔，取出 p/a/c/k 四个参数。
  (String, int, int, List<String>)? _extractPacker(String html) {
    final funcIdx = html.indexOf('eval(function(p,a,c,k,e,d)');
    if (funcIdx < 0) return null;
    final callIdx = html.indexOf('}(', funcIdx);
    if (callIdx < 0) return null;
    final parts = _parseCallArgs(html, callIdx + 1);
    if (parts.length < 4) return null;
    final p = parts[0].replaceAll("\\'", "'").replaceAll('\\"', '"');
    final a = int.tryParse(parts[1]) ?? 36;
    final c = int.tryParse(parts[2]) ?? 36;
    final k = parts[3].split('|');
    return (p, a, c, k);
  }

  /// 解析 `(` 之后到配对的 `)` 之间的调用参数。
  ///
  /// 逐字符扫描：括号进深度、引号配对（`\` 后字符按转义连读）、逗号分隔；
  /// 字符串参数去掉外层引号，数字/变量原样保留。等价 Python 参考的遍历逻辑。
  static List<String> _parseCallArgs(String s, int start) {
    final parts = <String>[];
    var depth = 0;
    var current = StringBuffer();
    var inString = false;
    String? quote;
    var i = start;
    while (i < s.length) {
      final c = s[i];
      if (inString) {
        if (c == r'\') {
          current.write(c);
          if (i + 1 < s.length) {
            i++;
            current.write(s[i]);
          }
        } else if (c == quote) {
          inString = false;
          parts.add(current.toString());
          current = StringBuffer();
        } else {
          current.write(c);
        }
      } else {
        if (c == '(') {
          depth++;
        } else if (c == ')') {
          depth--;
          if (depth == 0) break;
        } else if (c == "'" || c == '"') {
          inString = true;
          quote = c;
          current = StringBuffer();
        } else if (c == ',') {
          final t = current.toString().trim();
          if (t.isNotEmpty) parts.add(t);
          current = StringBuffer();
        } else {
          current.write(c);
        }
      }
      i++;
    }
    final t = current.toString().trim();
    if (t.isNotEmpty) parts.add(t);
    return parts;
  }

  String _decodePacker(String p, int a, int c, List<String> k) {
    final d = <String, String>{};
    for (var i = 0; i < c; i++) {
      d[_packerKey(i, a)] = i < k.length ? k[i] : _packerKey(i, a);
    }
    final buf = StringBuffer();
    final tokenRe = RegExp(r'\w+');
    var last = 0;
    for (final m in tokenRe.allMatches(p)) {
      buf.write(p.substring(last, m.start));
      final token = m.group(0)!;
      buf.write(d[token] ?? token);
      last = m.end;
    }
    buf.write(p.substring(last));
    return buf.toString();
  }

  String _packerKey(int n, int a) {
    if (n < a) return _to36(n % a);
    return _packerKey(n ~/ a, a) + _to36(n % a);
  }

  String _to36(int n) {
    if (n < 10) return '$n';
    if (n <= 35) return String.fromCharCode(97 + n - 10);
    return String.fromCharCode(n + 29);
  }

  static String _unescape(String s) =>
      s.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'");

  static String? _first(RegExp re, String s) {
    final m = re.firstMatch(s);
    return m?.group(1);
  }
}