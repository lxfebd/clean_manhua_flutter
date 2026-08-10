# 樱漫盒 Clean · 一体化重做开发计划

> 适用项目：`yingmanhe_clean`（Flutter 多源漫画 + 动漫阅读器）
> 编写依据：产品需求全流程（6 阶段）+ 设计/测试技能 + 现状诊断
> 目标：把"问题一大堆、不好用"的现状，重做成一个**源稳定、好用、可上线**的产品

---

## 0. 现状诊断（为什么不好用）

| 维度 | 现状 | 结论 |
|---|---|---|
| 默认源 | 原默认 MangaDex（英文/非 R18），国内体验差 | ✅ 已改为豆包（国内可用） |
| 禁漫 JM | 旧代码走 web 抓取，阅读页验证码 + 章节正则抓错 | ✅ 已重写为 JSON API + 图片解扰 |
| 哔咔 Picacg | 写死 3 个 CF IP，失效即整源挂死；未登录无引导 | ✅ 已加 DNS 回退；登录引导待 UI 强化 |
| 网络层 | 15s 超时，但优选 IP 不可达时无自愈 | ✅ 已加"候选 IP 轮询 + DNS 回退 + 6s 短超时" |
| 配置 | 域名/IP 全写死在代码里，源挂了只能改代码重发版 | ❌ 需做**可配置化** |
| 缓存 | 无响应缓存、无磁盘图缓存 | ❌ 需补 |
| UI | 信息架构不清晰、源切换/错误态缺失 | ❌ 需重做 |
| 测试 | 无用例、无验收标准 | ❌ 需补 |

**核心根因**：把"外部随时会变的网络/域名"硬编码进代码，且缺少统一的**源健康度/错误/缓存**抽象，导致一个源抖动就拖垮整页。

---

## 1. 产品定位与目标（阶段一 · 需求规划）

- **目标用户**：国内漫画/动漫读者，关注大陆可直连的中文源，也接受海外源（需代理/镜像）。
- **核心场景**：发现 → 搜索/分类 → 进详情 → 读章节 → 加书架/下载 → 续看。
- **业务目标**：国内默认源可用率 ≥ 95%；切源 < 1s 反馈；阅读首屏 < 2s（有缓存）。
- **范围边界**：不做 UGC/社区/付费；R18 内容按平台合规收敛（见风险）。
- **成功标准**：豆包/樱漫默认可用；禁漫/哔咔在可用网络下可读；任一源失效不影响其他源与 App 其余功能。

> 待确认：是否保留动漫视频源（AgedM/TvTFun）？是否在大陆提供 R18 入口？——需负责人拍板。

---

## 2. 信息架构（IA）

```
底部导航：首页 · 分类 · 书架 · 我的
首页
 ├─ 顶部：源切换条（当前源 + 状态灯）
 ├─ 搜索入口
 ├─ 分类快捷（漫画/动漫/排行）
 └─ 内容流（随当前源变化）
分类页 → 分类列表 → 列表流
详情页（漫画）→ 章节列表 / 加入书架 / 下载 / 分享
阅读器 → 竖滑 / 翻页 / 双页 / 缩放 / 预加载 / 源故障提示
我的 → 哔咔登录 / 书架 / 下载 / 源管理 / 设置
源管理页（新增）→ 启用·排序·编辑域名·代理·登录状态
```

**全局规则**：任何源请求失败 → 统一 `SourceResult` → UI 给"可操作"反馈（换源 / 去登录 / 重试），不白屏、不长时间转圈。

---

## 3. 架构与多源稳定性（工程重点）

### 3.1 源层契约升级
在现有 `ComicSource`/`VideoSource` 上增加：
```dart
abstract class ComicSource {
  // 既有：categories/listByCategory/rank/search/detail/chapterPics
  String get id; String get name;
  bool get requiresLogin;          // 哔咔=true
  bool get isEnabled;              // 用户可在源管理关闭
  Future<SourceHealth> health();   // 轻量探测，结果可持久化
}
```
统一返回类型：
```dart
sealed class SourceResult<T> {
  factory SourceResult.ok(T data) = Ok;
  factory SourceResult.empty() = Empty;
  factory SourceResult.error(SourceError e) = Err; // network | needsLogin | unavailable | parse
}
```

### 3.2 可配置化（治本）
把"会变的东西"全部外置：
- `SourceConfig`：域名列表、CF 优选 IP、API Key、是否需要登录、是否启用。
- 持久化（SharedPreferences / 文件），**源管理页可编辑**。
- 远程兜底：内置一份默认配置 + 可选远程配置 URL（域名过期时后台更新，免发版）。

