import '../models/comic_item.dart';
import 'dsl/html_parser.dart' show firstCleanMatch, stripHtmlTags;
import 'novel_source.dart';
import 'source_config.dart';
import 'source_http.dart';

/// 笔趣阁小说源（`www.biquge365.net` 经典笔趣阁模板）。
///
/// ## 2026-11-04 换站重写
/// 旧站 tobiquge.com / xbiquge.com **已全灭**：
/// - `tobiquge.com`：HTTP 302 跳 `http://www.js96110.com.cn/`（江苏反诈拦截页），
///   HTTPS 直接 TLS 握手失败——站点被反诈系统接管，不是临时故障；
/// - `xbiquge.com`：HTTPS 15s 超时无响应。
/// 另测 16 个常见笔趣阁镜像，无一使用旧站 `/bqg/{id}/{cid}.html` 模板，故不换
/// 域名、直接**换站**：改为 `biquge365.net`（同属经典笔趣阁模板）。
///
/// ## 站点结构（2026-11-04 实测）
/// - 分类：`/sort/{catId}_{page}/`（catId 1-8；第 1 页即 `_1`）
/// - 详情：`/newbook/{novelId}/`，章节目录整页直出
///   （`<a href="/chapter/{id}/{cid}.html">第N章 …</a>`）
/// - 章节：`/chapter/{novelId}/{cid}.html` → 正文在 `<div id="txt">` 内，
///   以 `<br/>` 分段。**多页章节仍一页直出**：文本中间会插入
///   `（本章未完，请点击下一页继续阅读）第N章xx(第2/2页)` 之类的标记，但第 2 页
///   内容紧接其后，无需真的抓第二页，清洗掉标记即可。
/// - 搜索：站内 `POST /s.php` **自身 SQL 报错**
///   （`Illegal mix of collations (gbk_bin, utf8mb3_general_ci)`），
///   服务端根本搜不出结果；与旧实现一致，返回空列表由 UI 兜底。
/// - 排行：无独立排行榜页，回退分类第 1 页（玄幻魔法）当榜单。
///
/// 保留 `id: 'biquge'` / `name: '笔趣阁'` 不变，书架里已收藏的进度不受影响
/// （`chapterId` 形如 `"novelId|cid"`，与旧实现同构）。
class BiqugeNovelSource extends NovelSource {
  /// 主站 + 备用镜像。站点换域名时优先在这里补，解析规则通常无需改动。
  static const List<String> _defaultHosts = [
    'https://www.biquge365.net',
  ];

  /// 已确认死亡的旧域名。**必须在选取 host 时过滤掉**：
  /// `SourceConfigStore.hostsFor()` 优先返回内置/用户配置里的 hosts，
  /// 而老用户的 `sources_config.json` 里仍可能存着换站前的那对域名。
  /// 若不剔除，配置会盖过 [_defaultHosts]，导致「解析器换了站却仍然连旧站」。
  static const Set<String> _deadHosts = {
    'https://www.tobiquge.com',
    'http://www.tobiquge.com',
    'https://www.xbiquge.com',
    'http://www.xbiquge.com',
  };

  /// 站内分类 id → 名称（来自首页导航 `/sort/{id}_1/`）。
  static const Map<String, String> _catNames = {
    '1': '玄幻魔法',
    '2': '仙侠修真',
    '3': '都市言情',
    '4': '网游动漫',
    '5': '科幻小说',
    '6': '恐怖灵异',
    '7': '历史军事',
    '8': '其他小说',
  };

  /// 主列表条目（`ul.gengxin` 内的更新列表，**分页正确的那一份**）：
  /// `<li><span class="name">《<a href="/book/{id}/">书名</a>》</span>
  ///  <span class="jie"><a href="/chapter/{id}/{cid}.html">最新章节</a></span>
  ///  <span class="zuo">作者</span><span class="time">日期</span></li>`
  ///
  /// 注意：页面顶部/侧栏另有一块「本站强推 / 收藏排行」（带封面、每页都相同），
  /// 早先按「img + h3」抓会一直抓到那份重复数据，导致翻页首条不变。
  static final RegExp _mainItemRe = RegExp(
      r'<li>\s*<span class="name">《<a\s+href="/book/(\d+)/"[^>]*>([^<]+)</a>》</span>'
      r'(?:\s*<span class="jie"><a[^>]*>([^<]*)</a></span>)?'
      r'(?:\s*<span class="zuo">([^<]*)</span>)?');

