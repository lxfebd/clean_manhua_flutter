# project-overview.md — 星漫匣 项目整体说明

> 面向任何人的项目总览：这是什么、技术栈、能力矩阵、路线图、代码库概况。
> 开发者入口见 `AGENTS.md`；架构见 `architecture.md`；视觉规则见 `DESIGN.md`。

---

## 1. 这是什么

**星漫匣（XingManXia）** 是一个 **漫画 + 番剧（动漫）+ 小说** 三合一的聚合阅读/观看 App。

- 聚合多个内容源：动画屋（dm5）、豆包、禁漫（JM）、MangaDex（漫画）；AGE、TvTFun、稀饭、Anime1（动漫）；笔趣阁、新笔趣阁、本地导入（小说）。
- 定位：在一个 App 内完成"找书/看漫/追番/读小说"的完整闭环，多源切换、线路诊断、离线缓存。
- 应用名：星漫匣｜包名 `com.xingmanxia.app`。

## 2. 技术栈

| 层 | 选型 |
|---|---|
| 框架 | Flutter 3.44 / Dart 3.12 |
| 平台 | Android（主力，含 arm64）· Windows · macOS · Linux；iOS 由外部人员拿源码自行编译 |
| 视频 | media_kit（mpv 硬解）+ Anime4K 超分 + WebView 直链解析 |
| 网页容器 | webview_flutter（Android/iOS/macOS）+ webview_windows（WebView2） |
| 图片 | package:image（解码/裁剪）+ 自研 Isolate 超分/裁边/解扰 |
| 状态/存储 | 轻量：JSON 文件书架 + LocalStore 设置（merge 式），无重量级 ORM |
| 网络 | dart:io HttpClient（Android 增强 cronet_http）+ 代理 + Cloudflare 优选 IP |
| 同步 | WebDAV 云同步 |
| 其他 | TTS（flutter_tts）、file_picker、screen_brightness、volume_controller、wakelock_plus、qr_flutter、connectivity_plus |

## 3. 能力矩阵

| 领域 | 能力 |
|---|---|
| 漫画 | 多源聚合、分类/排行/搜索、详情、阅读器（横向翻页/纵向滚动/双页/条漫）、点击放大镜、自动裁边去白边、图片超分、缩放拖动、书签、下载离线、续读 |
| 动漫 | 多源聚合、线路切换、网页解析直链 → 原生播放器（mpv 硬解 + Anime4K 超分）、弹幕、倍速 0.25x~4x、画质滤镜、全屏、自动连播、缓存记录续播 |
| 小说 | 多源聚合、TXT/EPUB 本地导入、阅读器（字号/行距/段距/首行缩进/背景/色温护眼）、TTS 朗读、章节切换 |
| 通用 | 书架（漫画/动漫/小说/书签）、统一搜索、收藏更新提醒、WebDAV 云同步、版本更新提醒、网络感知预下载、源管理（启用/层级/健康度）、线路诊断、响应式（手机/平板/桌面）、桌面窗口记忆与快捷键 |

## 4. 开发流水线

```
本地：flutter analyze（0 问题）+ flutter test（回归）
构建：GitHub Actions（Build APK & Release）— 本地不做全量构建
发布：推送 master → CI 构建成功 → 下载 APK
```

详见 `development.md`。

## 5. 路线图（5 方向 3 阶段）

1. **体验深化**：双页/条漫/裁边/放大镜（✅）→ 小说导入/TTS/色温/缩进（✅）→ 动漫字幕（✖️不做）/画中画/音轨/倍速（✅倍速，🔲画中画/音轨）→ 通用：书架分类/WebDAV（✅）/更新提醒（✅）
2. **架构演进**：插件化源 / 自定义源 DSL / 源健康度调度（🔲）
3. **性能极致**：Impeller / 内存动态适配 / 启动优化懒加载（🔲）
4. **合规安全**：免责声明 / 数据加密 / 请求频率限制（🔲）
5. **生态差异化**：AI 相关 / Web 版 / TV 版 / 年度报告 / 书单分享（🔲，远期）

当前进度明细见 `TODO.md`。

## 6. 代码库概况（约 2 万行 Dart）

```
lib/
├── main.dart / theme.dart       入口与主题
├── sources/   3 套源契约 + 11 个源实现 + 源管理器
├── net/       网络/缓存/存储/同步/下载/熔断/预取
├── ui/        19 个页面 + 响应式 + 设计 token + 通用组件
├── utils/     纯逻辑工具（裁边/超分/解扰/弹幕/解密）
├── models/    轻量数据模型
└── ui/widgets/ 通用组件（缓存图/弹幕/播放器控件等）
test/          单元 + 回归测试（regression_*.dart 不提交）
ci_parts/      CI 工作流片段
```

## 7. 关联文档

| 文档 | 内容 |
|---|---|
| `AGENTS.md` | AI 进入项目须知（验证/铁律/目录地图） |
| `architecture.md` | 分层架构与数据流 |
| `DESIGN.md` | 视觉规则（token/字号/配色/响应式） |
| `TODO.md` | 任务与优先级 |
| `user-guide.md` | 功能使用说明 |
| `development.md` | 开发命令与回归清单 |
| `component-api.md` | 组件与契约 |
| `HANDOFF.md` | 历史交接（内部） |
| `PROJECT_MEMORY.md` | 项目记忆库（本地，不提交 git） |