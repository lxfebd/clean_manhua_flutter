/// 源市场 / 能力市场共用的索引地址。
///
/// 两个市场读的是同一份 `index.json`，地址必须一致，所以集中在这里——此前
/// `source_market.dart` 与 `capability_market.dart` 各写一份常量，改一处漏一处。
///
/// 顺序按「同一信任域、不同网络路径」排，实测（2026-10-13，国内网络）同一时刻
/// `raw.githubusercontent.com` 与 `cdn.jsdelivr.net` 的 TLS 连接都被重置，
/// 而 `github.com/…/raw`（301 回 raw，但入口 IP/SNI 不同）与 jsDelivr 的另两个
/// 别名 fastly / gcore 仍 200：只加候选地址就能从「市场整页打不开」变「能开」。
///
/// 刻意不引入第三方 raw 代理（ghproxy 一类）：索引内容决定装进 App 的源定义
/// （URL、选择器、请求头），多一个可篡改的中间方就多一个供应链风险。
library;

/// 索引候选地址（按尝试顺序）。
const List<String> kMarketIndexUrls = [
  'https://raw.githubusercontent.com/lxfebd/xingmanxia-sources/main/index.json',
  'https://github.com/lxfebd/xingmanxia-sources/raw/main/index.json',
  'https://cdn.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json',
  'https://fastly.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json',
  'https://gcore.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json',
];

/// 单个候选地址的超时。
///
/// raw 系在国内常见 8-10s 慢通（不是失败），太短会把它判死；但候选有 5 个，
/// 每个都吃满 30s 会让市场页最坏挂 150s。12s 是「慢通仍能命中」与
/// 「全灭时不至于把 UI 卡死」之间的取值。
const Duration kMarketIndexTimeout = Duration(seconds: 12);

/// 整条镜像链的总预算（5 个候选的合计上限）。
///
/// 单个候选超时只是「这一个网址最多等多久」，5 个全灭时市场页仍会挂最坏
/// 5 × 12 = 60s。给 [Net.getBytesMirrors] 传 totalTimeout 后，整条链合计不
/// 超过该值——预算内慢通的候选仍能命中，全灭时把「市场打不开」从 60s
/// 压到 20s 内，UI 不再长时间假死。
const Duration kMarketIndexTotalTimeout = Duration(seconds: 20);
