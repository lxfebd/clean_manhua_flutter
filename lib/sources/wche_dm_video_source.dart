import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'video_source.dart';

/// 风车动漫视频源（www.16dns.com）。
///
/// stui 模板站点。关键约定（决定本源用 Dart 实现而非 JSON DSL 插件）：
/// 详情页 id 与播放页 id **不同**——详情为 `/fcdm/{id}.html`，
/// 播放页为 `/co_e/{playId}-0-{ep}.html`，其中 `playId = id 去掉前缀 "166"`
/// （如详情 `16613410` → 播放 `13410`）。该变换已实测 4 个样本（16613410→13410 /
/// 16613476→13476 / 16621014→21014 / 16622052→22052）确认稳定，
/// 但 JSON DSL 的 `{id}`/`{season}`/`{episode}` 占位符无法表达，故写成内置源。
///
  /// 数据流：
  /// - 分类列表：`/html/{cat}[-{page}].html`，条目为 stui 卡片；
  /// - 搜索：**站点已不可用**——实测 `/search/{kw}-----------.html` 的所有
  ///   dash 变体都返回同一份忽略关键词的静态页；详情页 `<a>` 指向的
  ///   `/search.php?searchword=` 触发站点人机校验（「系统安全验证」）。
  ///   故 search 返回空列表，由 UI 提示，列表仍从分类浏览进入。
  /// - 详情：`/fcdm/{id}.html`，标题 `h1.title`、封面 `data-original`、
  ///   元信息 `p.data`、剧集 `a[title][href="/co_e/..."]`（去重后为真实剧集，
  ///   导航区的「立即播放」链接会被去重掉）。
  /// - 播放：`/co_e/{playId}-0-{ep}.html`，m3u8 直链在内联脚本变量
  ///   `var now="..."`；部分剧集该变量为空串，解析失败时返回播放页 URL
  ///   交内嵌 WebView 加载（站点可能下发 JS 质询）。
  /// - 剧集号是 **0 基**：`/co_e/{playId}-0-0.html` 即第 01 集。
class WcheDmVideoSource implements VideoSource {
  static const String _base = 'https://www.16dns.com';

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static final Map<String, String> _headers = {
    'User-Agent': _ua,
    'Referer': '$_base/',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  /// 分类列表条目：以 `<a class="stui-vodlist__thumb` 为锚点切窗解析。
  ///
  /// 用切窗而非单条大正则——实测同一页有**两种封面载体**，单条正则里的可选
  /// 捕获组会被前置的 `[^>]*?` 短路成空匹配（封面恒丢）：
  /// - 主列表区用懒加载 `data-original="https://…"`（42 张）；
  /// - 页顶推荐区用内联 `style="background: url(https://…) …"`（10 张）。
  /// 卡片内的 `pic-text` 是标题重复而非更新提示，故不取。
  static final RegExp _cardAnchorRe = RegExp(r'<a class="stui-vodlist__thumb');
  static final RegExp _cardIdRe = RegExp(r'href="(/fcdm/(\d+)\.html)"');
  static final RegExp _cardTitleRe = RegExp(r'title="([^"]*)"');
  static final RegExp _cardPicDataRe = RegExp(r'data-original="(https?://[^"]+)"');
  static final RegExp _cardPicBgRe = RegExp(r'background:\s*url\((https?://[^)]+)\)');

  /// 标题：`<h1 class="title">标题<span class="score text-red">6.0</span></h1>`
  /// 标题是**裸文本**后接评分 span，故只取首个 span 之前的部分。
  static final RegExp _titleRe =
      RegExp(r'<h1 class="title">([^<]*)');
  /// 封面：详情页用 `data-original` 承载全图 URL。
  static final RegExp _fullCoverRe = RegExp(r'data-original="(https?://[^"]+)"');
  static final RegExp _descRe =
      RegExp(r'<p class="desc[^"]*">([\s\S]*?)</p>', dotAll: true);
  static final RegExp _dataRowRe = RegExp(
    r'<p class="data">\s*([\s\S]*?)\s*</p>',
    dotAll: true,
  );
  /// 元信息行内「标签：」与紧随的值（值在 `<a>` 内或纯文本）。
  static final RegExp _metaPairRe = RegExp(r'>([^<>]{1,6})：</span>[\s\S]*?>([^<>]+)<');
  /// 剧集链接。实测标签属性顺序为 `title=` 在前、`href=` 在后，故按
  /// `title="…" href="…"` 匹配；剧集号是 **0 基**（`-0-0` 即第 01 集）。
  /// detailUrl 的 id 与播放页 id 不同，故同时捕获两段数字。
  static final RegExp _epRe = RegExp(
    r'<a[^>]*title="([^"]*)"[^>]*href="(/co_e/(\d+)-\d+-(\d+)\.html)"',
    dotAll: true,
  );
  static final RegExp _nowRe = RegExp(r'var\s+now="([^"]+)"');

  static final List<Category> _categories = [
    Category('1666', '里番动漫'),
    Category('1661', '日韩动漫'),
    Category('1662', '欧美动漫'),
    Category('1663', '国产动漫'),
    Category('1664', '动漫电影'),
    Category('1665', '海外动漫'),
  ];

  @override
  String get id => 'wchedm';

  @override
  String get name => '风车动漫';

  @override
  Future<List<Category>> categories() async => _categories;

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final cat = _categories.any((c) => c.id == categoryId)
        ? categoryId
        : _categories.first.id;
    final url = page <= 1 ? '$_base/html/$cat.html' : '$_base/html/$cat-$page.html';
    final html = await _fetch(url);
    return _parseCards(html);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    // 搜索端点已失效：实测 `/search/{kw}-----------.html` 的所有 dash 变体
    // 都返回同一份忽略关键词的静态页；详情页 `<a>` 指向的
    // `/search.php?searchword=` 会触发站点人机校验（「系统安全验证」）。
    // 返回空列表，避免用户拿到与本剧无关的结果。
    return const [];
  }