  /// 推荐位条目（带封面，仅当主列表为空时兜底）：
  /// `<a href="/book/{id}/"><img src="…"></a> … <h3><a href="/book/{id}/">书名</a>`
  static final RegExp _itemRe = RegExp(
      r'<a\s+href="/book/(\d+)/"[^>]*>\s*<img[^>]+src="([^"]+)"[^>]*>[\s\S]*?'
      r'<h3[^>]*>\s*<a\s+href="/book/\1/"[^>]*>([^<]+)</a>');
  /// 无封面的简洁列表（部分栏目只有文字链接）
  static final RegExp _textItemRe = RegExp(
      r'<a\s+href="/book/(\d+)/"[^>]*>([^<]{2,40})</a>');

  /// 章节目录：`<a href="/chapter/{novelId}/{cid}.html">第N章 标题</a>`
  static final RegExp _chapterRe = RegExp(
      r'<a[^>]*\bhref="/chapter/(\d+)/(\d+)\.html"[^>]*>([^<]+)</a>');
  /// 过滤目录里的功能按钮（不是章节）
  static const Set<String> _navLabels = {
    '开始阅读',
    '章节目录',
    '加入书架',
    '上一章',
    '下一章',
    '返回目录',
  };

  static final RegExp _ogTitleRe =
      RegExp(r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"');
  static final RegExp _ogImgRe =
      RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"');
  static final RegExp _ogDescRe =
      RegExp(r'<meta[^>]+property="og:description"[^>]+content="([^"]*)"');
  static final RegExp _authorRe =
      RegExp(r'<meta[^>]+name="author"[^>]+content="([^"]+)"');
  static final RegExp _h1Re = RegExp(r'<h1[^>]*>([^<]+)</h1>');

  /// 正文容器起点：`<div  id="txt" class="txt">`（结尾边界见 [_parseContent]）
  static final RegExp _contentStartRe =
      RegExp(r'<div\s+id="txt"[^>]*>', caseSensitive: false);

  // ── 正文清洗 ────────────────────────────────────────────────────────
  /// 站方插入的广告行：「一秒记住【笔趣阁】biquge365.net，更新快，无弹窗！」
  static final RegExp _adRe =
      RegExp(r'一秒记住【[^】]*】[^\n<]*', caseSensitive: false);
  /// 分页标记：「(第1/2页)」
  static final RegExp _pageMarkRe =
      RegExp(r'\(第\d+/\d+页\)', caseSensitive: false);
  /// 翻页提示：「（本章未完，请点击下一页继续阅读）」
  static final RegExp _nextHintRe =
      RegExp(r'（本章未完，请点击下一页继续阅读）', caseSensitive: false);
  /// 分段标记：老章节用 `<br/>`，较新的章节改用 `<p>…</p>`。
  /// 两者都要当换行处理，否则 `</p>` 那类章节会被并成一个几千字的巨型段落
  /// （实测某章 paras=2 / 8359 字），阅读体验极差。
  static final RegExp _brRe =
      RegExp(r'(<br\s*/?>|</p>|</div>)', caseSensitive: false);
  static final RegExp _tagRe = RegExp(r'<[^>]+>');
  static final RegExp _nbspRe = RegExp(r'&nbsp;|&#160;', caseSensitive: false);
  /// 单独的章节标题行残留（无正文），如「第318章 敲打」
  static final RegExp _bareTitleRe = RegExp(r'^第\d+章[\s\S]{0,30}$');

  @override
  String get id => 'biquge';

  @override
  String get name => '笔趣阁';

  /// 换站后已可用；仍保持 `fallback`，让实测更充分的新笔趣阁
  /// （xbiquge.bz）继续担任小说首页默认源，本源作为可选备用。
  @override
  SourceTier get tier => SourceTier.fallback;

  /// 选一个可用 host 并 GET 相对路径。
  ///
  /// 优先级：用户在源管理页配置的 host（剔除 [_deadHosts]）→ [_defaultHosts]。
  /// 这样既尊重用户自定义域名，又不会被换站前的死域名卡住。
  Future<String> _get(String path) async {
    final configured = await SourceConfigStore.hostsFor('biquge', _defaultHosts);
    final alive = configured
        .map((h) => h.trim())
        .where((h) => h.isNotEmpty && !_deadHosts.contains(h))
        .toList();
    final host = alive.isNotEmpty ? alive.first : _defaultHosts.first;
    return SourceHttp.getUrl('biquge', '$host$path');
  }

  @override
  Future<List<Category>> categories() async => [
        for (final e in _catNames.entries) Category(e.key, e.value),
      ];

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final id = _catNames.containsKey(categoryId) ? categoryId : '1';
    return _parseList(await _get('/sort/${id}_$page/'));
  }

