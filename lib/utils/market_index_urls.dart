/// 源市场 / 能力市场共用的索引地址。
///
/// 两个市场读的是同一份 `index.json`，地址必须一致，所以集中在这里——此前
/// `source_market.dart` 与 `capability_market.dart` 各写一份常量，改一处漏一处。
///
/// 排序原则：**先官方直连（可信度最高，能通即用）→ 再回源型第三方镜像（返回
/// 最新）→ 最后 CDN 缓存镜像（可能返回旧内容，仅兜底）**。
///
/// 为什么 jsDelivr 必须排到最后（2026-10-13 实测事故）：jsDelivr 对 `@main`
/// 这类分支引用的缓存 `max-age=7 天`，且**无自助即时 purge**（`?build` 仍回旧
/// 内容、POST 刷新返 405）。发布新索引后 7 天内，raw 已是新版而 fastly/gcore
/// 仍是旧版——若 jsDelivr 排在前面，raw 一旦超时，用户装到的就是**缺新源、
/// 还含已下架死源**的旧市场，且市场 UI 完全看不出异常。GH 代理类回源型服务
/// 实测与 raw 同内容（0.75s / 2.2s），故置于 jsDelivr 之前。
///
/// 关于第三方镜像的信任取舍（诚实版）：索引内容决定装进 App 的源定义（URL、
/// 选择器、请求头），中间方可篡改即供应链风险。但 `index.json` 目前**没有任何
/// 签名/校验字段**，而 jsDelivr 这类第三方 CDN 本来就在候选链中、且是国内网络
/// 下最常实际命中的一环——也就是说「完全走可信通道」从来就不成立，只排除
/// ghproxy 并不能消除该风险。真正闭合它需要「索引签名 + App 内公钥锚定」，
/// 属发布流程架构变更，另行评估。当前顺序保证的是：在**同等信任等级**下优先
/// 拿最新内容、优先用官方直连。
library;

/// 索引候选地址（按尝试顺序，见上方排序原则）。
const List<String> kMarketIndexUrls = [
  // 官方直连：能通就是最新，可信度最高
  'https://raw.githubusercontent.com/lxfebd/xingmanxia-sources/main/index.json',
  'https://github.com/lxfebd/xingmanxia-sources/raw/main/index.json',
  // 回源型第三方代理：与 raw 同内容，国内比 raw 稳且快
  'https://gh-proxy.com/https://raw.githubusercontent.com/lxfebd/xingmanxia-sources/main/index.json',
  'https://ghproxy.net/https://raw.githubusercontent.com/lxfebd/xingmanxia-sources/main/index.json',
  // CDN 缓存镜像：可能命中 7 天旧缓存，仅作最后的「有总比打不开强」兜底
  'https://cdn.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json',
  'https://fastly.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json',
  'https://gcore.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json',
];

/// 单个候选地址的超时。
///
/// raw 系在国内常见 8-10s 慢通（不是失败），太短会把它判死；但候选有 7 个，
/// 每个都吃满 12s 会让市场页最坏挂 84s——故再配 [kMarketIndexTotalTimeout]
/// 给整条链设硬上限。12s 是「慢通仍能命中」与「快速判死换下一个」之间的取值。
const Duration kMarketIndexTimeout = Duration(seconds: 12);

/// 整条镜像链的总预算（所有候选的合计上限）。
///
/// 单个候选超时只是「这一个网址最多等多久」，候选全灭时市场页仍会挂最坏
/// 「候选数 × 单超时」。给 [Net.getBytesMirrors] 传 totalTimeout 后，整条链
/// 合计不超过该值。
///
/// **取值必须覆盖「两个官方直连都慢通失败 + 至少一个回源代理命中」**：国内
/// raw / github.com 各自可能吃掉近 [kMarketIndexTimeout]（12s）才判死，预算若
/// 小于「2×12 + 代理 RTT」，就会在轮到能返回最新内容的回源代理之前耗尽——
/// 等于加了代理却永远够不到，仍旧只能拿 jsDelivr 的旧缓存。30s ≈ 两个 raw 系
/// 各 12s 失败 + 代理 ~5s 命中 + 余量。全灭时（资源篮 / 代理全挂，概率低）
/// 把「市场打不开」压到 30s 内，UI 不再长时间假死。
const Duration kMarketIndexTotalTimeout = Duration(seconds: 30);