> 这是解决"JM 域名一死就要改代码"的根本手段。

### 3.3 网络层（已部分完成，补全）
- ✅ 优选 IP 轮询 + DNS 回退 + 6s 短超时（`http_client.dart`）。
- ❌ 增加：每 host 的**熔断/重试**（连续失败 N 次标记 unavailable，冷却后自愈）。
- ❌ 增加：响应缓存（按 URL 缓存 JSON，TTL 可配），减少重复请求。
- ❌ 增加：JM / 哔咔**图片 CDN 优选 IP**（当前未配，被墙时破图）。

### 3.4 缓存与图片管线
- 响应缓存（内存 + 磁盘，TTL）。
- 图片磁盘缓存（`cached_network_image` 或自管）。
- 阅读器**预加载**下一章前 3 页；JM 解扰在下载线程做，避免卡 UI。

### 3.5 状态管理
- 现状疑似 `setState` 为主。建议统一到 **Riverpod / BLOC**，便于源切换、书架、登录态跨页共享。

### 3.6 开源项目借鉴（不重复造轮子）

本项目是 Flutter/Dart 多源聚合阅读器，赛道上已有多个成熟开源项目，直接在它们**验证过的架构**上借鉴，比从零设计更稳更快。本工作区已含 `animeko_ref`（Ani）参考代码，另两个同是 Flutter 的项目（Mangayomi / JHenTai）可直接对标，Mihon 是 Source API 设计的标杆。

| 项目 | 技术栈 | 契合点 | 借鉴要点 |
|---|---|---|---|
| **Mangayomi** | Flutter + Dart（源用 Dart/JS 扩展） | 同是 Flutter 多源（漫画+动漫+小说）聚合 | 扩展注册表 `anime_index.json`+`sourceCodeUrl`、源调用流 `getPopular/getLatest/search/getDetail/getPageList/getVideoList`、统一模型 `MPages/MManga/MChapter`、Filter 体系、多语言/多源框架 |
| **JHenTai** | Flutter + GetX + Dio + Drift | 同是 Flutter，重图片/阅读体验 | `extended_image` 高级图缓存、缩略图预加载（优先级队列+并发上限）、`waterfall_flow` 网格、Drift/SQLite 持久化、4 种阅读布局、多线程下载 |
| **Mihon / Tachiyomi** | Kotlin（源 API 标杆） | Source 契约与异常设计 | `Source` 接口（`getPopularManga/getLatestUpdates/getSearchManga/getMangaDetails/getPageList`）、`SManga/SChapter/Page` 模型、`HttpSource`/`ParsedHttpSource` 基类、`FilterList`、结构化异常 |
| **Ani（animeko_ref，工作区已含）** | Kotlin Multiplatform | 多源媒体抽象 + 可配置源 | `MediaSourceInstance`（源+配置+启用，可序列化持久化）、`SelectorMediaSource`（**声明式配置驱动源**：URL/选择器/cookie 全在 config）、`MediaSourceTier`（Primary/Fallback）、`checkConnection()→ConnectionStatus`、`MediaCacheManager`（可插拔 `MediaCacheStorage`+实时 `CacheStatus` 流+状态机）、限流与 `BlockedException(BlockReason)` |

#### 借鉴后的目标架构（升级 3.1–3.5）

1. **源契约对齐 Mihon 调用流 + Mangayomi 模型**（升级 3.1）
   - 抽象接口对齐 Mihon：`getPopular / getLatest / search / getDetail / getChapterList / getPageList`（动漫源加 `getVideoList`）。
   - 统一模型：`Manga / Chapter / Page`（对应 Mihon 的 `SManga/SChapter/Page`，避免各源返回结构各异）。
   - 返回类型用下方 `SourceResult` 密封类。

2. **声明式可配置源 = 治本硬编码**（升级 3.2，直接学 Ani `SelectorMediaSource` + Mangayomi 扩展模式）
   - 一个源 = **引擎代码（不变） + 声明式配置（易变）**：域名列表、请求头、Cookie、登录态、scramble 标记、tier、代理。
   - 配置序列化为 JSON，**持久化到文件/SharedPreferences**，源管理页可编辑；并支持一份内置默认配置 + 可选远程配置 URL（域名过期后台改，免发版）。
   - 可选进化：仿 Mangayomi 做**扩展注册表** `sources_index.json`+`sourceCodeUrl`，社区可提交新源而无需改主工程（M2+ 评估）。

