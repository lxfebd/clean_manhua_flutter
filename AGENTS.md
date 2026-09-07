# AGENTS.md — 星漫匣（XingManXia）AI 协作入口

> 本文件是 AI 进入本项目**首先需要通读**的说明：验证方式、目录地图、开发铁律、交接清单。
> 配套文档：`DESIGN.md`（视觉规则）、`architecture.md`（架构与数据流）、`development.md`（命令与回归清单）、
> `TODO.md`（任务与进度）、`user-guide.md`（功能说明）、`component-api.md`（组件契约）、`project-overview.md`（整体说明）。

---

## 0. 一句话

**星漫匣** 是一个 Flutter 多源聚合 App：漫画 / 番剧（动漫）/ 小说三合一，多源适配、可离线缓存、带本地导入与 TTS 朗读。

- 仓库：`https://github.com/lxfebd/clean_manhua_flutter`（master）
- 本地路径：`J:\xiangm_transfer\xiangm\back\clean_manhua_flutter`
- 应用名：星漫匣｜包名 `com.xingmanxia.app`
- 技术栈：Flutter 3.44 / Dart 3.12，Android + Windows + macOS + Linux（iOS 由外部自行编译）

---

## 1. 进入项目第一步（硬性要求）

1. **通读本文档** + `architecture.md`（30 分钟能上手全貌）。
2. **跑验证**，不要相信任何"已完成"声明（历史教训：声称完成的功能实际编译不过）：
   ```bash
   flutter analyze          # 必须 0 问题
   flutter test             # 回归清单，见 development.md
   ```
3. 打开 `TODO.md` 确认当前任务与优先级；改动前先看对应模块在 `architecture.md` 中的位置。
4. 每个功能完成后：`flutter analyze` + 相关回归测试 → 提交 → 推送 → **GitHub Actions 确认构建成功**。

## 2. 目录地图

```
lib/
├── main.dart               # 入口：首帧后 init LocalStore/UpdateChecker/Net/WebDAV/书架/内存分档/窗口
├── theme.dart              # 全局主题（Material3，seed 换肤）
├── models/                 # ComicItem 等轻量数据模型
├── sources/                # ★ 源层：漫画源 / 动漫源 / 小说源 / 源配置与聚合（见 architecture.md）
│   ├── source_manager.dart     # 源注册与切换（漫画/动漫/小说三套）
│   ├── source_config.dart      # 源启用/层级/健康度配置持久化
│   ├── comic_source.dart       # ComicSource 抽象契约
│   ├── novel_source.dart       # NovelSource 抽象契约（+ LocalNovelSource 本地导入实现）
│   ├── video_source.dart       # VideoSource 抽象契约
│   ├── dm5_source.dart         # 动漫屋（漫画，默认源）
│   ├── doubao_source.dart      # 豆包（漫画，AES 解密）
│   ├── jm_source.dart          # 禁漫（漫画，反爬）
│   ├── mangadex_source.dart    # MangaDex（漫画，英文兜底）
│   ├── biquge_novel_source.dart  # 笔趣阁（小说）
│   ├── xbiquge_novel_source.dart # 新笔趣阁（小说）
│   ├── local_novel_source.dart # ★ 本地 TXT/EPUB 导入源（不占网络）
│   ├── agedm_video_source.dart # AGE 动漫
│   ├── tvtfun_video_source.dart# TvTFun 动漫
│   ├── xifan_video_source.dart # 稀饭动漫
│   ├── anime1_video_source.dart# Anime1 动漫
│   └── source_http.dart        # 源层 HTTP 工具（携带 UA/签名等）
├── net/                     # ★ 网络/存储层
│   ├── http_client.dart         # 全局 HttpClient（代理/优选IP/超时/重试）
│   ├── image_cache.dart         # 图片内存+磁盘缓存（分平台容量，Isolate 解码）
│   ├── local_store.dart         # 设置/历史/书签/视频记录持久化（merge 式 _updateSetting）
│   ├── bookshelf_store.dart     # 漫画书架 JSON
│   ├── novel_shelf_store.dart   # 小说书架 JSON
│   ├── webdav_sync.dart         # WebDAV 云同步
│   ├── shelf_updater.dart       # 收藏更新检查轮询
│   ├── update_checker.dart      # 版本更新检查
│   ├── download_manager.dart    # 漫画下载
│   ├── video_download_manager.dart # 视频下载
│   ├── circuit_breaker.dart     # 源健康度熔断
│   ├── cf_ip_picker.dart        # Cloudflare 优选 IP
│   ├── smart_prefetch.dart      # 网络感知预取
│   ├── aes_cbc.dart / jm_crypto.dart / jm_scramble.dart  # 源解密（豆包/禁漫）
│   └── route_diagnostic.dart    # 线路诊断
├── ui/                      # ★ 页面层（见 architecture.md 分层）
│   ├── main_shell.dart          # 底部导航壳（首页/书架/我的）
│   ├── home_page.dart           # 首页（漫画分类/排行/搜索）
│   ├── detail_page.dart         # 漫画详情
│   ├── reader_page.dart         # 漫画阅读器（横向/纵向/双页/放大镜/裁边/超分）
│   ├── anime_home_page.dart     # 动漫首页
│   ├── anime_player_page.dart   # ★ 网页播放器（WebView 解析直链 → 切原生）
│   ├── native_player_page.dart  # ★ 原生播放器（media_kit/mpv + Anime4K 超分 + 弹幕）
│   ├── novel_home_page.dart     # 小说首页
│   ├── novel_detail_page.dart   # 小说详情
│   ├── novel_reader_page.dart   # 小说阅读器（段距/缩进/色温/TTS）
│   ├── novel_import_page.dart   # ★ TXT/EPUB 本地导入
│   ├── bookshelf_page.dart      # 书架（漫画/动漫/小说记录 + 书签）
│   ├── settings_page.dart       # 设置
│   ├── profile_page.dart        # 我的
│   ├── toolbox_page.dart        # 工具箱
│   ├── source_manage_page.dart  # 源管理
│   ├── unified_search_page.dart # 统一搜索
│   ├── webview_page.dart / desktop_webview.dart  # 通用 WebView / WebView2 适配
│   ├── responsive.dart          # ★ 响应式布局工具（手机/平板/桌面分档）
│   └── tokens.dart              # ★ 设计 token（S 间距/R 圆角/T 透明度/F 字号）
├── utils/                   # 纯逻辑工具（无 UI 依赖）
│   ├── image_trim.dart          # ★ 漫画自动裁边（Isolate 扫描）
│   ├── image_super_res.dart     # ★ 图片超分（Anime4K，Isolate）
│   ├── anime4k.dart             # Anime4K 内核
│   ├── danmaku.dart             # 弹幕解析
│   └── ...
└── ui/widgets/              # 通用组件
    ├── cached_image.dart        # 带缓存/超分的图片组件
    ├── jm_scramble_image.dart   # 禁漫解扰图片组件
    ├── danmaku_overlay.dart     # 弹幕浮层
    ├── player_widgets.dart      # 播放器共用组件（面板/进度条/按钮）
    └── settings_row.dart / state_view.dart / motion.dart / tap_target.dart ...
test/                       # 单元/回归测试（regression_*.dart 已 gitignore，勿提交）
ci_parts/                   # CI 工作流片段
```

