# 开发时间线：v1.4.3 → 当前（1.4.3+72）

> 本文件是「从 1.4.3 到现在的开发说明」存档版，与 PLANNING.md 章节互相引用。
> 时间跨度：2026-09-10 00:58（dc2af9b，v1.4.3 基线）→ 2026-09-12 02:20（2ff6143，1.4.3+72）。
> 提交数：45 个。版本号规则：每批测试前 +1，不是每个提交都有版本号。

## 怎么读

- **版本号**：`1.4.3+N` 是本地迭代号。基线 v1.4.3=+40（已 push），此后全部未 push。
- **账本**：PLANNING.md 是唯一权威文档，[x]=完成 [~]=部分 [ ]=待办。
- **并行规矩**：docs/parallel-workflow.md 定义并行 AI 任务的模块隔离规则。
- **红线**：任何 GitHub 远程写操作必须先展示清单并获明确同意；colorizer*.dart 归独立 agent，主线程不碰。

---

## 主线一：Web 端（alpha → beta 收口）——1.4.3 内 + 收口期

| 提交 | 内容 |
|---|---|
| （1.4.3 基线内） | Web alpha：PlatformHttp/WebPersist 抽象层 + path_provider 守护清单 |
| f7b71ce | 自定义源 DSL 正则分支崩溃修复 + 全局搜索吞结果修复 |
| 720fe53 | 源切换弹窗横屏/源多时底部溢出修复 |
| a3b192d | Web beta 阅读器阻塞点：图片/下载/本地文件链路 web 守卫 |
| 188aad6 | Web beta 启动崩溃：NovelHomePage _Namespace + CORS 友好提示 |
| 7983767 | Web beta 剩余 io 崩溃面收口：书架动漫下载卡片 + 小说导入文件读取 |
| 2bcb4d1 | Web beta 禁用态：设置页/工具箱平台功能 web 灰置替代报错 |

**结论**：Web 端可编译、可浏览、核心 io 崩溃面已收口。dm5/tobiquge 因 CORS 永久不可用，MangaDex 实测可用。剩余：真浏览器实测。

**代码位置**：`lib/platform/`（PlatformHttp/WebPersist）、各页面的 `kIsWeb` 守卫。

## 主线二：源生态 —— +46 ~ +48

| 版本 | 提交 | 内容 |
|---|---|---|
| +46 | 86eab33 | 并行收口：DSL 视频/小说源绑定 + 启动补检（B-6）+ 本地推荐 |
| +48 | 138e4c9 | 源市场补缺：索引缓存回退 + RateLimiter 管控 + 已装源可卸载 |

**结论**：源市场全链路（CSS+正则两源 demo）本地走通；DSL 支持视频/小说源；_indexUrl 已恢复 GitHub。

## 主线三：批次 A/B 交付（内容功能）—— +49 ~ +51

| 版本 | 提交 | 内容 |
|---|---|---|
| +49 | e3b0974 | 批次C 章节总结：本地纯规则摘要（无模型依赖） |
| +50 | 2ad8d31 | 书单海报导出：封面网格 PNG 保存（批次A验收项） |
| +51 | c2cb8d0 | 书单导入：剪贴板解析 + 跨源搜索入架（批次A验收项） |
| +72 | 2ff6143 | 书单分享：share_plus 系统分享面板（文本+海报图） |

> 注：字幕 SRT、年度报告、书单导出在 1.4.3 基线内已交付（批次A 其余项）。

## 主线四：技术债收口（P0/P1/P2）—— +47 ~ +58

| 版本 | 提交 | 内容 |
|---|---|---|
| +47 | 34e0fd7 | 备份域补齐 / 自签收敛 / 死代码清理 / 日志收口 |
| +52 | fdd266c | P2 第二批：锁超时对齐 + RateLimiter 排队上限 + imageCache 恢复 + 下载索引防抖 |
| +53 | b087102 | schema 迁移框架：version + 迁移钩子（P2-10） |
| +54 | 15c66cf | P1-12 WebDAV 密钥升级 PBKDF2：v2 写入 + v1 兼容解密 |
| +55 | 8fab1a0 | P1-19 本地导入目录时序守卫：setStoreDir 前置 |
| +56 | 08c0313 | P2 收尾：corrupt 备份统一 + 备份契约文档 + 转出层清理 |
| +57 | 20cc869 | P1-14 regression 测试入库：CI 恢复回归保护 |
| +58 | 068bf45 / bef9f97 | 删除 legacy 图标死文件 + 版本号对齐 |
| （账本） | 1b9b085 / d8fe675 / f074c76 / 0b69843 | P1 账本归拢、design_tokens 棘轮文档、P2-7 维持现状、状态同步 |

**结论**：P0×2 早已修；P1 主体（14 项）全部处理（修/验证/标记维持）；P2 核心完成。已知遗留：P1-9 连接策略注明、P2-15 棘轮为纯文档门禁。

## 主线五：AI 漫画上色（批次C）—— +59 ~ +61