  @override
  Future<List<ComicItem>> rank(int page) async {
    // 无独立排行页：用「玄幻魔法」分类首页当榜单（page>1 时仍回首页）。
    return _parseList(await _get('/sort/1_1/'));
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    // 站内搜索服务端 SQL 报错（collation 冲突），拿不到结果 → UI 兜底。
    return const [];
  }

  @override
  Future<NovelDetail> detail(String novelId) async {
    // /newbook/{id}/ 整页直出章节目录
    final body = await _get('/newbook/$novelId/');

    // firstCleanMatch 无匹配时返回 ''（非 null），故按「空则回退」逐级取。
    var name = _cleanText(firstCleanMatch(_ogTitleRe, body));
    if (name.isEmpty) name = _cleanText(firstCleanMatch(_h1Re, body));
    if (name.isEmpty) name = novelId;
    final cover = firstCleanMatch(_ogImgRe, body);
    final desc = firstCleanMatch(_ogDescRe, body);
    final author = firstCleanMatch(_authorRe, body);

    final chapters = <NovelChapter>[];
    final seen = <String>{};
    var idx = 0;
    for (final m in _chapterRe.allMatches(body)) {
      final nid = m.group(1)!;
      final cid = m.group(2)!;
      if (nid != novelId) continue; // 页面可能有「推荐」区，排除别的书
      final label = _cleanText(m.group(3) ?? '');
      if (label.isEmpty || _navLabels.contains(label)) continue;
      if (!seen.add(cid)) continue;
      chapters.add(NovelChapter('$novelId|$cid', label, index: idx++));
    }

    final item = ComicItem(novelId, name, cover)
      ..author = author
      ..content = desc;

    return NovelDetail(item, chapters, description: desc);
  }

  @override
  Future<NovelContent> chapterContent(String chapterId) async {
    // chapterId 形如 "{novelId}|{cid}"
    final sep = chapterId.indexOf('|');
    if (sep < 0) return NovelContent(chapterId, '', const []);
    final novelId = chapterId.substring(0, sep);
    final cid = chapterId.substring(sep + 1);

    final body = await _get('/chapter/$novelId/$cid.html');
    final title = _cleanText(firstCleanMatch(_h1Re, body));
    final paragraphs = _parseContent(body);
    final nav = _parseNav(body);

    return NovelContent(
      chapterId,
      title,
      paragraphs,
      prevChapterId: nav.$1,
      nextChapterId: nav.$2,
    );
  }

  // ── 解析辅助 ────────────────────────────────────────────────────────

  List<ComicItem> _parseList(String body) {
    final items = <ComicItem>[];
    final seen = <String>{};

    // 0) 先把页面里「带封面的推荐位」建成 id → 封面 映射。
    //    主列表（ul.gengxin）本身不含图片，但推荐位常与主列表部分重叠，
    //    顺手复用封面可让首屏多几张图（拿不到也不影响功能）。
    final covers = <String, String>{};
    for (final m in _itemRe.allMatches(body)) {
      final id = m.group(1)!;
      final src = _absolute(m.group(2) ?? '');
      if (src.isNotEmpty) covers.putIfAbsent(id, () => src);
    }

    // 1) 主列表（ul.gengxin）：分页正确，条目无封面（用上面的映射补）
    for (final m in _mainItemRe.allMatches(body)) {
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      final title = _cleanText(m.group(2) ?? '');
      if (title.isEmpty) continue;
      final latest = _cleanText(m.group(3) ?? '');
      final author = _cleanText(m.group(4) ?? '');
      items.add(ComicItem(id, title, covers[id] ?? '')
        ..author = author.isEmpty ? null : author
        ..remarks = latest.isEmpty ? null : latest);
    }
    if (items.isNotEmpty) return items;

    // 2) 兜底：推荐位（带封面）。仅当页面没有主列表时使用。
    for (final m in _itemRe.allMatches(body)) {
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      items.add(ComicItem(
        id,
        _cleanText(m.group(3) ?? ''),
        _absolute(m.group(2) ?? ''),
      ));
    }
    if (items.isNotEmpty) return items;

    // 3) 再兜底：纯文字链接（跳过按钮词）
    for (final m in _textItemRe.allMatches(body)) {
      final id = m.group(1)!;
      final label = _cleanText(m.group(2) ?? '');
      if (label.isEmpty || _navLabels.contains(label)) continue;
      if (!seen.add(id)) continue;
      items.add(ComicItem(id, label, ''));
    }
    return items;
  }