## 3. 开发铁律（违反会返工）

| # | 铁律 | 说明 |
|---|------|------|
| 1 | **不本地全量构建** | 一切以 `flutter analyze` + 定向测试为准，release 由 GitHub Actions 构建。 |
| 2 | **绝不 `git add` regression 测试** | `test/regression_*.dart` 被 gitignore，是本地回归资产。 |
| 3 | **设置一律 merge 式持久化** | `LocalStore._updateSetting(key, value)` 增量写；`novel_read_settings` 也是 merge。 |
| 4 | **新建 UI 从 tokens 取值** | `S` 间距 / `R` 圆角 / `T` 透明度 / 字号档位，不写散落字面量。 |
| 5 | **页面分层引用** | ui → sources → net → utils，只允许向下依赖；隔离纯逻辑到 `utils/`。 |
| 6 | **播放器叠音零容忍** | 切原生播放器前必须物理移除 WebView（`_killWebMedia` 会置 `_webViewRemoved`），不要只做 JS 静音。 |
| 7 | **Android 可用的同时 iOS 不能坏** | iOS 由外部拿源码自编译；cronet_http 仅 Android 启用，其余平台自动降级 `dart:io`。 |
| 8 | **提交信息用中文** | 描述清楚"做了什么 + 为什么"。提交前检查 Mimosa git-gate hook 状态（见 development.md）。 |
| 9 | **版本号递进** | 每次提交 bump `pubspec.yaml` version（`X.Y.Z+N`）。 |
| 10 | **推完必须看 CI** | 推送后轮询 GitHub Actions，`completed successfully` 才算完。 |

## 4. 当前状态（截至 2026-09-07）

- 版本：1.4.7+24
- 已完成：阅读器性能根治、三批体验深化（裁边/排版/色温/倍速）、WebDAV、更新提醒、预下载、TXT/EPUB 导入、TTS、双播放器叠音根治
- 进行中：见 `TODO.md`（按优先级从上往下做，字幕不做）
- 完整路线图与历史：`HANDOFF.md`（交接）、`PROJECT_MEMORY.md`（记忆库，本地不提交）

## 5. 交接 / 换会话

新会话接手：读 `AGENTS.md` → `TODO.md` → `architecture.md` → 跑 analyze + test → 从 TODO 最高优先级开始。
本文档要随项目演进持续更新（新增模块/改架构时同步改）。
