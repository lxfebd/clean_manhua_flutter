import 'dart:convert';

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
    if (!(baseUrl.startsWith('http://') || baseUrl.startsWith('https://'))) {
      errs.add('baseUrl 必须以 http(s):// 开头');
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
    detailRule?.validate(errs, detailUrl);
    return errs;
  }
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
  final String baseUrl; // 相对链接解析基准

  const DslDetailRule({
    this.title = '',
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
    this.baseUrl = '',
  });

  factory DslDetailRule.fromJson(Map<String, dynamic> j) => DslDetailRule(
        title: (j['title'] as String?) ?? '',
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
        baseUrl: (j['baseUrl'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'title': title,
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
        'baseUrl': baseUrl,
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