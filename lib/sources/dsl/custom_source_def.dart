import 'dart:convert';

import 'html_parser.dart';

/// 自定义源 JSON DSL 定义模型。
///
/// 一份 JSON（见 [CustomSourceDef.fromJson]）即可声明一个完整漫画源：
/// 基础信息 + 分类/列表/排行/搜索/详情/章节图六类规则。规则字段说明：
/// - 全部 URL 支持占位符：`{id}`（详情/章节图传入的 id）、`{page}`（页码）、
///   `{categoryId}`、`{keyword}`（搜索词，自动 URL 编码）。
/// - 每个规则可挂 `css`（选择器）或 `regex`（捕获组）两种抽取方式，二选一；
///   正则捕获组 1..n 映射为虚拟节点属性 r1..rn（对应抽取字段填 `r1`/`r2`…）。
/// - `decrypt` 声明响应解码链（按 `|` 串联）：
///   `b64`（base64→utf8）、`hex`（hex→utf8）、`aes:KEY[,IV]`（base64 密文 +
///   AES-128-CBC，key/iv 取前 16 字节）、`replace:OLD>NEW`、`re:PATTERN|REPL`、
///   `decode`（URL 解码）。
class CustomSourceDef {
  final String id;
  final String name;
  final String type; // 'comic' 等
  final String version;
  final String author;
  final String? description;
  final String baseUrl;
  final List<String> hosts;
  final List<String> imageHosts;
  final Map<String, String> headers;
  /// 图片请求头（防盗链 Referer 等），阅读器加载图源时携带。
  final Map<String, String> picHeaders;
  final bool requiresLogin;
  final String? categoriesUrl;
  final DslListRule? categoriesRule;
  final String? categoryListUrl;
  final DslListRule? categoryListRule;
  final String? rankUrl;
  final DslListRule? rankRule;
  final String? searchUrl;
  final DslListRule? searchRule;
  final String? detailUrl;
  final DslDetailRule? detailRule;

  const CustomSourceDef({
    required this.id,
    required this.name,
    this.type = 'comic',
    required this.version,
    required this.author,
    this.description,
    required this.baseUrl,
    this.hosts = const [],
    this.imageHosts = const [],
    this.headers = const {},
    this.picHeaders = const {},
    this.requiresLogin = false,
    this.categoriesUrl,
    this.categoriesRule,
    this.categoryListUrl,
    this.categoryListRule,
    this.rankUrl,
    this.rankRule,
    this.searchUrl,
    this.searchRule,
    this.detailUrl,
    this.detailRule,
  });

