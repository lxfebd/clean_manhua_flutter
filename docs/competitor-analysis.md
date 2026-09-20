# 星漫匣 · 竞品分析

> 调研日期：2026-09-20
> 方法：公开网页 / GitHub / 应用商店公开信息；未做深入实测。
> 目的：回答「市面上有没有这种软件、我们的核心竞争力是什么」；供对外介绍与功能优先级规划参考。

## 一、同类软件地图

市面上的聚合阅读/追番软件分两大类：

- **单品类**：一个 App 只做漫画、或只做动漫、或只做小说。
- **单平台**：绝大多数只做 Android（或只做移动端）；少数跨桌面，但不同时覆盖三种内容类型。

### 1. 漫画类

| 软件 | 平台 | 定位 | 关键能力 | 缺失（与星漫匣对比） |
|---|---|---|---|---|
| [Mihon](https://mihon.app/)（Tachiyomi 精神续作，23.7k★） | 仅 Android | 开源漫画阅读器 | 扩展源体系、本地阅读、追踪器（AniList/Bangumi 等）、分类、备份到云 | 无桌面端、无内置源、无 WebDAV 同步、无画质增强、无动漫/小说 |
| [VeneraNext](https://github.com/cyrilpeng/venera-next) | Android/iOS/Windows/Linux/macOS | Flutter 跨平台漫画阅读器 | **WebDAV 三件套**（数据同步/CBZ 备份/远端漫画库）、JS 扩展 API、瀑布流跨章节阅读 | 只做漫画、无播放器/动漫/小说、无画质增强 |

### 2. 动漫类

| 软件 | 平台 | 定位 | 关键能力 | 缺失（与星漫匣对比） |
|---|---|---|---|---|
| [Aniyomi](https://github.com/aniyomiorg/aniyomi)（基于 Mihon） | 仅 Android | 开源动漫+漫画聚合 | mpv 内核播放器、扩展源、追踪器 | 无桌面端、无超分、无 WebDAV |
| [Animeko (open-ani)](https://github.com/open-ani/animeko)（2.9k★，Kotlin Compose） | Android/iOS/Windows/macOS/Linux | 一站式弹幕追番 | 弹幕聚合（弹弹play 等）、Bangumi 进度云同步、多数据源（ani-subs/BT/Jellyfin/Emby）、VLC/ExoPlayer 内核 | 无超分、无 WebDAV、无本地下载管理、只做动漫 |

### 3. 小说类

| 软件 | 平台 | 定位 | 关键能力 | 缺失（与星漫匣对比） |
|---|---|---|---|---|
| [阅读 Legado](https://gedoor.github.io/) | 仅 Android | 开源小说阅读器 | **书源系统最成熟**（社区书源量级最大） | 仅 Android、无漫画/动漫、无桌面 |

## 二、核心结论：市场上没有"同款"

**没有任何一个软件同时满足：**

1. **多品类**：漫画 + 动漫 + 小说 三端内容一个 App 聚合；
2. **全平台**：手机 + 桌面（Windows/macOS/Linux）+ Web；
3. **自托管同步**：WebDAV 云同步（收藏/历史/进度/设置，非厂商云）；
4. **画质增强**：桌面端超分/画质链路。

> 注意区分「目标」与「现状」：以上是我们的**产品定位（愿景）**。其中多项能力**已经落地**，但也有**尚未落地**的部分（见第四节诚实清单）。对外宣传必须区分，不能把定位当已实现能力。

## 三、核心竞争力（差异化位置）

### 1. 唯一的多品类聚合
漫画 + 动漫 + 小说三合一，一套数据模型（书架/历史/进度统一）。竞品均为单品类：Mihon 只漫画、Animeko 只动漫、Legado 只小说。这是我们最大的差异点。

### 2. 唯一的"手机 + 桌面 + Web"覆盖
Mihon / Aniyomi / Legado 全系仅 Android；跨桌面的 VeneraNext / Animeko 只做单品类。桌面端看漫画/番剧 + 手机端续看的场景目前只有我们能一站覆盖。

### 3. WebDAV 自托管同步（隐私）
收藏、阅读进度、设置通过用户自己的 WebDAV 网盘（坚果云/Nextcloud/群晖）同步，数据不出用户掌控；AES-256-GCM 可选加密。VeneraNext 是同类中唯一也有 WebDAV 的（只做漫画）；Mihon 只有"备份到云"（无 WebDAV 目录/进度级同步）；Animeko 走 Bangumi 云同步（依赖第三方平台）。

### 4. 桌面端画质增强
Anime4K 超分 + mpv 硬解 + 弹幕 + 视频下载管理，是桌面看番场景的差异化体验（Animeko/Aniyomi 均无超分）。

## 四、诚实清单：短板与未落地（必须如实标注）

| 项 | 现状 | 说明 |
|---|---|---|
| AI 插帧/超分 | **未落地** | M0 实测：RIFE 插帧 1080p 实时不可行（RTX 5090 上 0.55–0.79×）、720p 边缘（0.91×）；M1 定位 libmpv 段错误根因（render API × VSScript × librife）。当前只有 Anime4K shader 级超分。**不得宣传 AI 插帧为已实现** |
| Web 端 | **构建失败（存量）** | `dart:ffi` 不可用于 Web（webview_windows/media_kit 依赖链），属既有问题、非本次 UX 改动引入。实际可发布平台 = 手机 + 桌面 |
| 书源/扩展生态 | **弱** | 竞品靠社区生态（Mihon 扩展仓库、Legado 书源社区）赢得用户；我们是自研 DSL + 内置源，生态差距大，短期无法靠"源多"竞争 |
| 本地漫画导入 | 待确认 | VeneraNext 支持 CBZ/ZIP/PDF/EPUB；我们的本地导入能力需对照补齐 |

## 五、竞争叙事建议（供拍板）

> **唯一同时覆盖「漫画 + 动漫 + 小说」三类内容、横跨手机 / 桌面 / Web 的开源聚合阅读器，内置 WebDAV 自托管同步与桌面画质增强。**

- 短期不打"书源生态战"（打不过社区），主打「品类全 × 平台全 × 隐私自托管」占位。
- 对外材料须区分「已实现」（三端聚合、WebDAV、桌面超分）与「规划中」（AI 插帧/超分、Web 端）。
- 后续功能优先级建议结合本清单：先补 Web 端可用性（dart:ffi 隔离）与本地漫画导入，再评估 AI 插帧的替代路线（离线导出/子进程）。

## 附：信息来源
- Mihon: https://mihon.app/ · https://github.com/mihonapp/mihon
- Aniyomi: https://github.com/aniyomiorg/aniyomi
- Animeko: https://github.com/open-ani/animeko · https://myani.org/
- VeneraNext: https://github.com/cyrilpeng/venera-next
- 阅读 Legado: https://gedoor.github.io/
- 社区盘点（Bangumi/Appinn）：https://bangumi.tv/m/topic/group/464931 · https://meta.appinn.net/t/topic/84903
