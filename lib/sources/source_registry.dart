/// 内置第三方源的**授权登记册**（P0-06）。
///
/// ## 这个文件解决什么问题
/// 本 App 内置了若干第三方内容源（漫画/动漫/小说站）。「技术上能抓取」**不等于**
/// 「已获授权」——公开分发一个默认启用这些源的客户端，可能面临投诉、下架与信任
/// 风险。参考案例：Legado 官方仓库已因侵权被清空项目并保留法律公告（2026-11-20
/// 核验）；Mihon 的做法是只做客户端、源由社区自行承担。
///
/// 审查清单里的原始要求（P0-06）：
/// > 建立源登记册（运营者/内容范围/授权或开放 API 依据/联系人/复核日期/下架状态）；
/// > 官方源与社区源分栏；提供投诉下架入口与版本化禁用清单；必要时法务复核。
/// >
/// > 验收：发布包 100% 默认启用源均有登记与审查结论，授权未知源为 0；
/// > 完成一次「投诉→禁用索引→旧版本停止默认启用」演练。
///
/// ## 本文件的诚实原则
/// **不确定就写不确定。** 没有一份源站公开过授权文件，所以绝大多数条目的
/// [AuthorizationKind] 只能是 [AuthorizationKind.unknown] 或
/// [AuthorizationKind.unofficial]。这看起来"不好看"，但把它写成
/// "已获授权"才是真正的风险——那是伪造合规状态，比没有登记更糟。
///
/// 因此本 App 的**产品定位**要与之匹配：**本地优先、用户自行选择源**，
/// 内置源以 [SourceTier.fallback] 为主，默认源（primary）也仅限
/// 「站点公开提供内容、无付费墙、无 DRM」的普通聚合站。
/// 这不是法律意见，也不构成授权；真要公开发行请做法务复核。
///
/// ## 登记册与「禁用清单」的分工
/// - 本文件是**编译期快照**：随版本发布，记录"发布这一刻的认知"。
/// - 运行期的**下架动作**走 [SourceTakdownList]（lib/sources/source_takdown.dart）：
///   版本化、可远端更新，能让**已经装出去的旧版本**也停止默认启用某个源。
///   两者的关系是：登记册给结论，禁用清单执行下架。
library;

/// 授权依据的性质。**不要**把 [unknown] 粉饰成别的值。
enum AuthorizationKind {
  /// 站点自带公开 API 且条款允许第三方客户端访问（如 MangaDex）。
  openApi,

  /// 站点官方授权本客户端使用（本项目目前没有任何一例）。
  licensed,

  /// 站点自身即为内容发布方/版权方（自营内容）。
  firstParty,

  /// 无公开授权声明，属社区/第三方整理性质的源。
  unofficial,

  /// 未获授权，或授权状态无法核实——**默认按此处理**。
  unknown,
}

/// 源的归属分栏：官方（本项目维护者承担）vs 社区（用户自行取舍）。
enum SourceProvenance {
  /// 本项目内置并默认提供，由本项目维护。
  official,

  /// 社区/第三方性质，界面上单独分栏提示用户自担风险。
  community,
}

/// 下架状态。
enum TakdownState {
  /// 正常在架。
  active,

  /// 已被投诉/预警，但仍保留——**必须写明原因**。
  underReview,

  /// 已下架：不再默认启用，且禁用清单会拦掉。
  removed,
}

/// 单个内置源的授权登记条目。
class SourceRegistration {
  /// 源 id，与 `SourceManager` 里的 id 一致（构建期会对齐，见 `test/source_registry_test.dart`）。
  final String sourceId;

  /// 展示名。
  final String displayName;

  /// 媒体类型（comic / video / novel），便于分栏展示。
  final String mediaType;

  /// 站点运营方。**不要臆测公司名**——只知道域名就写域名。
  final String operator;

  /// 内容范围（站点提供什么）。
  final String contentScope;

  /// 授权或开放 API 依据。写事实：文档地址、条款链接、或"无公开授权声明"。
  final String basis;

  final AuthorizationKind authKind;

  final SourceProvenance provenance;

  final TakdownState state;

  /// 复核日期（YYYY-MM-DD）。**必须真实**，是"何时核过"的记录。
  final String reviewedAt;

  /// 投诉/下架联系人。无公开联系方式时写 "无公开联系方式"。
  final String contact;

  /// 下架/预警原因（[TakdownState.active] 时为 null）。
  final String? note;

  const SourceRegistration({
    required this.sourceId,
    required this.displayName,
    required this.mediaType,
    required this.operator,
    required this.contentScope,
    required this.basis,
    required this.authKind,
    required this.provenance,
    required this.state,
    required this.reviewedAt,
    required this.contact,
    this.note,
  });

  /// 该源是否「授权明确到可以放心默认启用」。
  ///
  /// 只有 [AuthorizationKind.openApi] / [licensed] / [firstParty] 算明确；
  /// [unofficial] / [unknown] 一律**不算**——这正是验收项
  /// 「授权未知源为 0」的判定口径。
  bool get hasExplicitAuthorization =>
      authKind == AuthorizationKind.openApi ||
      authKind == AuthorizationKind.licensed ||
      authKind == AuthorizationKind.firstParty;