  factory CustomSourceDef.fromJson(Map<String, dynamic> j) => CustomSourceDef(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        type: (j['type'] as String?) ?? 'comic',
        version: (j['version'] as String?) ?? '1.0.0',
        author: (j['author'] as String?) ?? '',
        description: j['description'] as String?,
        baseUrl: (j['baseUrl'] as String?) ?? '',
        hosts: _strList(j['hosts']),
        imageHosts: _strList(j['imageHosts']),
        headers: _strMap(j['headers']),
        picHeaders: _strMap(j['picHeaders']),
        requiresLogin: (j['requiresLogin'] as bool?) ?? false,
        categoriesUrl: j['categoriesUrl'] as String?,
        categoriesRule: _rule(j['categories']),
        categoryListUrl: j['categoryListUrl'] as String?,
        categoryListRule: _rule(j['categoryList']),
        rankUrl: j['rankUrl'] as String?,
        rankRule: _rule(j['rank']),
        searchUrl: j['searchUrl'] as String?,
        searchRule: _rule(j['search']),
        detailUrl: j['detailUrl'] as String?,
        detailRule: _detailRule(j['detail']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'version': version,
        'author': author,
        'description': description,
        'baseUrl': baseUrl,
        'hosts': hosts,
        'imageHosts': imageHosts,
        'headers': headers,
        'picHeaders': picHeaders,
        'requiresLogin': requiresLogin,
        'categoriesUrl': categoriesUrl,
        'categories': categoriesRule?.toJson(),
        'categoryListUrl': categoryListUrl,
        'categoryList': categoryListRule?.toJson(),
        'rankUrl': rankUrl,
        'rank': rankRule?.toJson(),
        'searchUrl': searchUrl,
        'search': searchRule?.toJson(),
        'detailUrl': detailUrl,
        'detail': detailRule?.toJson(),
      };

  static List<String> _strList(dynamic v) =>
      List<String>.from(v as List? ?? []);

  static Map<String, String> _strMap(dynamic v) =>
      Map<String, String>.from(v as Map? ?? {});

  static DslListRule? _rule(dynamic v) => v is Map
      ? DslListRule.fromJson(Map<String, dynamic>.from(v))
      : null;

  static DslDetailRule? _detailRule(dynamic v) => v is Map
      ? DslDetailRule.fromJson(Map<String, dynamic>.from(v))
      : null;

  /// 校验：返回错误列表（空 = 通过）。
  List<String> validate() {
    final errs = <String>[];
    if (id.isEmpty) errs.add('缺少 id');
    if (name.isEmpty) errs.add('缺少 name');
    if (baseUrl.isEmpty) errs.add('缺少 baseUrl');
    else {
      // 必须 http(s) + 拒绝本机/内网/组播地址（P1 SSRF）
      if (!(baseUrl.startsWith('http://') || baseUrl.startsWith('https://'))) {
        errs.add('baseUrl 必须以 http(s):// 开头');
      } else {
        final reason = _internalHostReason(baseUrl);
        if (reason != null) {
          errs.add('baseUrl 指向 $reason，禁止内网/本机地址');
        }
      }
    }
    if (type != 'comic' && type != 'video' && type != 'novel') {
      errs.add('type 仅支持 comic/video/novel');
    }
    // 至少要有一种可用的内容规则（列表或详情）
    if (categoryListUrl == null && rankUrl == null && searchUrl == null && detailUrl == null) {
      errs.add('至少配置一种内容规则（categoryList/rank/search/detail）');
    }
    if (categoryListUrl != null && categoryListRule == null) errs.add('categoryList 配置了 URL 但缺少规则');
    if (searchUrl != null && searchRule == null) errs.add('search 配置了 URL 但缺少规则');
    if (detailUrl != null && detailRule == null) errs.add('detail 配置了 URL 但缺少规则');
    // 正则可编译性预检：非法正则（如孤立的 `[`）会在运行期 RegExp 构造时
    // 抛 FormatException 逃逸到 UI 层，这里在安装/校验阶段就拦截。
    for (final r in [categoryListRule, rankRule, searchRule]) {
      if (r != null && r.regex.isNotEmpty) _checkRegex(r.regex, errs);
    }
    detailRule?.validate(errs, detailUrl);
    return errs;
  }
}

/// 单条正则字段的长度上限（防 ReDoS：过长 pattern 会让主 Isolate 卡死）。
/// 合法 DSL 规则通常几十到几百字符，2000 已经是极端宽松的上限。
const int _maxRegexLen = 2000;

/// 校验一段 DSL 正则：长度 + 可编译性（任一失败则向 [errs] 追加一条）。
/// 附带字段名，便于用户定位问题字段。
void _checkRegex(String pattern, List<String> errs, {String? field}) {
  final tag = field != null ? '${field}=' : '';
  if (pattern.length > _maxRegexLen) {
    errs.add('正则过长（${pattern.length} > $_maxRegexLen 字符）：$tag${_clip(pattern)}');
    return;
  }
  try {
    RegExp(pattern);
  } catch (e) {
    errs.add('非法正则「${_clip(pattern)}」: $e');
  }
}

/// 错误提示里的 pattern 片段截断（避免一条错误信息塞下几千字符）。
String _clip(String s, [int n = 40]) =>
    s.length <= n ? s : '${s.substring(0, n)}…';

/// 检查 [url] 是否为内网/本机地址；返回中文拒绝理由（null 表示合法）。
/// 覆盖：localhost / 127.0.0.0/8 / ::1 / 0.0.0.0 / 10.0.0.0/8 /
/// 172.16.0.0/12 / 192.168.0.0/16 / 169.254.0.0/16（链路本地）/
/// fc00::/7（IPv6 内网）/ fe80::/10（链路本地）/ 100.64.0.0/10（运营商 NAT）。
String? _internalHostReason(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null; // 交给 baseUrl 前缀检查兜底
  final host = u.host;
  if (host.isEmpty) return null;
  final lower = host.toLowerCase();
  if (lower == 'localhost') return '本机地址 localhost';
  // IPv6 字面量（Uri.host 会剥掉方括号，形如 ::1 或 2001:db8::1）
  if (lower.contains(':')) {
    if (lower == '::1' || lower == '0:0:0:0:0:0:0:1' || lower == '::') {
      return '本机地址 ::1';
    }
    if (lower.startsWith('fe80')) return '链路本地地址 fe80::/10';
    if (lower.startsWith('fc') || lower.startsWith('fd')) return '内网地址 fc00::/7';
    // 混合 IPv6-IPv4 写法（如 ::ffff:127.0.0.1），取后缀 IPv4 再判一次
    final idx = lower.lastIndexOf(':');
    if (idx >= 0 && lower.substring(idx + 1).contains('.')) {
      return _internalHostReason('http://${lower.substring(idx + 1)}');
    }
    return null;
  }
  // IPv4 字面量（无方括号）
  final parts = lower.split('.');
  if (parts.length == 4 &&
      parts.every((p) => p.isNotEmpty && int.tryParse(p) != null)) {
    final a = int.parse(parts[0]);
    final b = int.parse(parts[1]);
    // 按段判断，覆盖 127.0.0.1 / 127.5.6.7 等回环写法
    if (a == 127) return '本机地址 127/8';
    // 只拒 0.0.0.0 本身（RFC 1918 保留）；不拒整个 0/8 段以避免误伤
    if (lower == '0.0.0.0') return '本机地址 0.0.0.0';
    if (a == 10) return '内网地址 10/8';
    if (a == 172 && b >= 16 && b <= 31) return '内网地址 172.16/12';
    if (a == 192 && b == 168) return '内网地址 192.168/16';
    if (a == 169 && b == 254) return '链路本地地址 169.254/16';
    if (a == 100 && b >= 64 && b <= 127) return '运营商 NAT 保留段 100.64/10';
  }
  return null;
}

/// 列表类规则（分类列表/分类内容/排行/搜索共用）。
class DslListRule {
  final String selector; // CSS 选择器
  final String regex; // 正则（每匹配一组 → 虚拟节点）
  final String decrypt; // 响应解码链
  final String name; // 名称字段（CSS 属性名 或 正则捕获组 r1）
  final String id; // id 字段
  final String url; // 详情链接字段
  final String pic; // 封面字段
  final String? yname;
  final String? score;
  final String? hits;
  final String? rank;
  final String? author;
  final String? content;
  final String? picFallback;
  final String? itemName; // 分类名（分类专用）
  final String? itemUrl; // 分类链接（分类专用）