3. **结构化错误 + 熔断**（升级 3.3，学 Ani `BlockedException/ApiFailure` + Mihon 异常类型）
   ```dart
   sealed class SourceResult<T> {
     const factory SourceResult.ok(T data) = Ok;
     const factory SourceResult.empty() = Empty;
     const factory SourceResult.err(SourceError e) = Err;
   }
   sealed class SourceError {
     const factory SourceError.network() = Network;          // 类比 ApiFailure.NetworkError
     const factory SourceError.service() = Service;          // 类比 ApiFailure.ServiceUnavailable
     const factory SourceError.unauthorized() = Unauthorized; // 需登录
     const factory SourceError.blocked(BlockReason r) = Blocked; // Captcha | RateLimited | NotFound
   }
   enum BlockReason { captcha, rateLimited, notFound }
   ```
   - 每 host 熔断：连续失败 N 次 → `CircuitOpen`（停止请求，冷却后 half-open 探测），UI 显示"源暂不可用"。

4. **图片/缓存管线**（升级 3.4，学 JHenTai `extended_image` + Ani `MediaCacheManager`）
   - 图片：`extended_image`（内存+磁盘二级缓存，自带解码+占位+失败重试），替代裸 `cached_network_image`。
   - 预加载：仿 JHenTai「优先级队列 + 并发上限」——可视区上下 N 张预取，弱网可关；JM 解扰在线程池做。
   - 缓存抽象：`CacheManager` 配可插拔 `CacheStorage`（本地目录），暴露实时 `CacheStatus`（NotCached/Caching 百分比/Cached）流，供 UI 显示进度。
   - 持久化：Drift/SQLite 存历史、书架、下载任务、缓存元数据（学 JHenTai）。

5. **状态管理**（升级 3.5）
   - 计划维持 **Riverpod**；如团队更熟 GetX，可参考 JHenTai「生命周期 Bean + 拓扑排序初始化」做 DI（二选一，勿混用）。

#### 落地优先级
- **M1 直接采用**：① 契约对齐、② 声明式配置、③ `SourceResult`+熔断。
- **M2 采用**：④ 图片/缓存管线。
- **评估项**：扩展注册表（仿 Mangayomi），取决于是否要"社区共建源"。

---

## 4. UX/UI 重做（设计）

设计规范（遵循 mobile-app-design / ui-design-zh）：
- 优雅极简 + 蓝色强调；统一间距(4/8/12/16)、圆角(12/16)、阴影、卡片。
- 安全区：状态栏不遮挡、底栏预留 `pb-20`、首屏 `pt-12`。
- 触控热区 ≥ 44pt；源切换/登录/错误态都有明确反馈。

### 关键页面（已出高保真原型 `UI.html`）
1. **首页**：源切换条 + 状态灯 + 搜索 + 分类 + 内容流；源故障显示"该源暂不可用，换个源"而非转圈。
2. **源切换/管理**：列出全部源（豆包/樱漫/哔咔/禁漫/MangaDex + 视频源），显示状态（正常/需登录/不可用），哔咔直接"去登录"。
3. **详情页**：封面/作者/标签/章节网格/加入书架/下载。
4. **阅读器**：竖滑为主，支持翻页/双页/缩放；加载/失败/解扰中均有态；切源失败提示。
5. **我的**：哔咔登录态、书架、下载、源管理、设置（代理/清晰度/关于）。
6. **搜索**：跨源或当前源搜索，结果卡片，空/错误态。

> 视觉稿见 `UI.html`（可点击预览）。

---

## 5. PRD 与验收标准（阶段二）

按 EARS 原则写需求，示例：
- **Ubiquitous**：系统始终在源请求失败时返回 `SourceResult.error` 而非抛未捕获异常。
- **Event-driven**：当用户切换源时，系统应清空旧缓存并重新拉取首页。
- **Unwanted**：若某源连续 3 次请求失败，则系统应将其标记为"不可用"并在源管理页置灰。
- **State-driven**：当哔咔未登录时，系统应隐藏其需要登录的入口并提示去登录。

**验收清单（节选）**
- 默认源豆包可正常浏览/搜索/阅读；切到樱漫同样可用。
- 哔咔未登录 → 明确"去登录"；登录后可读。
- 禁漫在可用网络下能读（含解扰图）；不可用时整页不崩。
- 任一源失效，其余源与 App 其他功能不受影响。

> 交付物：PRD 文档上传**项目资料库**，并创建评审事项给技术/设计/测试负责人。

---

## 6. 研发评审与任务拆解（阶段三/四）