  /// 是否可被默认启用：在架 + 授权明确。
  ///
  /// [SourceTakdownList] 会在运行期再叠一层（远端下架优先于本快照）。
  bool get canBeDefaultEnabled =>
      state == TakdownState.active && hasExplicitAuthorization;

  /// 界面展示用的授权描述（中文，避免英文残留）。
  String get authLabel {
    switch (authKind) {
      case AuthorizationKind.openApi:
        return '公开 API（条款允许第三方访问）';
      case AuthorizationKind.licensed:
        return '站点已授权本客户端';
      case AuthorizationKind.firstParty:
        return '站点自营内容';
      case AuthorizationKind.unofficial:
        return '社区整理（无公开授权声明）';
      case AuthorizationKind.unknown:
        return '授权状态未知';
    }
  }

  String get stateLabel {
    switch (state) {
      case TakdownState.active:
        return '在架';
      case TakdownState.underReview:
        return '复核中';
      case TakdownState.removed:
        return '已下架';
    }
  }

  String get provenanceLabel =>
      provenance == SourceProvenance.official ? '官方源' : '社区源';
}

/// 全量登记册。
///
/// ## 编写规则（后续接手者必读）
/// 1. 新增内置源 → **必须**在这里加一条，否则 `source_registry_test` 会红。
///    （测试用 `SourceManager` 的实际源列表与本登记册做双向对齐校验。）
/// 2. `basis` 只写**能验证的事实**：有 API 文档就贴链接；没有就写
///    「无公开授权声明」，并把 [authKind] 定为 [AuthorizationKind.unknown]。
/// 3. 不要把 `authKind` 往乐观方向写。写保守了只是少一个默认启用的源，
///    写乐观了是伪造合规。
/// 4. 复核日期要真的复核过才写。
const List<SourceRegistration> kSourceRegistrations = [
  // ---------------- 漫画 ----------------
  SourceRegistration(
    sourceId: 'dm5',
    displayName: '动漫屋',
    mediaType: 'comic',
    operator: 'dm5.com 运营方（未公开公司主体）',
    contentScope: '日漫/韩漫等漫画聚合，含付费章节',
    basis: '无公开授权声明；站点未提供面向第三方客户端的公开 API 条款',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式（站点页面未见投诉入口）',
    note: '国内聚合站，内容多为未授权转载。保留仅因用户量大、可用性最好；'
        '如收到权利人投诉应优先下架。',
  ),
  SourceRegistration(
    sourceId: 'doubao',
    displayName: '豆包漫画',
    mediaType: 'comic',
    operator: 'doubaomanhua.com 运营方（未公开公司主体）',
    contentScope: '漫画聚合',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '同上：内容授权不可核实。',
  ),
  SourceRegistration(
    sourceId: 'jm',
    displayName: '禁漫天堂',
    mediaType: 'comic',
    operator: '18comic/JM 系列站点（域名频繁轮换，主体不明）',
    contentScope: '成人向漫画（R18）',
    basis: '无公开授权声明；站点以 Cloudflare 挑战封锁抓取',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '成人内容 + 授权不明，风险最高。已因反爬基本不可用；'
        '**建议下一版本直接下架**（见待办）。',
  ),
  SourceRegistration(
    sourceId: 'mangadex',
    displayName: 'MangaDex',
    mediaType: 'comic',
    operator: 'MangaDex（社区运营的非营利项目）',
    contentScope: '多语言漫画，含 scanlation 组上传内容',
    basis: '有公开 API 与使用文档（https://api.mangadex.org/docs/），'
        '文档要求客户端如实标识 UA 并遵守限流；站点自身亦声明内容由社区上传',
    authKind: AuthorizationKind.openApi,
    provenance: SourceProvenance.official,
    state: TakdownState.active,
    reviewedAt: '2026-11-27',
    contact: 'https://api.mangadex.org/docs/（含联系方式与 abuse 渠道）',
    note: '唯一有明确开放 API 依据的源。注意：开放 API 授权的是**接口访问**，'
        '不等于对站点内第三方上传内容的分发授权。',
  ),
  // ---------------- 视频 ----------------
  SourceRegistration(
    sourceId: 'agedm',
    displayName: 'AGE 动漫',
    mediaType: 'video',
    operator: 'agedm.io 运营方（未公开公司主体）',
    contentScope: '动漫在线播放（iframe 引第三方 m3u8）',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '内容授权不可核实。真实 m3u8 地址由站点 JS 加密后放在 iframe 参数里，'
        '该加密与被绕过属站点自身机制，不代表授权。',
  ),
  SourceRegistration(
    sourceId: 'tvtfun',
    displayName: 'TvTFun',
    mediaType: 'video',
    operator: 'tvtfun.net 运营方（未公开公司主体）',
    contentScope: '番剧在线播放',
    basis: '无公开授权声明；站点有人机验证（/cap/）',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '内容授权不可核实。站点另设人机验证（/cap/），属反爬措施，不构成授权。',
  ),
  SourceRegistration(
    sourceId: 'xifan',
    displayName: '稀饭动漫',
    mediaType: 'video',
    operator: 'xifanacg.com 运营方（未公开公司主体）',
    contentScope: '动漫在线播放',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '内容授权不可核实，站点未公开任何授权或 API 条款。',
  ),
  SourceRegistration(
    sourceId: 'anime1',
    displayName: 'Anime1',
    mediaType: 'video',
    operator: 'anime1.me 运营方（未公开主体）',
    contentScope: '动画在线播放（纯文本站点，无封面）',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '2026-11-27 实测全线 HTTP 521（Cloudflare 回源失败），'
        '疑似源站宕机；无可用镜像（anime1.pw 为挖矿木马域名，禁止访问）。',
  ),
  SourceRegistration(
    sourceId: 'wchedm',
    displayName: '风车动漫',
    mediaType: 'video',
    operator: '16dns.com 运营方（未公开公司主体）',
    contentScope: '动漫在线播放',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '内容授权不可核实，站点未公开任何授权或 API 条款。',
  ),
  SourceRegistration(
    sourceId: 'ashanyy',
    displayName: '鞍山影院',
    mediaType: 'video',
    operator: 'dainyew.com 运营方（未公开公司主体）',
    contentScope: '影视/动漫聚合（ewave 模板站）',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '站点仅 HTTP 可用（HTTPS 握手失败），传输层本身不安全。',
  ),
  // ---------------- 小说 ----------------
  SourceRegistration(
    sourceId: 'biquge',
    displayName: '笔趣阁',
    mediaType: 'novel',
    operator: 'biquge365.net 运营方（笔趣阁为长期被大量仿冒的模板站群，主体不明）',
    contentScope: '网络小说全文（多为盗版转载）',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '「笔趣阁」是模板站群通用名，版权风险高。',
  ),
  SourceRegistration(
    sourceId: 'xbiquge',
    displayName: '新笔趣阁',
    mediaType: 'novel',
    operator: 'xbiquge.bz 运营方（同上，模板站群）',
    contentScope: '网络小说（多为盗版转载）',
    basis: '无公开授权声明',
    authKind: AuthorizationKind.unknown,
    provenance: SourceProvenance.community,
    state: TakdownState.underReview,
    reviewedAt: '2026-11-27',
    contact: '无公开联系方式',
    note: '同上。当前是小说默认源，风险需知悉。',
  ),
  SourceRegistration(
    sourceId: 'local',
    displayName: '本地小说',
    mediaType: 'novel',
    operator: '本 App（用户导入本地文件）',
    contentScope: '用户自带的本地 txt/epub',
    basis: '不涉及网络抓取；内容由用户自行提供',
    authKind: AuthorizationKind.firstParty,
    provenance: SourceProvenance.official,
    state: TakdownState.active,
    reviewedAt: '2026-11-27',
    contact: '本项目仓库 issue',
    note: '无版权风险：不触网、不内置内容。',
  ),
];