  const DslListRule({
    this.selector = '',
    this.regex = '',
    this.decrypt = '',
    this.name = '',
    this.id = '',
    this.url = '',
    this.pic = '',
    this.yname,
    this.score,
    this.hits,
    this.rank,
    this.author,
    this.content,
    this.picFallback,
    this.itemName,
    this.itemUrl,
  });

  factory DslListRule.fromJson(Map<String, dynamic> j) => DslListRule(
        selector: (j['css'] as String?) ?? '',
        regex: (j['regex'] as String?) ?? '',
        decrypt: (j['decrypt'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        id: (j['id'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        pic: (j['pic'] as String?) ?? '',
        yname: j['yname'] as String?,
        score: j['score'] as String?,
        hits: j['hits'] as String?,
        rank: j['rank'] as String?,
        author: j['author'] as String?,
        content: j['content'] as String?,
        picFallback: j['picFallback'] as String?,
        itemName: j['itemName'] as String?,
        itemUrl: j['itemUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'css': selector,
        'regex': regex,
        'decrypt': decrypt,
        'name': name,
        'id': id,
        'url': url,
        'pic': pic,
        'yname': yname,
        'score': score,
        'hits': hits,
        'rank': rank,
        'author': author,
        'content': content,
        'picFallback': picFallback,
        'itemName': itemName,
        'itemUrl': itemUrl,
      };
}

/// 详情页规则 + 章节图规则。
class DslDetailRule {
  final String title;
  /// 标题清理正则（组 1 = 清理后的标题），用于剥离标题尾部混入的评分/年份
  /// 等无关文本（如 stui 站的「片名 7.2」）。留空则标题原样输出。
  final String titleRe;
  final String cover;
  final String coverAttr;
  final String author;
  final String description;
  final String area;
  final String type;
  final String status;
  final String chapters; // 章节容器 CSS
  final String chapterUrl; // 章节链接属性（href）
  final String chapterUrlRe; // 章节链接正则（从 innerText 或 href 提取）
  final String chapterTitle; // 章节标题属性（可选）
  final String chaptersRe; // 章节正则（组1=标题 组2=链接）
  final String baseDecrypt; // 详情响应解码
  final String picListUrl; // 章节图页 URL（含 {id}）
  final String picListCss; // 章节图 CSS
  final String picListRe; // 章节图正则（组1=地址）
  final String picAttr; // 图片地址属性（默认 src）
  final String picListDecrypt; // 章节图响应解码
  final String picFilter; // 图片地址过滤正则（命中才保留）
  final Map<String, String> picReplace; // 图片地址替换 {old: new}
  /// m3u8 播放列表重写规则（顺次替换字符串）。用于分片 CDN 域名失效/被墙
  /// 时把播放列表里的分片地址替换为可用镜像（如 kkzycdn.com:65 →
  /// play.modujx16.com）。仅当 picListRe/picListCss 抽到的地址以 .m3u8 结尾
  /// 时生效：会先下载该 m3u8，替换后再写本地缓存文件返回 file:// 路径。
  final Map<String, String> m3u8Rewrite;
  final String baseUrl; // 相对链接解析基准
  /// 详情 id → 播放/章节图 id 的变换规则。
  /// - 用命名组 `(?<id>...)`（或 Python 风格 `(?P<id>...)`）指定变换结果。
  ///   如 `166(?<id>\d+)` 把 `fcdm/16613410.html` 映射为 `13410`。
  /// - 未用命名组时取组 1（无组时取整个匹配）：如 `(?<id>\d+)` 或 `(\d+)`
  ///   把 `pptv/1230130` 映射为 `1230130`。
  /// 正则缺失或不命中时原样返回。
  /// 用于「详情页 id 与播放页 id 不同」的站点（如风车动漫 16621700→21700）。
  final String idRegex;

  const DslDetailRule({
    this.title = '',
    this.titleRe = '',
    this.cover = '',
    this.coverAttr = 'src',
    this.author = '',
    this.description = '',
    this.area = '',
    this.type = '',
    this.status = '',
    this.chapters = '',
    this.chapterUrl = 'href',
    this.chapterUrlRe = '',
    this.chapterTitle = '',
    this.chaptersRe = '',
    this.baseDecrypt = '',
    this.picListUrl = '',
    this.picListCss = '',
    this.picListRe = '',
    this.picAttr = 'src',
    this.picListDecrypt = '',
    this.picFilter = '',
    this.picReplace = const {},
    this.m3u8Rewrite = const {},
    this.baseUrl = '',
    this.idRegex = '',
  });

  factory DslDetailRule.fromJson(Map<String, dynamic> j) => DslDetailRule(
        title: (j['title'] as String?) ?? '',
        titleRe: (j['titleRe'] as String?) ?? '',
        cover: (j['cover'] as String?) ?? '',
        coverAttr: (j['coverAttr'] as String?) ?? 'src',
        author: (j['author'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        area: (j['area'] as String?) ?? '',
        type: (j['type'] as String?) ?? '',
        status: (j['status'] as String?) ?? '',
        chapters: (j['chapters'] as String?) ?? '',
        chapterUrl: (j['chapterUrl'] as String?) ?? 'href',
        chapterUrlRe: (j['chapterUrlRe'] as String?) ?? '',
        chapterTitle: (j['chapterTitle'] as String?) ?? '',
        chaptersRe: (j['chaptersRe'] as String?) ?? '',
        baseDecrypt: (j['baseDecrypt'] as String?) ?? '',
        picListUrl: (j['picListUrl'] as String?) ?? '',
        picListCss: (j['picListCss'] as String?) ?? '',
        picListRe: (j['picListRe'] as String?) ?? '',
        picAttr: (j['picAttr'] as String?) ?? 'src',
        picListDecrypt: (j['picListDecrypt'] as String?) ?? '',
        picFilter: (j['picFilter'] as String?) ?? '',
        picReplace: Map<String, String>.from(j['picReplace'] as Map? ?? {}),
        m3u8Rewrite: Map<String, String>.from(j['m3u8Rewrite'] as Map? ?? {}),
        baseUrl: (j['baseUrl'] as String?) ?? '',
        idRegex: (j['idRegex'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'titleRe': titleRe,
        'cover': cover,
        'coverAttr': coverAttr,
        'author': author,
        'description': description,
        'area': area,
        'type': type,
        'status': status,
        'chapters': chapters,
        'chapterUrl': chapterUrl,
        'chapterUrlRe': chapterUrlRe,
        'chapterTitle': chapterTitle,
        'chaptersRe': chaptersRe,
        'baseDecrypt': baseDecrypt,
        'picListUrl': picListUrl,
        'picListCss': picListCss,
        'picListRe': picListRe,
        'picAttr': picAttr,
        'picListDecrypt': picListDecrypt,
        'picFilter': picFilter,
        'picReplace': picReplace,
        'm3u8Rewrite': m3u8Rewrite,
        'baseUrl': baseUrl,
        'idRegex': idRegex,
      };

  void validate(List<String> errs, String? detailUrl) {
    if (picListUrl.isEmpty && detailUrl != null) {
      errs.add('detail 配置了 URL 但缺少 picListUrl（章节图）');
    }
    if (picListUrl.isNotEmpty &&
        picListCss.isEmpty &&
        picListRe.isEmpty) {
      errs.add('picListUrl 已配置但缺少 picListCss/picListRe');
    }
    // 正则预检（见 CustomSourceDef.validate 注释）：全部正则字段做长度 + 编译
    // 检查，包括此前漏检的 picFilter。
    for (final re in [titleRe, chapterUrlRe, chaptersRe, picListRe, idRegex, picFilter]) {
      if (re.isNotEmpty) _checkRegex(re, errs);
    }
    // m3u8Rewrite 目标安全校验：值是「子串替换 pattern」而非完整 URL
    // （如 "kkzycdn.com:65" → "play.modujx16.com"），因此不能强制 URL 格式。
    // 但要拒绝会注入危险 scheme 的目标——否则第三方源可把合法 m3u8 分片
    // 替换为 file:///etc/passwd，让 mpv 读取本机任意文件。
    for (final e in m3u8Rewrite.entries) {
      final why = unsafeRewriteTarget(e.value);
      if (why != null) {
        errs.add(
            'm3u8Rewrite 值「${_clip(e.value)}」不安全：$why');
      }
    }
  }
}

/// 序列化工具。
String encodeCustomSourceDef(CustomSourceDef def) =>
    const JsonEncoder.withIndent('  ').convert(def.toJson());

CustomSourceDef? decodeCustomSourceDef(String json) {
  try {
    final m = jsonDecode(json);
    if (m is Map<String, dynamic>) return CustomSourceDef.fromJson(m);
  } catch (_) {}
  return null;
}