  @override
  Future<VideoDetail> detail(String videoId) async {
    final html = await _fetch('$_base/fcdm/$videoId.html');

    final title = _stripTags(_firstGroup(_titleRe, html)).trim();
    final cover = _resolveCover(_firstGroup(_fullCoverRe, html));
    String? desc;
    for (final m in _descRe.allMatches(html)) {
      final text = _stripTags(m.group(1) ?? '').replaceFirst(RegExp(r'^简介[:：]\s*'), '').trim();
      if (text.isNotEmpty && text != '详情') {
        desc = text;
        break;
      }
    }

    String? area;
    String? year;
    String? type;
    for (final m in _dataRowRe.allMatches(html)) {
      final text = _stripTags(m.group(1) ?? '');
      if (text.contains('类型')) type = _afterLabel(text, '类型');
      if (text.contains('地区')) area = _afterLabel(text, '地区');
      if (text.contains('年份')) year = _afterLabel(text, '年份');
    }
    if (type == null || area == null) {
      for (final m in _metaPairRe.allMatches(html)) {
        final k = m.group(1)?.trim() ?? '';
        final v = m.group(2)?.trim() ?? '';
        if (k == '类型' && type == null) type = v;
        if (k == '地区' && area == null) area = v;
        if (k == '年份' && year == null) year = v;
      }
    }
    if (year != null && year == '0') year = null;

    // 剧集：按 href 去重（导航区的「立即播放」与第 1 集同 href，会被合并）。
    final episodes = <VideoEpisode>[];
    final seen = <String>{};
    for (final m in _epRe.allMatches(html)) {
      final href = m.group(2) ?? '';
      if (!seen.add(href)) continue;
      final ep = int.tryParse(m.group(4) ?? '');
      if (ep == null) continue;
      // 站点的剧集号是 0 基（`-0-0` 即第 01 集）；标题缺失时按 +1 兜底。
      final label = (m.group(1) ?? '').trim().isEmpty
          ? '第${_pad(ep + 1)}集'
          : (m.group(1) ?? '').trim();
      episodes.add(VideoEpisode(1, ep, label));
    }

    final item = ComicItem(videoId, title, cover);
    return VideoDetail(
      item,
      episodes,
      description: desc,
      cover: cover,
      area: area,
      year: year,
      type: type,
    );
  }