- **设计评审**：页面清单、状态清单（默认/加载/空/失败/禁用/权限不足）、交互边界、设计验收点。
- **研发评审**：技术依赖（网络/缓存/解扰）、接口问题、数据结构、Cloudflare IP 兼容性、Android/iOS 差异。
- **任务拆解**（建议）：
  1. 源层契约（对齐 Mihon 调用流）+ 声明式配置（学 Ani `SelectorMediaSource`）+ `SourceResult`+熔断（P0）
  2. 网络层熔断/重试/响应缓存（P0）
  3. 图片管线 + 阅读器预加载 + JM 解扰线程化（P0）
  4. 源管理页 + 可编辑域名/代理（P1）
  5. UI 重做（首页/详情/阅读器/我的）（P1）
  6. 状态管理迁移 Riverpod（P2）

> 提醒：把技术任务拆成子事项分配给开发，并附上 PRD/设计稿/评审结论。

---

## 7. 测试验收方案（阶段五，test-case-design）

**用例类型**：功能 + 移动端专项（手势/网络/权限/中断/兼容）。
**设计方法**：等价类 + 边界值 + 异常/场景法。
**覆盖范围**：每源的 搜索/列表/详情/章节/阅读；跨源切换；书架持久化；登录流；网络异常（断网/慢网/域名失效/登录过期/解扰失败/验证码）。

**样例用例（节选）**

| 模块 | 用例 | 前置 | 步骤 | 期望 | 类型 |
|---|---|---|---|---|---|
| 源切换 | 豆包→樱漫 | 两源可用 | 首页切源 | 内容流刷新为新源，<1s 反馈 | 功能 |
| 哔咔 | 未登录访问 | 已登出 | 进详情/读章节 | 提示"去登录"，不崩溃 | 异常 |
| 禁漫 | 解扰阅读 | 网络可用 | 打开含 scramble 章节 | 图片正常显示，无错位 | 功能 |
| 禁漫 | 域名全失效 | 模拟 | 拉取首页 | 显示"源不可用，请换源"，不白屏 | 异常 |
| 书架 | 加入/续看 | 已登录 | 加入→退出→重进 | 仍在书架，定位到上次页 | 功能 |
| 阅读器 | 弱网预加载 | 3G | 翻页 | 下一页预加载，失败可重试 | 移动端/网络 |
| 通用 | 断网重试 | 飞行模式 | 任意拉取 | 错误态 + 重试按钮可用 | 移动端/中断 |

> 注：性能压测/自动化脚本不在本技能范围，需另行排期。发现的 Bug 创建事项并关联回 PRD。

---

## 8. 上线复盘（阶段六）

- 上线后观察：源可用率、阅读完成率、崩溃率、切源频次。
- 复盘：哪些源最不稳 → 是否下架/加镜像；解扰错位率 → 回样本微调算法。
- 沉淀：把"源配置/镜像域名"维护 SOP 写入资料库；后续优化点建为新事项。

---

## 9. 里程碑（建议排期）

| 里程碑 | 内容 | 对应阶段 | 交付 |
|---|---|---|---|
| M1 | 源层契约（对齐 Mihon）+ 声明式配置（学 Ani）+ `SourceResult`+熔断（学 Mihon/Ani） | 三/四 | 代码 + 评审结论 |
| M2 | 图片管线 + 阅读器预加载 + 解扰线程化 | 三/四 | 代码 |
| M3 | UI 重做（首页/详情/阅读器/我的/源管理） | 二/三 | UI.html 落地 + 设计验收 |
| M4 | 测试 + 验收（阶段五用例全跑） | 五 | 用例表 + 验收清单 |
| M5 | 灰度上线 + 复盘 | 六 | 复盘报告 |

> 每项需负责人确认排期/资源/上线范围（涉及排期决策请找对应负责人确认）。

---

## 10. 风险与待确认

1. **网络/合规**：禁漫/哔咔在大陆可达性依赖网络环境；R18 内容需按应用商店政策收敛。**需负责人确认边界**。
2. **解扰算法**：JM scramble 重排顺序为社区近似实现，真机样本若错位需微调（已有回样本通道）。
3. **配置下发**：远程配置 URL 需后端/托管，否则仍靠发版更新域名。
4. **无 git 版本控制**：工作区当前无 git，建议立即初始化，避免重做过程丢失。

---

### 附：本次已落地修复（前置工作）
- 默认源改豆包；MangaDex 去 debug print。
- JM 重写为 JSON API + 解扰；阅读页接入解扰组件。
- Net 层候选 IP 轮询 + DNS 回退 + 6s 短超时。
- `pubspec` 增加 `image` 依赖。