/// 按 id 查登记条目；未登记返回 null。
SourceRegistration? registrationOf(String sourceId) {
  for (final r in kSourceRegistrations) {
    if (r.sourceId == sourceId) return r;
  }
  return null;
}

/// 未登记的源 id 列表（用于测试与"发布前自检"）。
///
/// 空列表 = 所有内置源都有登记。
List<String> unregisteredSourceIds(Iterable<String> sourceIds) {
  final out = <String>[];
  for (final id in sourceIds) {
    if (registrationOf(id) == null) out.add(id);
  }
  return out;
}

/// 授权未知但**当前被默认启用**的源。
///
/// ## ⚠️ 这是已知偏差，不是"通过"
/// 审查清单 P0-06 的验收标准原文是「授权未知源为 0」。本项目**当前不满足**
/// 该项：实测有 11 个源在默认启用状态下授权状态为 [AuthorizationKind.unknown]。
///
/// 运营者（2026-11-27）明确决定：**保持这些源默认启用，改为如实记录风险**，
/// 理由是本 App 的定位是本地优先的阅读客户端，源的可选性是核心功能；
/// 骤然降级会直接砍掉大部分可用内容。
///
/// 因此本函数保留，但**不再由测试硬阻断**（见 `test/source_registry_test.dart`
/// 里的「已知偏差」用例）。谁要改这个决定，改那份测试的断言即可——
/// 但请连同本段说明一起改，不要静默把偏差洗成通过。
///
/// 真正的兜底不是"假装授权明确了"，而是：
/// 1. 登记册如实展示（`SourceRegistryPage`，用户点得到）；
/// 2. 投诉下架通道可用（版本化禁用清单，旧版本也生效）；
/// 3. 默认源仅限「无付费墙、无 DRM」的公开聚合站。
List<String> unverifiedButDefaultEnabled(Iterable<String> defaultEnabledIds) {
  final out = <String>[];
  for (final id in defaultEnabledIds) {
    final r = registrationOf(id);
    if (r == null) {
      out.add(id);
      continue;
    }
    if (!r.hasExplicitAuthorization) out.add(id);
  }
  return out;
}