| 版本 | 提交 | 内容 |
|---|---|---|
| +59 | af9c194 / 00d0fb9 | 上色全链路：TFLite Isolate 推理 + 设置页开关/模型导入 + 阅读器接入；MuMu 实测修复 |
| +60 | 6e58502 | 推理跑通：DDColor 协议锁定（gray[0,1]+ab0）+ skip 重试 + 互斥锁竞态修复 |
| +61 | 86c5233 | **手机上色撤下，仅桌面端保留**（用户实测反馈糊+不上色） |

**结论**：桌面端 MuMu 实测 2.8-4.4s/页。**当前状态：桌面可用，手机端已撤**。后续方向（独立调研，不占主线）：DDColor-tiny INT8 + NCNN + 分块推理。

**代码位置**：`lib/colorizer*`（colorizer_backend.dart 等）+ `ai-coloring-research/` 独立目录。模型权重用户自备。

## 主线六：TV 适配 + CI —— +63 ~ +67

| 版本 | 提交 | 内容 |
|---|---|---|
| +63 | dacdada | 播放器系统级画中画 PiP（Android 8+）+ 按钮接入 |
| +64 | 74ccbb8 | CI 增强：split-per-abi 多架构包 + master 分支夜间内测 Pre-release |
| +65 | fcfa250 | TV 基础期：leanback 声明 + 遥控器 D-pad 焦点导航 |
| +66 | bf97c05 | TV 增强期：播放器媒体键映射 + 启动器 banner |
| +67 | 568d8cc | TV 10ft 可聚焦化：PressableScale focusable + 首页/动漫/书架卡片接入 |

**结论**：36 项目标真编码项全部收官（3ea50d3 / 1a0f92f 账本确认）。剩纯实测项（真机视觉确认）。

## 主线七：能力插件化（最近的大架构动作）—— +68 ~ +72

| 版本 | 提交 | 内容 |
|---|---|---|
| +68 | 041f110 | 框架 M1：CapabilityPlugin/Manager/Runtime + 演示能力（章节字数统计）+ 能力中心 UI，MuMu 实测闭环 |
| +69 | 2286cf0 | 桌面播放器真全屏：window_manager.setFullScreen（页面内全屏→占满屏幕） |
| M2 | f42e72b | 桌面原生构件链路：FFI 加载真实 DLL + SHA256 钉死 + 失败明确原因 |
| +71 | ad1d2b4 / bf779d7 | M3: Android jniLibs 打包演示原生构件（per-ABI .so + gradle sha256 守卫）+ 验收勾选 |
| M4 | 29845e0 | M4 契约文档（只读调研，不碰 colorizer*.dart） |
| +72 | 2ff6143 | 书单分享 + 并行协作规矩 |

**结论**：
- M1/M2/M3 完成且 MuMu 实测通过（自测 sum=42）。
- M4 是契约文档（docs/colorizer-capability-contract.md），不是代码；待用户评审后才写 metadata shell。
- 关键技术决策：colorizer 通过**主 isolate 直调 manager**，不包 CapabilityRuntime.run（Isolate 内单例恒降级）。
- M4 缺口表：批量/取消/进度/algoVersion/路径注入；目录冲突（support/colorizer/ vs .model_cache/）待统一。

**代码位置**：`lib/capabilities/`（CapabilityPlugin/Artifact/Weight/Manager/Runtime）+ `android/app/src/main/jniLibs/<abi>/`。

## 当前状态（1.4.3+72，commit 2ff6143，未 push）

**已完成可跑**：Web beta、源市场、字幕/年度报告/书单全套、章节总结、技术债 P0/P1/P2 主体、TV 全项、能力插件 M1-M3、桌面真全屏、PiP、上色（桌面端）。

**等用户实测**：通知真机存活、share sheet 真机弹出、Web beta 浏览器、桌面侧键、TV 10ft 视觉确认、上色 INT8/FP16 量化评估。

**等用户评审**：M4 契约文档 → 之后才写 ai_colorize_capability.dart shell。

**未 push**：+46 到 +72 全部 39 个提交（自 dc2af9b 之后）。

---

## 各主线与代码目录对照（脑内地图）

| 想找什么 | 去哪看 |
|---|---|
| Web 抽象层 | `lib/platform/`（PlatformHttp/WebPersist） |
| 源市场 / DSL 源 | `lib/sources/` + 源市场相关页面 |
| 书单（导出/导入/海报/分享） | `lib/ui/profile_page.dart` + 书单相关服务 |
| 上色 | `lib/colorizer*`（桌面）+ `ai-coloring-research/`（调研） |
| 能力插件 | `lib/capabilities/` + `docs/colorizer-capability-contract.md` |
| TV | `lib/ui/` focus 相关 + `android/app/src/main/AndroidManifest.xml`（leanback） |
| CI | `.github/workflows/`（split-per-abi + nightly） |
| 原生构件 | `android/app/src/main/jniLibs/` + gradle verifyDemoNativeSha |
| 备份/密钥/迁移 | WebDAV sync + `schema 迁移框架`（+53） |
| 并行规矩 | `docs/parallel-workflow.md` |