  @override
  Future<String> playUrl(String videoId, int season, int episode) async {
    final playId = _playId(videoId);
    final pageUrl = '$_base/co_e/$playId-0-$episode.html';
    final detailUrl = '$_base/fcdm/$videoId.html';
    String? html;
    try {
      // 带 Referer 为详情页，降低反爬触发率。
      html = await Net.get(
        pageUrl,
        headers: {..._headers, 'Referer': detailUrl},
        timeout: const Duration(seconds: 20),
      );
    } catch (_) {
      try {
        html = await Net.get(
          pageUrl,
          headers: {..._headers, 'Referer': detailUrl},
          timeout: const Duration(seconds: 25),
        );
      } catch (_) {}
    }
    final m = html == null ? null : _nowRe.firstMatch(html);
    if (m != null) return m.group(1)!;
    // 解析不出直链（人机校验落地页 / 网络抖动 / 站点结构变化）：
    // 返回播放页 URL 交内嵌 WebView 通道加载——WebView 具备完整浏览器指纹，
    // 可执行站点 JS 质询并通过后由播放器自行渲染。
    return pageUrl;
  }

  /// 详情页 id → 播放页 id：去掉前缀 "166"。
  /// 已实测样本 16613410→13410 / 16613476→13476 / 16621014→21014 / 16622052→22052。
  static String _playId(String videoId) {
    final digits = videoId.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 3 && digits.startsWith('166')) {
      return digits.substring(3);
    }
    return digits;
  }

  List<ComicItem> _parseCards(String html) {
    final out = <ComicItem>[];
    final seen = <String>{};
    final starts = [for (final m in _cardAnchorRe.allMatches(html)) m.start];
    for (var i = 0; i < starts.length; i++) {
      final end = i + 1 < starts.length ? starts[i + 1] : html.length;
      final win = html.substring(starts[i], end);
      final idMatch = _cardIdRe.firstMatch(win);
      if (idMatch == null) continue;
      final id = idMatch.group(2) ?? '';
      if (id.isEmpty || !seen.add(id)) continue;
      final title = _unescape(_cardTitleRe.firstMatch(win)?.group(1) ?? '').trim();
      if (title.isEmpty) continue;
      // 主列表区优先取 data-original，推荐区回退到内联 background url。
      final pic = _resolveCover(
        _cardPicDataRe.firstMatch(win)?.group(1) ??
            _cardPicBgRe.firstMatch(win)?.group(1) ??
            '',
      );
      out.add(ComicItem(id, title, pic));
    }
    return out;
  }

  /// 封面路径可能是相对路径（列表页）或全图 URL（详情页），统一补全为绝对地址。
  String _resolveCover(String raw) {
    var pic = _unescape(raw).trim();
    if (pic.isEmpty) return '';
    if (pic.startsWith('http://') || pic.startsWith('https://')) return pic;
    if (pic.startsWith('//')) return 'https:$pic';
    if (pic.startsWith('/')) return '$_base$pic';
    return pic;
  }

  Future<String> _fetch(String url) async {
    try {
      return await Net.get(url, headers: _headers, timeout: const Duration(seconds: 25));
    } catch (_) {
      return Net.get(
        url,
        headers: _headers,
        timeout: const Duration(seconds: 30),
      );
    }
  }

  static String _firstGroup(RegExp re, String s) =>
      re.firstMatch(s)?.group(1)?.trim() ?? '';

  static String _stripTags(String s) =>
      _unescape(s).replaceAll(RegExp(r'<[^>]+>'), '').trim();

  static String? _afterLabel(String text, String label) {
    final i = text.indexOf('$label：');
    if (i < 0) return null;
    final tail = text.substring(i + label.length + 1).trim();
    return tail.isEmpty ? null : tail;
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// 站点主用数字实体转义（`&#22899;` 中文、`&#xNNNN;` 符号），
  /// 故必须先解码数字实体再解码命名实体，否则标题会是乱码数字串。
  static String _unescape(String s) {
    s = s.replaceAllMapped(
        _numHexRe, (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
    s = s.replaceAllMapped(_numDecRe, (m) => String.fromCharCode(int.parse(m.group(1)!)));
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }

  static final RegExp _numHexRe = RegExp(r'&#x([0-9a-fA-F]+);');
  static final RegExp _numDecRe = RegExp(r'&#(\d+);');
}