  /// 正文：按 `<br>` 分段，逐段清洗广告/分页标记/翻页提示。
  ///
  /// 站点的多页章节虽然插了「第2/2页」标记，但第 2 页正文同一响应里紧接
  /// 其后，故这里不真抓第二页，只把标记抹掉。
  ///
  /// 容器边界不用「第一个 `</div>`」：`#txt` 内可能嵌 `div`（报错层/翻页层），
  /// 非贪婪正则会在内层提前收尾，正文被截成几十字。改为优先切在
  /// 版面已知的收尾标记（报错/翻页/遮罩）之前，找不到再退回到 `</div>`。
  List<String> _parseContent(String body) {
    final startMark = _contentStartRe.firstMatch(body);
    if (startMark == null) return const [];
    final from = startMark.end;
    final rest = body.substring(from);

    var end = rest.length;
    for (final marker in const [
      '<div class="baocuo"',
      '<div id="fanye',
      '<div class="zhezhao"',
    ]) {
      final i = rest.indexOf(marker);
      if (i >= 0 && i < end) end = i;
    }
    if (end == rest.length) {
      // 没有已知收尾标记时，退回到闭合 div（可能截断，但有内容总比没有好）
      final j = rest.indexOf('</div>');
      if (j >= 0) end = j;
    }

    var raw = rest.substring(0, end);
    raw = raw.replaceAll(_brRe, '\n');
    raw = raw.replaceAll(_tagRe, '');
    raw = raw.replaceAll(_nbspRe, ' ');
    raw = raw.replaceAll(_adRe, '');
    raw = raw.replaceAll(_nextHintRe, '');
    raw = raw.replaceAll(_pageMarkRe, '');

    final out = <String>[];
    for (final line in raw.split('\n')) {
      final t = line.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isEmpty) continue;
      // 单独的章节标题行残留（无正文）跳过
      if (_bareTitleRe.hasMatch(t)) continue;
      out.add(t);
    }

    // 站点对部分章节（实测为较新的章节）下发**加密正文**：肉眼是可读的
    // Base64 大块，但 base64 解开后仍非 UTF-8/GBK 明文（服务端加密，页面也
    // 没有可复用的解密脚本；带 Referer/Cookie 同样只得到密文）。此时若直接
    // 输出，读者会看到几千字符的乱码。识别出来给一条明确提示，既不假装成功
    // 也不把垃圾塞进正文。
    final joined = out.join('');
    final cjk = RegExp(r'[\u4e00-\u9fa5]').allMatches(joined).length;
    final looksCipher = cjk < 20 &&
        joined.length > 80 &&
        RegExp(r'[A-Za-z0-9+/=]{60,}').hasMatch(joined);
    if (looksCipher) {
      return const ['（本章正文由站点加密下发，App 端暂无法解密；可到站点网页端阅读。）'];
    }
    return out;
  }

  /// 上一章/下一章 id（返回 `"novelId|cid"`，无则 null）。
  (String?, String?) _parseNav(String body) {
    String? prev;
    String? next;
    final re = RegExp(
        r'<a[^>]*\bhref="/chapter/(\d+)/(\d+)\.html"[^>]*>\s*(上一章|下一章)\s*</a>');
    for (final m in re.allMatches(body)) {
      final id = '${m.group(1)}|${m.group(2)}';
      if (m.group(3) == '上一章') {
        prev ??= id;
      } else if (m.group(3) == '下一章') {
        next ??= id;
      }
    }
    return (prev, next);
  }

  String _cleanText(String raw) => stripHtmlTags(raw).trim();

  String _absolute(String src) {
    final s = src.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('http')) return s;
    if (s.startsWith('//')) return 'https:$s';
    final host = _defaultHosts.first;
    return s.startsWith('/') ? '$host$s' : '$host/$s';
  }
}
