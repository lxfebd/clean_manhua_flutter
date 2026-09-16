import '../models/comic_item.dart';
import '../net/http_client.dart';
import 'comic_source.dart';
import 'source_result.dart';
import 'video_source.dart';

/// 鞍山影院视频源（www.dainyew.com）。
///
/// ewave 模板站点。关键约定（决定本源用 Dart 实现而非 JSON DSL 插件）：
/// 详情页 id 与播放页 id **不同**——详情为 `/{ns}/{num}.html`（ns 为 news / dvd /
/// cctv / mtv 等多命名空间，随分页变化、无法预测），播放页统一为
/// `/tvplay/{num}-{channel}-{ep}.html`。需从详情 id 抽取纯数字 num 再拼播放地址，
/// JSON DSL 的 `{id}` 占位符无法表达，故写成内置源。
///
/// 数据流：
/// - 分类列表：首页 `/so-show/{cat}-----------.html`（11 个 dash），
///   翻页 `/so-show/{cat}--------{page}---.html`（页码插在 8 个 dash 之后）。
///   实测 dash 数错一位就静默返回单作品的 SEO 页而非分类列表。
/// - 搜索：**站点已不可用**——首页表单 action `/search/-------------.html?wd={kw}`
///   实测返回 0 条目（服务端错误），导航栏关键词模板 `/so-show/{cat}-{kw}---------.html`
///   返回的是 SEO 垃圾聚合页（`/{ns}/{随机目录}/{id}.html`，无播放源）。
///   故 search 抛「暂不可用」，由 UI 提示，列表仍从分类浏览进入。
/// - 详情：`/{ns}/{num}.html`，标题 `h1.title`、封面 `data-original`（站内相对路径）、
///   元信息 `p`（「类型：…地区：…年份：…」）、剧集 `a[href="/tvplay/…"]`。
/// - 播放：`/tvplay/{num}-{channel}-{ep}.html`，m3u8 直链在内联脚本
///   `var player_aaaa={...}` 的 `"url":"https:\/\/…m3u8"`（斜杠带反斜杠转义）。
///
/// 防 SEO 垃圾：列表只收录 id 形如 `/{ns}/{纯数字}.html` 的条目。垃圾页的特征是
/// 数字 id 前多一段随机目录（`/mtv/dvgesudtgc/324622.html`），会被此规则过滤。
class AshanYingyuanVideoSource implements VideoSource {
  static const String _base = 'https://www.dainyew.com';

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static final Map<String, String> _headers = {
    'User-Agent': _ua,
    'Referer': '$_base/',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  /// 列表条目：`/so-show/` 页每卡以 `ewave-vodlist__thumb` 开头。
  ///
  /// 用「锚点切窗」而非单条大正则——卡片里 `<span class="pic-text">…</span>`
  /// 之后紧跟 `<span class="pic-tag">`，`[^>]*?` 无法跨越 `>`，单条正则会让
  /// 封面/备注捕获组恒为空（实测 30 卡全丢封面）。改为按卡片起点切窗，
  /// 各自取字段。`href` 形如 `/{ns}/{纯数字}.html` 是防 SEO 垃圾的关键——
  /// 垃圾页数字前多一段随机目录（`/mtv/dvgesudtgc/324622.html`），不匹配。
  static final RegExp _cardAnchorRe = RegExp(r'ewave-vodlist__thumb');
  static final RegExp _cardTitleRe = RegExp(r'title="([^"]*)"');
  static final RegExp _cardPicRe = RegExp(r'data-original="([^"]*)"');
  static final RegExp _cardRemarkRe =
      RegExp(r'<span class="pic-text[^"]*">([^<]*)</span>');
  static final RegExp _cardLinkRe = RegExp(
    r'<a class="thumb-link" href="(/(?:news|dvd|cctv|mtv|tv|pptv|vedio)/(\d+)\.html)"',
  );

  /// 标题：`<h1 class="title"><span >标题</span><span class="score…">5.0</span></h1>`
  /// 取第一个 span，否则尾部评分数字会混进标题。
  static final RegExp _titleRe =
      RegExp(r'<h1 class="title">\s*<span[^>]*>([^<]*)</span>');
  static final RegExp _metaLineRe = RegExp(r'<p[^>]*>[\s\S]*?</p>');
  /// 剧集只在 `#playlist\d+` 块内提取，避免把「立即播放」按钮计入剧集。
  static final RegExp _playlistRe = RegExp(r'<div id="playlist\d+"');
  static final RegExp _epRe = RegExp(
    r'href="(/tvplay/\d+-(\d+)-(\d+)\.html)"[^>]*>([^<]*)</a>',
  );
  /// 播放页 m3u8：`"url":"https:\/\/play…/index.m3u8"`（反斜杠转义形式）。
  static final RegExp _playJsonUrlRe = RegExp(r'"url"\s*:\s*"([^"]+)"');

  static final List<Category> _categories = [
    Category('45', '里番动漫'),
    Category('36', '精品日韩'),
    Category('26', '日本动漫'),
    Category('25', '国产动漫'),
    Category('27', '欧美动漫'),
    Category('28', '海外动漫'),
    Category('4', '全部动漫'),
    Category('18', '日剧'),
    Category('20', '海外剧'),
    Category('30', '最新短剧'),
  ];

  @override
  String get id => 'ashanyy';

  @override
  String get name => '鞍山影院';

  @override
  Future<List<Category>> categories() async => _categories;

  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async {
    final cat = _categories.any((c) => c.id == categoryId)
        ? categoryId
        : _categories.first.id;
    // 首页 11 个 dash；翻页把页码插在**第 9 个 dash 之前**（8 dash + 页码 + 3 dash）。
    // 实测：`45-----------` → 30 条列表；`45----------`（10 dash）返回的是单个作品
    // 的 SEO 页而非分类列表——dash 数错一位会静默返回错误页面。
    final tail = page <= 1 ? '-----------.html' : '--------$page---.html';
    final html = await _fetch('$_base/so-show/$cat$tail');
    return _parseCards(html);
  }

  @override
  Future<List<ComicItem>> search(String keyword, int page) async {
    // 搜索端点已失效：实测 /search/-------------.html?wd={kw} 返回 0 条目，
    // 关键词模板返回 SEO 垃圾（无播放源）。返回空列表，避免用户拿到不可播结果。
    return const [];
  }

  @override
  Future<VideoDetail> detail(String videoId) async {
    final html = await _fetch('$_base${_detailPath(videoId)}');
    final num = _videoNum(videoId);

    final title = _stripTags(_firstGroup(_titleRe, html)).trim();

    // 封面：详情页顶部 `<div class="ewave-vodlist__thumb picture v-thumb" title="…">`
    // 内是 `<img>`；其后的 `data-original` 属于「猜你喜欢」区，不能直接取第一个。
    final cover = _detailCover(html);

    // 完整简介在 `#desc` 块内；`<p class="desc">` 只有「…详情」截断串。
    final descBlock = _blockUntil(html, 'id="desc"', 'ewave-pannel ewave-pannel-bg');
    var desc = descBlock.isEmpty ? null : _stripTags(descBlock);
    String? area;
    String? year;
    String? type;
    // 实测站点把「类型：…地区：…年份：…」三个字段挤在同一个 `<p>` 里，
    // 故必须按标签边界切值，不能取「标签：」之后的全部内容。
    for (final m in _metaLineRe.allMatches(html)) {
      final text = _stripTags(m.group(0) ?? '');
      type = _fieldValue(text, '类型') ?? type;
      area = _fieldValue(text, '地区') ?? area;
      year = _fieldValue(text, '年份') ?? year;
      desc ??= _fieldValue(text, '简介');
    }
    if (year != null && year == '0') year = null;

    // 剧集只在 `#playlist\d+` 块内提取：页面上另有一个「立即播放」按钮，
    // 它的 href 与第 1 集相同，若全页扫会重复计入。
    final episodes = <VideoEpisode>[];
    final seen = <String>{};
    for (final blk in _playlistBlocks(html)) {
      for (final m in _epRe.allMatches(blk)) {
        final href = m.group(1) ?? '';
        if (!seen.add(href)) continue;
        final channel = int.tryParse(m.group(2) ?? '');
        final ep = int.tryParse(m.group(3) ?? '');
        if (channel == null || ep == null) continue;
        final rawLabel = _unescape(m.group(4) ?? '').trim();
        final label = rawLabel.isEmpty ? '第${_pad(ep)}集' : rawLabel;
        episodes.add(VideoEpisode(channel, ep, label));
      }
    }
    if (episodes.isEmpty && num != null) {
      // 兜底：无剧集时提供至少第 1 集，避免详情页空列表。
      episodes.add(VideoEpisode(1, 1, '第01集'));
    }

    return VideoDetail(
      ComicItem(videoId, title, cover),
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
    final num = _videoNum(videoId);
    if (num == null) {
      throw const SourceError.service('无效的播放地址');
    }
    final pageUrl = '$_base/tvplay/$num-$season-$episode.html';
    final referer = '$_base${_detailPath(videoId)}';
    String? html;
    try {
      html = await Net.get(
        pageUrl,
        headers: {..._headers, 'Referer': referer},
        timeout: const Duration(seconds: 20),
      );
    } catch (_) {
      try {
        html = await Net.get(
          pageUrl,
          headers: {..._headers, 'Referer': referer},
          timeout: const Duration(seconds: 25),
        );
      } catch (_) {}
    }
    final m = html == null ? null : _playJsonUrlRe.firstMatch(html);
    final raw = m?.group(1);
    if (raw != null) {
      // player_aaaa 的 JSON 用 \/ 转义斜杠，需还原为真实 URL。
      return raw.replaceAll('\\/', '/');
    }
    // 解析不出直链（站点结构变化 / JS 质询页）：返回播放页 URL 交内嵌 WebView。
    return pageUrl;
  }

  /// 详情页相对路径。列表给的 id 已带 `.html`，重复拼后缀会被站点 200 重定向到
  /// 一个无关作品的 SEO 页（实测 `/mtv/1228564.html.html` 稳定返回《大家操》，
  /// 且 HTTP 200——不会报错，只会静默给错内容）。
  static String _detailPath(String videoId) {
    final p = videoId.trim();
    if (p.startsWith('/')) return p;
    return '/$p';
  }

  /// 从详情 id 抽取播放用数字（`news/1082954` → `1082954`；兼容纯数字 id）。
  static String? _videoNum(String videoId) {
    final digits = RegExp(r'/(\d+)\.html?$').firstMatch(videoId)?.group(1);
    if (digits != null) return digits;
    final all = videoId.replaceAll(RegExp(r'\D'), '');
    return all.isEmpty ? null : all;
  }

  /// 按卡片锚点切窗解析列表。每个窗口内各自取标题/封面/备注/链接，
  /// 保证 `pic-text` 之后的 `pic-tag` 不会阻断封面捕获。
  List<ComicItem> _parseCards(String html) {
    final out = <ComicItem>[];
    final seen = <String>{};
    final starts = [for (final m in _cardAnchorRe.allMatches(html)) m.start];
    for (var i = 0; i < starts.length; i++) {
      final end = i + 1 < starts.length ? starts[i + 1] : html.length;
      final win = html.substring(starts[i], end);
      final link = _cardLinkRe.firstMatch(win);
      if (link == null) continue;
      final href = link.group(1) ?? '';
      if (!seen.add(href)) continue;
      // 站点用 `&#22899;` 形式编码中文，标题/备注都需解码。
      final title = _unescape(_cardTitleRe.firstMatch(win)?.group(1) ?? '').trim();
      if (title.isEmpty) continue;
      final pic = _abs(_cardPicRe.firstMatch(win)?.group(1) ?? '');
      final remarks = _unescape(_cardRemarkRe.firstMatch(win)?.group(1) ?? '').trim();
      out.add(ComicItem(href, title, pic)
        ..remarks = remarks.isEmpty ? null : remarks);
    }
    return out;
  }

  /// 从 `from` 标记处截到 `stop` 标记（或文本末尾），取中间内容。
  /// 用于抽取 `#desc` 简介块——完整简介不在 `<p>` 里。
  String _blockUntil(String html, String from, String stop) {
    final k = html.indexOf(from);
    if (k < 0) return '';
    var end = html.length;
    final s = html.indexOf(stop, k + from.length);
    if (s >= 0) end = s;
    return html.substring(k, end);
  }

  /// 剧集块：`#playlist\d+` 起、到下一个同级 pannel 或文本末尾。
  List<String> _playlistBlocks(String html) {
    final out = <String>[];
    for (final m in _playlistRe.allMatches(html)) {
      var end = m.end + 4000;
      if (end > html.length) end = html.length;
      out.add(html.substring(m.start, end));
    }
    return out;
  }

  /// 详情页封面：顶部 `v-thumb` 容器内的首张图。
  ///
  /// 该 `<img>` 是懒加载，`src` 是占位 gif（`/template/…/load.gif`），真实地址
  /// 在 `data-original`——实测位于 `src` 之后，故必须只取 `data-original`。
  String _detailCover(String html) {
    final k = html.indexOf('v-thumb');
    if (k < 0) return '';
    final end = html.length > k + 1500 ? k + 1500 : html.length;
    final win = html.substring(k, end);
    final m = _detailCoverRe.firstMatch(win);
    return _abs(m?.group(1) ?? '');
  }

  static final RegExp _detailCoverRe = RegExp(r'data-original="(/[^"]+)"');

  String _abs(String url) {
    var pic = _unescape(url).trim();
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

  /// 元信息字段值：取「标签：」之后、下一个「已知字段标签：」之前的内容。
  ///
  /// 站点的元信息行把多个字段拼在同一个 `<p>` 内（「类型：A 地区：B 年份：2026」），
  /// 直接取标签后的全部会串字段，故以其它字段标签作为终止边界。
  static String? _fieldValue(String text, String label) {
    const labels = ['类型', '地区', '年份', '主演', '导演', '更新', '简介'];
    final i = text.indexOf('$label：');
    if (i < 0) return null;
    var tail = text.substring(i + label.length + 1);
    var cut = tail.length;
    for (final other in labels) {
      if (other == label) continue;
      final j = tail.indexOf('$other：');
      if (j >= 0 && j < cut) cut = j;
    }
    final value = tail.substring(0, cut).trim();
    return value.isEmpty ? null : value;
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
