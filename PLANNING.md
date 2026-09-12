# 星漫匣 · 跨版本开发基线（资产积累 + 技术债 + 版本优化 + 11 项计划）

> 最后更新：2026-09-09（v1.5.0+20 三件套编码完成，待用户实测）
> 定位：Flutter 全端（Android/iOS/Windows/macOS/Linux）漫画 + 动漫 + 小说三引擎聚合阅读器
> 公开仓库 `lxfebd/clean_manhua_flutter`（master 分支 + v* tag 触发 CI 发布）
> 本文是跨版本长周期开发的基线文档：先资产积累与技术债归纳，再排 11 项计划。

---

## 〇、核心原则

1. **增量复用，不重造**：先查本文件「资产表 + 范式清单」，已有实现（放大镜/双页/条漫/字幕层模板等均部分存在）一律补全而非重写
2. **依赖克制**：新功能优先用项目已有机制（Isolate 管线/串行队列/降级链）；新增 pub 依赖前先在技术债 §4 核对
3. **渐进式重构**：Riverpod 只在新增/大改动的页面落地，不推翻现有 setState 架构
4. **可观测优先**：新代码必须走 ErrorLogger 分级日志（当前四级只用 1/4，P0 债），不留 debugPrint 噪音
5. **低端机兜底**：性能相关改动必须带分级（RAM 分档/机型降级），默认保守
6. **负面决策显式化**：已砍需求（§五）与不做的范围（如不加厂商推送 SDK 到排期）写死，避免反复

---

## 一、资产积累：历史功能资产表

> 每条 = 功能 → 实现锚点（文件:行号）→ 复用要点。11 项计划将直接引用。

### A. 阅读器（reader_page.dart，3251 行，6 个类）

| 功能 | 锚点 | 复用要点 |
|---|---|---|
| 三种阅读模式 | `ReaderMode enum :67-81`；`viewCountOf/pageOfView/viewOfPage :84-100` | 双页/条漫的换算基准，改模式只动这几处 |
| 竖滚=条漫连读 | `_buildBody vertical branch :1832-1900`（ListView + scrollCacheExtent 900px + `_observeLayout :1919-1933` 页高前缀和锚定） | 条漫 OOM 分级从这里做：横向/竖向各档 keepAlive + 超分开关 |
| 放大镜 | `_loupeRadius=72/_loupeZoom=2.2 :181-187`；`_onLongPressStart :990`；`_buildLoupe :1024-1088`；**横向两处排除 :738-739/:356** | 横向放大镜 = 去掉两处排除 + 横屏坐标换算；手势用 raw Listener 不进 arena（不抢翻页） |
| 双页阅读 | `_buildBody double branch :1798-1820`（Row[左, SizedBox(2), 右/黑]）；controller 缓存复用（性能记忆：不重建 PageController） | 缺 RTL 页序对调（item 构建 left=view*2 固定 :1798）+ 横屏自动切换 |
| 四指/双指手势 | `:812/:869` | 新手势照此模式加，别动 tap 区域逻辑 |
| 历史/统计/连读 | `:500 历史`、`_flushStats :1504`、连读 :1912 | 年报数据源 |
| 性能铁律 | 横向 keepAlive 关（防 JM OOM）、横向禁超分、`_pageAnimating` 600ms 兜底、JM 源整体禁超分 | **任何阅读器改动先过这四条** |

### B. 播放器

| 功能 | 锚点 | 复用要点 |
|---|---|---|
| media_kit 播放 | `native_player_page.dart` `p.stream.position :456-461`（~10Hz）vs `_pos`（5Hz 节流 :405-422） | 字幕帧级同步用 position 流，不要新起 timer |
| 弹幕层 | `lib/ui/widgets/danmaku_overlay.dart`（items+position+settings；sorted cursor+Ticker；CustomPaint+TextPainter） | **字幕层直接以它为模板**（`_stage Stack :1321-1382`，danmaku insert :1346-1354） |
| 音轨切换 | `:483-487` | 字幕轨道选择交互可抄 |
| 倍速档位 | `_setSpeed :536`，档位表 :2303（0.25~4x 已含） | **不再扩展倍速**（已砍决策） |
| 观看记录双轨 | `LocalStore.recordVideo`（书架）+ `video_progress`（续播秒，裸文件） | 技术债 P1-3：video_progress 并入 LocalStore 队列 |

### C. 网络 / 存储 / 图片

| 模块 | 锚点 | 复用要点 |
|---|---|---|
| Net 全局 HTTP | `lib/net/http_client.dart` `Net :121`；`getBytesAuto :467`（Cronet/优选IP/dart:io 三分支）；`buildUrl :588` | Web 端抽象层（PlatformHttp）从这里抽；`getBytesAuto` 吞 timeout 是 P1 债 |
| 限流 | `RateLimiter :23`（3req/s 令牌桶 + 并发≤5）；`_retryable :351`（Socket/Timeout/Handshake/5xx/429） | 源市场拉索引、更新检查都受它管 |
| 图片降级链 | `image_deg.dart normalizeUrl :39`（剥 @jm:）→ `image_cache.dart` 内存/磁盘分档（`:68-72` 24/40/64MB，桌面 96MB）→ `_maybeTrimDisk :290`（同步全目录扫描，P1 债） | 内存 key 归一化 bug `:213,220`（P1-6）；`load() 查 norm 但 _putMem(url)` |
| 超分管线 | `image_super_res.dart`（compute+mutex+30s/2min+`maxEdgeOf` >1400px 跳过）；`jm_scramble.dart`（纯 Dart 解码，单张 200-800ms 是最大卡顿债） | 本地 AI 上色的 Isolate 模板；互斥锁超时错配是 P2 债 |
| LocalStore 持久化 | `local_store.dart`（845 行，86 static 成员）：串行写队列 `_writeQueues :273-279`；`addReadingSeconds :595-607`（**唯一读改写整体串行做对的**） | 所有数据域统一走这里；备份 12 域 `collectBackup :779` / `restoreBackup :800`（不对称，P1 债） |
| 书架存储 | `bookshelf_store.dart`（独立 File + `_writeTail` + 300ms 防抖 + `.corrupt-<ts>` 损坏备份 :191-202） | LocalStore 损坏处理应对齐它；与 LocalStore 是两套写栈（P1-8） |
| WebDAV | `webdav_sync.dart`（AES-256-GCM；密钥 PBKDF2-HMAC-SHA256 120k 迭代（v2 魔数 `XMX-SYNC-2:`），旧 v1 裸 SHA256 文件仅解密兼容 :297-352；pull 整包覆盖 :276-282；仅手动同步） | merge 三向判断按手动同步语义保持 |
| 更新检查 | `update_checker.dart`（GitHub release + 平台分选 + `compareVersions :145` 支持 1.2.3+4） | 源市场索引模式抄这里；`downloadUpdate :166` 是死代码 |
| 下载 | `download_manager.dart`（并发 3、30s/张、省空间档压缩）；`video_download_manager.dart`（mp4+m3u8+AES-128；`_persist :603` 无队列裸写，P2 债）；`update_download_manager.dart`（Range 续传+镜像+通知栏） | 三套下载器职责已分，保持 |
| 源体系 | `source_plugin_manager.dart`（8 单例之一）；`custom_source_store.dart importJson :88-116`（single-or-array、validate→upsert，**源市场一键安装唯一入口**）；`CustomSourcePlugin extends SourcePlugin :138`（仅 comic 绑定） | 源市场直接调用 importJson，补 video/novel 绑定 |

### D. 已发布的稳定性 / 合规资产（勿回退）

- Impeller 显式开启（AndroidManifest）、请求频率限制、免责声明、备份 AES-256-GCM、错误日志按天滚动 7 天 + 一键导出、WebDAV 同步、代理单源生效+失败回退直连、Cronet 有代理必须跳 dart:io
- 阅读器性能 5 连修（controller 缓存/keepAlive 关闭/横向禁超分/翻页 600ms 兜底/JM 禁超分）
- MIUI 四坑（状态栏实心灰、导航栏半透黑、系统字体缩放、高 dpr 图片缓存）+ MuMu 锁横屏永远桌面档（验证手机档需真机或缩窗）

---

## 二、架构地图（现状快照，改动前先对图）

```
lib/ 93 dart 文件 / 43,836 行
├── ui/       7 大页面（reader 3251 / anime_player 3234 / bookshelf 2809 / native_player 2667 / detail 1785 / settings 1766 / home 1497）
│             + profile 1106 / novel_reader 1022 / toolbox 987 / source_manage 991 / main_shell 852 / responsive 1123 …
├── net/      http_client(601, 四职责) / local_store(845) / bookshelf_store / novel_shelf_store / shelf_updater
│             update_checker / update_download_manager / download_manager / video_download_manager
│             webdav_sync / source_health_monitor / error_logger / smart_prefetch / circuit_breaker(疑似死)
├── sources/  source_manager / source_plugin_manager / dsl/（custom_source_store） / local_novel_source
│             comic_source / video_source / novel_source / jm_scramble / aes_cbc / jm_crypto
├── utils/    image_super_res / image_trim / danmaku / aes_cbc …
├── services/ novel_tts_service
├── ui/widgets/ cached_image / danmaku_overlay / mini_player / player_widgets …
lib/ui/tokens.dart(167) + lib/theme.dart(287)：TypeScale 手机/平板双档 + AppTheme.light/dark
启动链 main.dart：同步(:71-101) → 串行(:104-133) → 并行 Future.wait(:136-150) → bindFile(:161-164)
测试：入库 10 个（UI/token 门禁为主）+ 本地 26 个 regression_*（gitignore，CI 跑不到，技术债 P1-14）※ 2026-09-11 复核：29 个 regression 测试已入库被 git 跟踪，此描述过时（详见 P1-14 ✅ 已修）
```

---

## 三、技术债归纳（按严重度，实施时对号入座）

### P0（必须修，启动链/日志正确性）

| # | 债 | 位置 | 修法 |
|---|---|---|---|
| P0-1 | 小说章节**加载成功**误写 ERROR 级日志 + 重复 debugPrint | `novel_reader_page.dart:288,290` | ✅ 已修（2026-09-11 复核）：成功事件改 `ErrorLogger.debug` + 删重复行（`:288-290` 现为 debug 级 + 注释说明不污染错误计数） |
| P0-2 | `UpdateChecker.init()` 并行段双调无幂等守卫 → 静态 `_cached` 并发写、日志版本窗口期错误 | `main.dart:138,142`；`update_checker.dart:46-51` | 加 `_inited` 幂等 + 合并为单次 init |

### P1（该修，数据正确性/可观测/性能）

| # | 债 | 位置 | 影响 / 修法 |
|---|---|---|---|
| P1-1 | 读-改-写只串行写、不串行读 → 并发 toggle 丢更新 | `local_store.dart:329-339,348-362,374-381,394-414,428-439,505-510,718-727` | ✅ 已修：全部变更点已并入 `_enqueue`（21 处）串行队列，"读-改-写"复合操作不再互相覆盖（verified `:421-1082`） |
| P1-2 | `video_progress` 裸读改写 + 永不裁剪 | `native_player_page.dart:650-667`、`mini_player.dart:94-104` | ✅ 已修：收口 LocalStore 队列 + 上限 500 条按最旧裁剪（`local_store.dart:978-1002`），播放器/小窗并发统一走同一路径 |
| P1-3 | `_read` 损坏静默返回 null 丢数据 | `local_store.dart:300-305` | ✅ 已修（1.4.3+47）：对齐 bookshelf_store 的 `.corrupt-<ts>` 备份（`local_store.dart:380-386`） |
| P1-4 | 备份 12 域漏项 + restore 与 collect 不对称 | `local_store.dart:779-815` | ✅ 已修（1.4.3+47）：collect 补 bookmarks/search_history/novel_read_settings/reading_stats/gesture_config/source_plugins/custom_sources/source_health/webdav_config/video_progress/update_check；restore 对称补齐，旧备份缺键自动跳过 |
| P1-5 | 图片内存缓存 key 归一化不一致 | `image_cache.dart:213,220`（查 norm 写 url） | ✅ 已修：`_putMem(norm, ...)` 全收口（`:184,200,238,244`），`load()` 入口 norm 化 |
| P1-6 | `_maybeTrimDisk` UI 线程同步全目录扫描（2000 文件 × 4 sync 调用） | `image_cache.dart:290-311` | ✅ 已修（1.4.3+54）：改单次惰性扫描（async 流式 + where 过滤，非阻塞累计），磁盘写后异步触发不阻塞 UI 线程 |
| P1-7 | `getBytesAuto` 吞 timeout 参数 | `http_client.dart:467-474` | ✅ 已修：timeout 透传（`getBytesAuto` → `_getBytesOnce`/`_getWithFallback` 全链路带参，`:301-324,409-416`） |
| P1-8 | 三套重复持久化栈 + 双写路径 | `local_store.dart` vs `bookshelf_store.dart`/`novel_shelf_store.dart` | 提取公共「串行队列+损坏备份」基类（低优先，功能正确性已在）；备份契约文档化 |
| P1-9 | 每请求 `client.close(force:true)` 无连接复用 | `http_client.dart:376,497,551` | 主体走 Cronet 连接复用；dart:io 兜底因优选 IP/代理每请求新建（有意的连接策略，`client.close()` 仅剩探活路径 :527） |
| P1-10 | `badCertificateCallback => true` 四处放行 MITM | `http_client.dart:186,210,223`、`webdav_sync.dart:158`、`update_download_manager.dart:150`、`update_checker.dart:183` | ✅ 已修（1.4.3+47）：新增 `Net.trustSelfSigned` 开关（设置页「网络」区，默认严格校验），5 处含 route_diagnostic 全收敛 |
| P1-11 | `buildUrl` 不 URL 编码（CJK 搜索词） | `http_client.dart:588-600` | ✅ 已修（1.4.3+47）：Uri.replace(queryParameters) 编码 |
| P1-12 | WebDAV pull 整包覆盖无合并；密钥裸 SHA256 无盐无迭代 | `webdav_sync.dart:276-282,326-334` | ✅ 已修（1.4.3+54）：密钥升级 PBKDF2-HMAC-SHA256（120k 迭代 + 固定盐 `xingmanxia-webdav-v2`），新文件写 v2 魔数 `XMX-SYNC-2:`，旧 v1 文件仍可解密（历史备份兼容）；merge 三向判断仍按手动同步语义（pull 全量拉取+本地合并清单），不加自动合并 |
| P1-13 | 日志可观测性≈0：38 处 debugPrint / 21 文件；ErrorLogger 四级只用 1/4 | 启动链 `main.dart:90-175` 8 处、持久化 catch 等 | ✅ 已修（1.4.3+47）：main.dart 10 处 debugPrint 全改 ErrorLogger.warn；剩余按页面改动顺带收敛 |
| P1-14 | 26 个 regression_* 测试 gitignore，CI 跑不到（回归保护=0） | `.gitignore:57` | ✅ 已修（1.4.3+57，commit 20cc869）：29 个 regression_* 测试已入库并被 git 跟踪（`git ls-files` 验证），单个测试可跑通（regression_reader_mode_test 通过）；`.gitignore` 无 regression 规则确认；真网络打活测保持不入库 |
| P1-15 | JM 纯 Dart 解码（单张 200-800ms）无原生降级路径——卡顿根因 | `jm_scramble.dart:88-116` | 长线：Android BitmapFactory MethodChannel；短期：分档限位解码保持 |
| P1-16 | 6 个巨型文件 SRP 违规（35% 代码量） | reader/anime_player/bookshelf/native_player/local_store/http_client | 随 Riverpod 渐进重构顺带拆（不做单独大重构） |
| P1-17 | token 落地不足：344 处内联 fontSize、252 处 borderRadius、66 处硬编码 Color；断点魔法数字 600 | `main.dart:241,280` 应引 `Responsive.compactBreakpoint`；tokens `S.x*` 几乎未用 | 页面级改造时顺带收敛，不单独立项 |
| P1-18 | 本地工作区 229M 构建产物 | `app-debug-ci.apk`(117M) + `downloaded_release.apk`(111M) + `ci_parts/`(118M) | ✅ 已清理（1.4.3+47）|
| P1-19 | `local_novel_source._storeDir` 硬编码兜底 + 启动期覆盖，时序错误时静默写错目录 | `lib/sources/local_novel_source.dart:44-58` | ✅ 已修（1.4.3+55）：`_bound` 标记 + store 惰性 getter 在绑定前被访问时记 ErrorLogger.warn（可观测，不再静默写错目录） |

### P2（可选，随开发顺带清）

| # | 债 | 位置 | 修法 |
|---|---|---|---|
| P2-1 | 死代码：tokens `class D`、`UpdateChecker.downloadUpdate` | 见各文件 | ✅ 已清理（1.4.3+47）；`Net.getCronet`/`WebDavSync.recordPull`/circuit_breaker 非死代码（有调用），保留 |
| P2-2 | 互斥锁超时 30s < compute 2min → 锁对象被覆盖错配 | `jm_scramble.dart`、`image_super_res.dart` | ✅ 已修（1.4.3+52）：acquire 超时 2m30s > compute 2m + identical 守卫防锁错配 |
| P2-3 | RateLimiter 无排队上限、无超时 | `http_client.dart` | ✅ 已修（1.4.3+52）：队列上限 40 + 等待超时 30s 抛错走降级 |
| P2-4 | 未使用依赖：`flutter_svg`/`uuid`/`cupertino_icons`（0 import） | `pubspec.yaml` | ✅ 已删（1.4.3+47） |
| P2-5 | `_legacy_icons/` 2 个已跟踪死文件（app_icon_master_256.png / macos_app_icon_1024_old.png） | 仓库根 | ✅ 已删（1.4.3+57）：全仓零引用确认后 git rm + 目录移除 |
| P2-6 | `native_player_page.dart` 唯一 `print(`（MPV 日志逐行 stdout） | 同上 | ✅ 已改 ErrorLogger.debug（1.4.3+47，:561） |
| P2-7 | `_write` 同步 IO 在 UI 线程 + 超限整文件读回重写 | `error_logger.dart:122-147` | ✅ 已评估（1.4.3+56）：同步小写（append 单行）+ 超限截断写是刻意设计——日志低频、异步化会在进程被杀时丢未 flush 日志；`_pruneOldLogs` 仅启动跑一次（非热路径）。维持现状 |
| P2-8 | `onLowMemory` 永久压 imageCache 无恢复 | `image_cache.dart` | ✅ 已修（1.4.3+52）：记录原预算 + 60s 后 load 入口渐进恢复 |
| P2-9 | 备份恢复对调用方隐式契约（bookshelf/novel_shelf 外部写回） | `local_store.dart:800-823` | ✅ 已文档化（1.4.3+56）：restoreBackup 注释明确 bookshelf/novel_shelf 由调用方单独还原（settings 备份恢复页与 WebDAV pull 均已各自处理），键缺失自动跳过 |
| P2-10 | 无 schema 迁移机制（唯一显式兼容：readerMode 回退旧 horizontal `:456-462`） | `local_store.dart` | ✅ 已修（1.4.3+53）：schema_version + 迁移钩子 `_migrations` map + `_readRaw`/`_MigratorImpl`；v1 框架就绪，3 测试过 |
| P2-11 | 损坏文件备份逻辑三处复制 | bookshelf/novel/LocalStore | ✅ 已修（1.4.3+56）：`utils/file_backup.dart` 新增 `File.backupCorrupt()` 扩展，三处（`bookshelf_store.dart:223` / `novel_shelf_store.dart:39` / `local_store.dart:386`）统一调用 |
| P2-12 | `video_download_manager._persist` 无防抖全量重写 | `video_download_manager.dart` | ✅ 已修（1.4.3+52）：500ms 防抖合并 + flushPersist 落盘（lifecycle 钩子收口） |
| P2-13 | `tmp_render_preview_test.dart` 被 `tmp_*` 规则误伤 gitignore | `test/` | ✅ 已改名（1.4.3+56）：`render_preview_test.dart`，脱离 `tmp_*` 误伤，默认 skip 出图测试 |
| P2-14 | `theme.dart:7` 兼容 export 转出层 | 同上 | ✅ 已删（1.4.3+56）：两 import 者（main/settings_page）均不用 token 符号，export 无引用；theme.dart 保留自身 import ui/tokens（TypeScale） |
| P2-15 | `design_tokens_test` 门禁只校验档位取值，不校验调用点 | `test/design_tokens_test.dart:76-84` | ✅ 已满足（1.4.3+56）：既有「字面量棘轮」门禁（`design_tokens_test.dart:95-138`）即有效的禁止内联 gate——遍历全 lib 统计 fontSize/BorderRadius/alpha 字面量**种类数**并连年下调基线（≤24/22/40）。按种类计数比按调用点更稳（对重构不敏感、防新增字面量），调用点计数易碎不作额外门禁 |

### 技术债修债节奏（原则）

- **P0 随任何开发前先修**（5 分钟内的小改动）
- **P1 跟所在页面/模块的改动一起修**，不单独立大项；数据正确性类（P1-1~4、P1-5、P1-7）优先
- **P2 顺手清**，出现代码改动即收敛

---

## 四、版本优化方向

### 1. 版本号双轨对齐策略
- 现状：pubspec `1.4.2+19` ↔ 线上 tag `v1.4.2`（已对齐）
- 规则：**本地迭代号（+build）可领先**（如 1.5.0+1、+2…）；只有用户确认发布才打 tag + 升 `version:` 主段，tag 触发 CI 出签名 APK/Windows zip 并自动建 Release
- 每个功能完成 = 本地构建验证 + 版本号 +1（build 号），不自动 push

### 2. 发布流程资产化（github.com 被墙时的替代路径）
- 正常：`git tag vX.Y.Z` → push → `.github/workflows/build.yml`（tag `v*` 触发）→ 签名 APK + `xingmanxia-windows-$V.zip` → softprops 自动 Release
- 被墙替代：**github.com 被 DNS/SSL 阻断但 api.github.com 可达** → 用 GitHub REST API 建 tag ref（`POST /repos/{owner}/{repo}/git/refs`，需 40 位完整 sha，`git credential fill` 取 token）→ CI 照常触发 → API 验证 `releases/latest`（匿名 60/h 限流，带鉴权）
- 发布清单（发布前逐一核对）：version 主段 ✓ / README 更新日志 ✓ / 本地实测 ✓ / commit 清单展示并获同意 ✓ / tag + Release ✓

### 3. 测试资产化：26 个 regression 入库方案
- 拆分原则：**纯逻辑/本地资源**（backup_cipher、dsl_e2e、error_logger、image_trim、local_novel_import、memory_tier、proxy、rate_limiter、reader_mode、shelf_updater、webdav_sync、webtoon_anchor 等）→ 入库 CI 必跑
- **真网络打活测**（verify_*、依赖源站/镜像存活性）→ 保持本地跑，标记 `@Tags(['network'])`，CI 用 `--exclude-tags network`
- CI 增加：`flutter test` 全量（入库测试）+ 覆盖率阈值（可选）

### 4. 观测性基线
- 所有新代码日志走 `ErrorLogger`（debug/info/warn/error 四级），`catch` 静默降级必须带日志
- 发布后检查日志导出（设置页导出入口），ERROR 计数应≈0（排除已修 P0-1 的噪音源）

---

## 五、已砍需求与已确认决策（存档，不再复议）

### ❌ 已砍（2026-09-09 用户决定，永久移出排期）
| 方向 | 功能 | 原因 |
|---|---|---|
| 小说 | 无级色温、段间距/首行缩进排版 | 用户认为用处不大 |
| 动漫 | 倍速扩展到 0.25x~4x | 现有档位够用 |
| 生态 | Android TV | 不在 11 项内 |
| 字幕 | ASS 特效全解析 | 只做 SRT + 自动匹配（用户评审决定） |

> 注：小说模块现状（在线聚合 + 本地导入 + TTS）**保留不动**，仅不再新增规划。

### ✅ 已确认决策（AskUserQuestion 定案，后续不再问）
1. **全部 11 项都要做**（不是只做阅读类）
2. **推送通知保留**，但**单独排期**（不塞进 v1.5.0）
3. **双页横屏 = 自动 + 手动**（横屏自动切双页，竖屏回落单页，可手动锁定）
4. **字幕范围 = SRT + 自动匹配**（同目录同名自动加载，无 ASS 特效）
5. **本地 AI 三项全做**：漫画上色 / 章节总结 / 本地推荐
6. **Web 端拆 alpha/beta**：alpha 只保证编译+浏览，beta 才做阅读器
7. **Riverpod 渐进式**：新增/大改页面用，不推翻 setState

---

## 六、v1.5.0 合版开发计划（按批次）

> 用户 2026-09-09 决定：**11 项全部合并为 v1.5.0 一个版本**交付（原 1.5.x/1.6.x 拆分的版本线取消）。
> 批次 A/B/C 按「复用现有基建程度 + 用户感知度」排列，每批完成过 analyze + 全量测试后版本号 +1。
> 已编码项（阅读三件套）已验收清单打勾，标 `<待实测>` 的等用户手工实测。

### 批次 0 —— 阅读体验打磨三件套 ✅ 已编码（v1.5.0+20，待实测）

#### 1. 放大镜支持横向 ✅
- 实现（2026-09-09）：去掉 `_buildReaderStack` 的 `if (!_horizontal)` 排除（loupe 仅按 `_loupeVisible` 渲染）；`_toggleLoupe` 键盘 L 支持横向；横向 `GestureDetector` 加 `onLongPressStart: _onLongPressStart`；`_visibleImageUrl([at])` 支持双页按触点半屏选页 + RTL 页序对调后索引
- 关键决策：长按在竞技场胜出取消 tap，不误翻页；横向 anchor 走 `box.globalToLocal` 兜底（无 raw Listener）；loupe 内 `_ImageView(horizontal: _horizontal)` 与页面布局一致，触点像素不漂移
- 验收清单：
  - [x] 横向每页长按均出放大镜，跟随手指实时移动
  - [x] 放大镜不误触发翻页/双击复位（长按竞技场胜出取消 tap）
  - [x] 纵向行为完全不变（回归，174 测试过）
  - [x] 低端机（RAM<3GB）放大镜打开/关闭无卡顿（复用原图缓存，不重新解码）
  - [ ] <待实测> MuMu 横屏实际手感

#### 2. 双页横屏自动切换 + RTL 页序对调 ✅
- 实现（2026-09-09）：State 加 `WidgetsBindingObserver` mixin，`didChangeMetrics` 跨 600dp 断点自动切换；`_init` 宽屏初始自适应双页；新增 `_switchReaderMode`（页→视图换算保留位置，旋转不丢进度）；`_cycleReaderMode`/`onModeChanged` 手动切换置 `_userModeLocked` 不再自动干涉；RTL 双页 item 构建 lIdx/rIdx 对调（日漫右奇左偶）
- 验收清单：
  - [x] 横竖屏旋转切换 mode 不丢进度（页→视图换算，controller 重建后 jumpToPage）
  - [x] RTL 作品页序正确（第 2 页在右侧、第 3 页在左侧）；非 RTL 不变
  - [x] 手动锁定后旋转不自动切换（_userModeLocked 短路）
  - [x] 双页翻页动画正常（未触碰 _pageAnimating 逻辑）
  - [x] JM 源双页不卡（禁超分保持生效，未改动）
  - [ ] <待实测> 旋转切换动画/页码稳定性

#### 3. 条漫连读 OOM 分级 ✅
- 实现（2026-09-09）：`_verticalCacheExtent()` 按 `ImageCacheManager.memoryBudgetBytes` 分级：≤24MB（<3GB）→ 300px、≤40MB（3-6GB）→ 600px、>40MB → 900px；新增公开 getter `ImageCacheManager.memoryBudgetBytes`（原 `debugMemBudget` 委托之）
- 验收清单：
  - [x] 长章节（500+ 页）竖滚内存曲线平稳（cacheExtent 按档收缩，低端机少保留页）
  - [x] 退出/重进章节进度像素级恢复（_observeLayout 未改）
  - [x] 低端机滚动不卡（预取按档位收缩——预取深度由 SmartPrefetch 网络类型决定，未改）
  - [x] 与双页互斥逻辑正确（模式互斥未改）
  - [ ] <待实测> 低端真机长章节竖滚内存表现

### 批次 A —— 感知强 · 轻量（复用现有基建，每项独立可测）

#### 4. 本地字幕（SRT + 自动匹配）
- 现状：无字幕功能；danmaku_overlay.dart 是现成字幕层模板
- 方案：`subtitle_layer.dart`（抄 danmaku_overlay 结构）；SRT 正则解析（时间轴→字幕项）；`p.stream.position` 帧级同步（倍速自动同步，不新起 timer）；同目录同名 `.srt` 自动匹配 + 手动选择；播放器 `_stage Stack` 加字幕层（:1346-1354 弹幕旁）
- 验收清单：
  - [ ] SRT 时间轴精确（±100ms），倍速 2x/3x 下同步不漂移
  - [ ] 同名 .srt 自动加载；手动选择可换
  - [ ] 全屏/迷你窗/画中画三态字幕可用
  - [ ] 无字幕文件时零开销（不建层）

#### 5. 年度阅读报告
- 现状：`profile_page.dart` 已有 `_ReadingReportSheet :939`（周报）+ `_ReadingStatsCard :434`；数据源 `reading_stats`（daily seconds）、`history`、`video_records` 全本地
- 方案：年报 = 周报扩展（年度时长/品类分布/最爱作品/连续阅读天数/月度热力）；卡片可视化 + 长图导出（复用现有截图/分享链路）
- 验收清单：
  - [ ] 数据与周报口径一致（同源）
  - [ ] 跨年边界（1/1 切换）正确
  - [ ] 空数据年（无阅读）不崩、给空态

#### 9. 书单分享
- 现状：无；书架/详情页已有数据模型
- 方案：文本导出（作品名+简介纯文本）；图片导出（封面网格海报保存相册/系统分享）；导入（识别文本/图片一键入书架）
- 验收清单：
  - [x] 导出→导入→还原字段完整（含源信息）（文本+海报导出 ✅ 2026-09-10；导入=剪贴板解析+跨源搜索入架 ✅ 1.4.3+51）
  - [x] 分享渠道（Android share sheet）可用（2026-09-12，v1.4.3+72：share_plus 12 接入，文本预览弹窗「分享到…」+ 海报保存后「分享图片」按钮；单测 270 绿，MuMu/真机实测待排期）
  - [x] 导入失败给可读错误（无源/格式错）（未找到项逐条列出，支持幂等重试）

### 📦 批次 B —— 生态与平台（独立可测）

#### 6. 更新推送通知（单独排期）
- 现状：`ShelfUpdater` 仅前台 Timer + SnackBar（无通知能力）；`checkNow :97-114` 只比对章节总数，需拆「新章 id 列表」
- 方案：通知渠道（Android 用 `flutter_local_notifications`；后台定时先做**前台常驻/下次启动补检**兜底，不依赖 workmanager 保证——国产 ROM 后台限制）；同一作品 24h 只提醒一次；设置页开关（默认关）
- 国产 ROM 兜底（用户评审要求）：引导页提示加白名单（MIUI/EMUI/ColorOS 自动跳转电池管理设置）；预留厂商推送 SDK 接入位但不排期；真机上提前验证 workmanager 存活率
- ✅ 代码完成（2026-09-10，审计收尾）：UpdateNotifier（MethodChannel + 24h 冷却 + 开关）已有；本次补 2 缺口——web 隐藏「系统通知」开关（settings_page:380）+ `ShelfUpdater.checkOnStartup` 启动补检（main.dart bindFile 后串行）
- ✅ 通知点击核查（2026-09-10）：`showShelfUpdateNotif` 已设 PendingIntent（点击回 MainActivity CLEAR_TOP）；多作品提醒精确跳单作品意义有限，验收按「点击回到书架」口径
- 验收清单：
  - [ ] 模拟器+真机（小米）通知到达（含省电模式开关两种状态）
  - [ ] 重复提醒抑制（24h）正确
  - [x] 应用被杀后：下次启动补检并补发未读提醒（checkOnStartup 已接）
  - [x] 通知点击跳转书架（原生 PendingIntent 已设）

#### 7. 源市场
- 现状：`custom_source_store.importJson :88-116` 是一键安装唯一入口（single-or-array、validate→upsert）；`update_checker.dart` GitHub 拉取+平台分选是索引模式模板
- 方案：源索引 JSON 托管公开 GitHub 仓库；App 内「源市场」页（分类/搜索/一键安装/更新提醒/风险提示）；安装走 importJson，扩 video/novel 绑定
- ✅ 代码完成 + 补缺（2026-09-10，1.4.3+48）：`fetchIndex` 受 RateLimiter 管控 + 成功落缓存，网络失败回退缓存浏览；已安装条目显示卸载按钮（带确认）；前置 DSL binding 已分派 video/novel
- 验收清单：
  - [x] 一键安装/卸载/更新闭环（含失败回退；卸载走 CustomSourceStore.remove）
  - [x] 索引更新拉取（受 RateLimiter 管，失败回退缓存）
  - [x] 源格式校验拒绝恶意 JSON（validate 在 importJson 内强化）
  - [x] 免责声明展示 + 风险提示
  - [ ] <待实测> 真机安装/卸载/更新闭环 + 离线缓存浏览

#### 8. Web 端（alpha → beta）
- 现状：无 web/ 目录；`Net` 基于 dart:io（Web 不可用）；29 文件 import dart:io、17 处 path_provider
- 方案：
  - **alpha（编译+浏览）**：加 `web/`，`flutter build web` 通过；浏览/搜索/详情只读链路走通（`PlatformHttp` 用 fetch）
  - **beta（阅读器）**：阅读/书架/设置可用；下载/本地导入/WebDAV 等平台功能显式禁用并提示
  - 抽象层（用户评审要求）：新增 `PlatformStorage`/`PlatformHttp`，替换散弹式 `if (kIsWeb)`——本地 IO 集中在接口后，dart:io 依赖收敛到桌面/移动实现
- ✅ 代码完成（2026-09-10，1.4.3+45）：启动崩溃修复（NovelHomePage _Namespace）+ io 崩溃面收口（bookshelf 下载卡/novel_import）+ 禁用态（设置页 4 项 + 工具箱 4 工具 web 灰置）+ CORS 友好提示；`flutter build web --release` 成功 + headless 0 console 错误
- 验收清单：
  - [x] alpha：`flutter build web` 零错，部署后浏览/搜索/详情可用（构建零错 + headless 渲染验证）
  - [ ] beta：阅读器翻页/进度/书签可用（需真实浏览器手动实测）；不兼容功能显示禁用态而非报错 ✅
  - [ ] 移动/桌面端行为零回归（194 测试过；真实设备需实测）

### 📦 批次 C —— 架构与差异化（依赖重，最后做）

#### 10. 本地 AI（三项全做，全本地不上传）
- 现状：`image_super_res.dart` 是成熟 Isolate 推理模板；无任何 ML 依赖（需新增）
- 方案：
  - **漫画上色 ⚠️ 手机端已撤下，仅桌面端保留（2026-09-11，1.4.3+61）**：`utils/colorizer*` 组件全部保留（backend 抽象 + io TFLite Isolate 真推理 + web stub + 条件导出），`colorizer_manager.dart` 完整（模型检测/导入/卸载、互斥锁、超时降级原图、低端机 RAM<4GB 隐藏），但**手机端（Android/iOS）从阅读器主流程彻底解除**——`reader_page.dart` `_colorizeEnabled` 加 `DesktopUi.isDesktopPlatform &&` 门闸（手机端恒 false，不推理），`initState` 模型懒加载 `ensureLoaded` 仅在桌面端执行（手机端不加载 225MB 模型，避免无谓 IO/内存）；`settings_page.dart` `_ColorizerSection` 入口仅桌面端显示（手机端回到无入口状态）。**撤下原因**：fp32 在 MuMu 模拟器实测 2.8-4.4s/页（部分超 3s 基线），用户实测反馈画面糊+颜色未上，手机端体验不达标；路线图上仍有 INT8/FP16 量化待做，待量化后再评估手机端是否重新启用。**DDColor 输入协议已锁定（技术资产，桌面端仍可用）**：输入 1×256×256×3 NHWC，通道 0 为 L/100 归一化灰度（L∈[0,1]），ab 通道置 0；输出 1×2×256×256 CHW 已是 Lab 原尺度（约 -128..127）不需 ×110——ImageNet mean/std、gray×3 等其余方案全部近零 ab（灰度假象）；tflite_flutter 0.12.1 `runForMultipleInputs` 在 loading 态静默 skip（残留/全零输出）→ inferAsync 按耗时<100ms 检测 + 最多 3 次重试；互斥锁 TOCTOU 竞态已修（while(true) 重检）；**模型权重不内置**（公开仓库红线 + 体积/授权），用户自备 .tflite 放入文档目录或设置页导入；<桌面端待实测> 真实模型推理跑通 + 性能基线
  - **章节总结 ✅ 已编码（2026-09-10，1.4.3+49）**：`utils/novel_summarizer.dart` 纯规则——拆句过滤（<8字/>120字丢）→ 位置加权（首尾 15% +2）→ 关键词/主角名加权 → 贪心去重按原文序输出 topK；小说阅读器 AppBar「本章摘要」面板。7 单测过；<待实测> 长章节摘要可读性
  - **本地推荐 ✅ 已编码（2026-09-10）**：`utils/local_recommender.dart` 纯规则——按历史聚合作者计数 → 跨启用源搜索该作者 → 过滤已读 → 排序 TopK；冷启动回落热门榜。profile 页右栏「猜你喜欢」横向封面列表，点击跳详情。3 测试过
  - 默认关闭，仅 WiFi+充电 下载模型；低端机（RAM<4GB）隐藏入口（用户评审要求）
- 验收清单：
  - [x] 本地推荐：历史作者聚合去重正确；空历史不请求网络；冷启动给热门兜底
  - [x] 上色管线：状态机/无模型/加载失败降级单测过；web 平台禁用；默认关；失败返回原图不打断阅读；MuMu 实测无模型全链路不崩
  - [ ] 上色单张 <3s（中端机）：fp32 实测 2.8-4.4s/页 部分超 3s 基线，手机端体验不达标已撤下（1.4.3+61）；待 INT8/FP16 量化后手机端再评估，桌面端待实测
  - [x] 离线可用（模型文件在文档目录即断网可用）：本地 tflite 推理无任何网络依赖
  - [x] 默认关闭；低端机隐藏逻辑（RAM<4GB）——MuMu 5.8GB 判非低端，区块完整显示；低端隐藏态由单测兜底
  - [x] 推理不阻塞 UI（Isolate），可取消/超时兜底（2m 计算超时 + 2m30s 锁等待）

#### 11. Riverpod 渐进重构
- 现状：58 个 State class、~90 处 setState、无 Provider/Riverpod；9 个服务层单例
- 方案：先全局状态（主题/设置/书架）→ 页面级（搜索/详情）→ 复杂交互（阅读器/播放器）；**新页面直接用 Riverpod，旧页面改动时才迁移**；`ReaderMode`/`ShelfUpdater` 等先以 `ChangeNotifierProvider` 包住不改内部
- 验收清单：
  - [ ] 迁移后页面行为与 setState 版本逐项一致（对照回归测试）
  - [ ] 每迁移一个页面跑全量测试
  - [ ] 不迁移的页面零影响（不引入混合复杂度到旧页面）

#### 12. 能力插件化 + 能力市场（2026-09-11 调研定案）
> 背景：用户问「像 ai 上色和插帧这些都可以做成插件，需要什么安装上就行，插件化可行性和稳定性」。调研结论：**可行，但要把「元数据壳」与「运行时隔离」分开看**。现有 `SourcePluginManager` 是元数据注册表（install/uninstall/setEnabled/persist/revision 全齐、生命周期钩子齐），但 bind 只是「把实现对象挂进 SourceManager」——同一进程、同一 isolate，**不是运行时隔离**。源插件能安全插拔是因为纯 JSON + 纯 Dart；带 `.so` 的原生算力插件需要外层机制补三件事（见「三件绕不过的事」）。基座 2026 年已成熟：Flutter 3.44 + Dart 3.13 native assets build hooks 稳定、ncnn 有官方 Android 库、Vulkan 走系统 API 免自打包。
- 三件绕不过的事（稳定性边界，方案必须满足）：
  1. **Android 原生库只能构建期 bundle，不能运行期裸下载**：Android 7.0+ SELinux 禁止从应用私有目录 `dlopen()` 裸 `.so`；Flutter 官方 Android c-interop 规范路径是「AAR 作为 Maven 依赖加进 build.gradle」（构建期纳入）。能跑通的两条路：`System.loadLibrary`（安装时解包）或 Dart 3.13+ native assets build hooks（构建期声明、运行期 `Native`/`DefaultAsset` 加载）。**含义**：AI 插件 `.so` 走 Maven/AAR 分发（需自建仓库 + CI 上传），模型权重才走运行期下载（`.model_cache/` 规则）
  2. **Native 崩溃无法隔离**：`DynamicLibrary.open` 同步、ncnn/Vulkan 一个 SIGSEGV 就是整个 Flutter 进程掉，Dart try/catch 抓不住。只能前置防御：FFI 调用全进独立 Isolate（主线程不碰）、调用前校验 ABI/尺寸/对齐/版本、Vulkan 不兼容降级 CPU。做不到「插件崩了主进程还活」
  3. **ABI 矩阵爆炸**：`libncnn.so`（5–15MB）+ rife 模型（10–50MB），一个插帧插件 50–150MB 起，按 `arm64-v8a / armeabi-v7a / x86_64` 三套；CI 已 split-per-abi（145MB→40MB/架构），插件包必须走同样 per-ABI 拆分，装错架构直接崩
- 架构：**新建平行体系 `lib/capabilities/`，不往 SourcePluginManager 里塞**（能力插件 ≠ 源插件：源插件 bind 挂 SourceManager，能力插件 bind 挂 CapabilityRuntime——FFI 句柄/Isolate/权重，生命周期一样但运行边界完全不同，污染现有注册表排序得不偿失）
  ```
  lib/capabilities/
    capability_plugin.dart          ← CapabilityPlugin（SourcePlugin 泛化：category/artifact/weights + 同款 5 钩子）
    capability_plugin_manager.dart  ← 注册表+生命周期+持久化（capability_plugins.json，抄 SourcePluginManager 模式）
    capability_runtime.dart         ← 运行时边界：acquire/probe/run 隔离调用+防御+降级（全项目唯一碰 FFI 的地方）
    capability_market.dart          ← 远端索引拉取（复用 Net/RateLimiter/LocalStore，索引加 capabilities 数组）
    capability_market_page.dart     ← 能力市场 UI（抄 SourceMarketPage 架子）
  ```
  依赖方向 `UI → Manager → Runtime → FFI`；业务代码只碰 Manager（查/装/卸/启/禁）与 Runtime facade（调能力），绝不直接碰 `DynamicLibrary`
- CapabilityPlugin 关键字段：`id / name / category('ai'|'video'|'utility') / version / author / description / builtin / rank` + `CapabilityArtifact?`（url 桌面直链 .dll/.dylib；maven Android 分发；embedded 是否预打包；`sha256` per-ABI 映射）+ `List<CapabilityWeight>`（name/url/sizeBytes/sha256）。内置能力=纯 Dart 壳+bind 空实现（同内置源套路）
- CapabilityRuntime 设计决策（每个都是「为什么」级别）：
  - `acquire(id)` 校验启用+构件已加载+权重已就绪，任一不满足返回带原因失败；`run(id, task)` 独立 Isolate 执行，超时/异常包装 CapabilityResult，连续失败 N 次自动标记 degraded 并通知 Manager 禁用（对应 circuit breaker 思路）
  - **加载失败给明确原因**（「当前机型无 Vulkan 支持」「权重校验失败已重新下载」），不静默降级——静默是上色「糊了+没上色」被骂的根因
  - **版本钉死**：artifact/weights 带精确版本+SHA256，升级走显式 needsUpdate，绝不自动滚动 latest
  - `probe(p)` 前置防御三步：ABI 校验（Platform 当前 ABI ∈ sha256 键）→ 权重 SHA256 校验 → 算力探测（Vulkan 物理设备/内存档位）
- 分发链路：现有源市场索引 JSON 加 `capabilities` 数组（同一 GitHub raw 索引、同一套拉取/缓存/校验逻辑）；安装时序 `validate(平台/字段/SHA256) → 落 capability_plugins.json → Manager.install → Runtime.probe → 提示下载权重(进 .model_cache/)`。**平台分发**：桌面（Windows/macOS）直链下载到应用支持目录 → `DynamicLibrary.open(绝对路径)`（无 SELinux 限制，先在这验证全链路）；Android 走 Maven/AAR 构建期纳入 + per-ABI 产物，权重运行期下载
- UI：`CapabilityMarketPage` 逐字复用 `SourceMarketPage` 架子（列表/已安装·需更新角标/一键安装+风险确认/卸载+数据保留说明/启停开关/SnackBar），入口放设置页或工具箱，与「源市场」并列
- 落地里程碑（每步版本+1、本地实测、commit 不 push）：
  - **M1 框架落地**：CapabilityPlugin/Manager/Runtime 骨架 + 一个纯 Dart 演示能力（如「章节字数统计」）走通 安装→启用→调用→禁用→卸载；MuMu 实测 + 单测
  - **M2 桌面原生加载**：Windows 端 FFI 加载真实 `.dll`，验证 下载→SHA256→load→Isolate 调用→失败降级；桌面实测
  - **M3 Android 接入**：Maven/AAR 渠道 + per-ABI 产物 + 权重 `.model_cache/` 下载；真机/MuMu 实测
  - **M4 对接独立 agent**：与 colorizer 团队对齐契约（输入/输出/互斥/目录），本线只接 metadata shell + 市场条目；契约文档 + 联调
- 验收清单：
  - [x] M1：演示能力全流程（装→启→调→禁→卸）MuMu 实测 + 单测绿（2026-09-11，v1.4.3+68）
  - [x] M2：桌面 FFI 全链路（SHA256→Isolate load→调用→降级）单测绿，真实 DLL 加载+调用+失败明确原因（2026-09-11，v1.4.3+70，commit f42e72b）；真实下载（example.com 占位 URL）待桌面 GUI 实测
  - [x] M3：Android per-ABI .so + jniLibs 打包 + 权重下载真机/MuMu 实测（2026-09-11，v1.4.3+71，commit ad1d2b4）；MuMu 实测「原生构件自测」sum(40,2)=42 · version=0x20260911 通过；12 native 测试 + 全量 270 绿；权重 `.model_cache/` 下载仍为 M4 后接
  - [~] M4：colorizer 契约文档 + 联调（**不触碰 colorizer*.dart 代码**，仅 metadata shell）——契约文档已产出 `docs/colorizer-capability-contract.md`（2026-09-11，只读调研）；**核心定案：上色走主 isolate 直调 ColorizerManager（自带锁+超时），不包 `CapabilityRuntime.run`（Isolate 内拿到的 manager 是全新单例恒降级）；目录约定待统一（colorizer 用 `support/colorizer/` 私有 const，能力体系用 `.model_cache/`）；接口缺口待上色团队排期（批量/取消/进度/algoVersion/路径注入）**；metadata shell 已落地（2026-09-12，v1.4.3+73，commit b56813a）：`lib/capabilities/ai_colorize_capability.dart`（AiColorizePlugin，builtin:false 可卸载）+ `CapabilityArtifactStore.downloadWeight`（.model_cache 下载+SHA256）+ `ensureModel()` 过渡期经 importModel 载入 + 能力中心「模型」按钮 + `regression_ai_colorize_capability_test` 4 项；全量 274 测试绿；能力市场（2026-09-12，v1.4.3+74，commit 9612018）：`capability_market.dart`（MarketCapabilityEntry + fetchIndex 复用源市场 GitHub raw 索引/缓存回退/限速，_parse 容忍无 capabilities 数组给空态）+ `capability_market_page.dart`（抄 SourceMarketPage 架子）+ 能力中心 AppBar「能力市场」入口 + `regression_capability_market_test` 7 项；全量 281 测试绿；**待真实权重 URL/SHA256 填入（发布时）**
  - [x] **插帧（AI 视频补帧）子项**——调研完成（2026-09-12，`docs/frame-interpolation-research.md`）：RIFE 模型（MIT）+ ncnn-vulkan 推理（Android 可复用同一推理代码走 maven AAR）；**完全落在现有 CapabilityPlugin 契约内，不改框架**（id `ai.frame.rife`、category `video`、builtin:false、artifact=桌面 .dll/.so 直链 + Android maven、weights=模型文件走 .model_cache/）。**F0 立项确认 + F1 桌面 PoC 完成（2026-09-12）**：预编译 rife-ncnn-vulkan 20221029（431MB 全平台包，含 exe + 13 个模型，**MIT 许可确认**）在 RTX 5090 Vulkan 上跑通真实补帧——太阳中心 f0=120→mid=140（精确中间）→f1=160，宽度不变；对比图 `docs/rife-f1/rife-v46-compare.png`；插件壳 `lib/capabilities/ai_frame_rife_capability.dart`（id `ai.frame.rife`、video 分类、builtin:false、artifact=onnxruntime.dll 占位 + weights=rife.onnx 占位）+ 注册进 restore() + `regression_ai_frame_rife_capability_test` 4 项全绿。**ncnn 自编译卡壳（无 cmake/cl/ninja/Vulkan SDK）→ 按文档 §2.2 fallback ONNX Runtime 路线**；FFI 绑定 + ONNX 模型获取为 F1 收尾项。→ F2 离线补帧导出 → F3 实时补帧（限分辨率档+失败降级）→ F4 Android（暂缓）。
- ⚠️ 红线：M4 之前完全不碰 `colorizer*.dart`；`.model_cache/` 保持为空（权重仅运行时下载）；不 push

---

## 七、开发纪律（红线，必须遵守）

1. **GitHub 红线（2026-09-09 强化）**：任何 GitHub 远程写操作（push / PR / tag / release / 删分支）前，必须先展示操作清单并取得用户**明确同意**；本地 git commit 可以，但绝不私自上传 GitHub
2. **推送时机**：用户本人本地手动实测通过前绝不 push；本地测试 = 用户手动介入；push 前展示 commit + stage 清单并确认
3. **治理**：公开仓库，内部文档/密钥/域名绝不入库（只留 README.md + PLANNING.md 这类公开规划）；绝不 stage `test/regression_*.dart` 中标记不入库的；push 前确认暂存清单
4. **密钥**：relay key 仅通过环境变量 `relay_key` 提供；transit host 已轮换，不得再入 history
5. **排序**：从高到低推进本文件 §六；已砍方向（§五）不再排期
6. **版本**：每个功能本地构建验证后版本号 +1（build 号）；发布需用户确认
7. **提交**：中文 commit message
8. **回归**：入库测试全绿才算完成；P0 债修完即跑全量

---

## 八、2026-09-11 全目标核对 + 由简到繁执行顺序

> 背景：用户提供 5 方向 36 项迭代目标清单，要求「由简单到复杂安排任务顺序」。本日全量核对代码真实状态（非账本记忆），结论：36 项中 22 项已实现、6 项部分实现、8 项未实现。下表是剩余工作的排期基线，覆盖 §六 11 项计划之外的新增缺口。
>
> **2026-09-11 傍晚进度同步**：当日已按序完成封面单独占页（几何纯函数+9 单测）、zip 日志导出、系统 PiP 三项编码，并核对确认音轨切换/变调补偿/年度报告/Impeller/CI-CD 均已存在或完成（见各批 ✅ 标注）。**8 项未实现中 7 项已闭环 + TV 基础期/增强期全部完成（含 10ft 内容卡可聚焦化，1.4.3+67），36 项真编码项全部收官；剩余仅纯实测项（§8.5）与 10ft 大间距视觉微调（需 TV 真机）**。

### 8.1 已实现（22 项，无需排期，仅保留实测项）

双页横屏+RTL、条漫 OOM 分级、图片裁边（image_trim）、放大镜、本地 TXT/EPUB 导入（local_novel_source）、TTS（novel_tts_service）、色温/段间距/首行缩进（novel_reader_page）、SRT 字幕（subtitle_srt）、迷你窗（mini_player）、倍速 0.25-4x、书架分类（bookshelf_store）、桌面快捷键（keyboard_shortcuts）、搜索历史+收藏内搜索、HTTP/Socks5 代理（http_client:183-202）、图片多级降级、自定义源 JSON 导入、源市场（批次B）、源健康度（SourceHealthMonitor）、内存动态适配（memoryBudgetBytes）、启动优化、智能预加载（smart_prefetch）、免责声明（settings_page:526）、备份密码加密（BackupCipher）、全局限流（RateLimiter 3/s burst5）、WebDAV 同步（webdav_sync）。

### 8.2 部分实现（6 项，需补强）

| 项 | 已有 | 缺口 |
|---|---|---|
| 更新推送通知 | UpdateNotifier+启动补检 | 国产 ROM 系统通知存活未实测（验收项未勾） |
| 年度阅读报告 | 周报+年度聚合（测试过） | 年度可视化/动效页已补全（2026-09-12，v1.4.3+75，commit 2e60b57）：`year_report_page.dart` 全屏页——柱子逐根生长动画+统计卡+最长连续（`LocalStore.yearReadingStreak`）+单日最长（`yearBestDay`）+空态；周报「查看年度报告」改 push 全屏页，`_YearReportSheet` 删除；+4 逻辑测试，全量 285 绿。剩真机视觉确认 |
| 书单导出 | 文本+海报导出+导入闭环；**share sheet 已接入（share_plus，v1.4.3+72）** | Android 分享面板真机弹出未实测 |
| Web 端 | alpha（build+浏览）✅ | beta 阅读器真实浏览器实测未做 |
| 桌面快捷键 | 体系在 | 鼠标侧键返回/前进未验证 |
| 本地 AI 上色 | 已隔离 | **归独立 agent 专项，本线不碰（红线）** |

### 8.3 未实现（8 项，排期对象）+ 由简到繁顺序

**第 1 批（单文件小改动，风险最低）——2026-09-11 实测后仅第 1 项需编码，第 2/3 项已存在（本批已全部闭环）**
1. ✅ 双页「卷首彩页/封面单独占一页」——已完成（2026-09-11）：`ReaderMode` + `viewCountOf/pageOfView/viewOfPage` 抽到 `lib/ui/reader_mode_geometry.dart`（纯函数可单测），语义改为「≥3 页时第 0 页独占 view 0，从页 1 起两两并排」；itemBuilder 封面视图单页渲染、`_visibleImageUrl`/页码指示器同步适配；新增 `test/regression_reader_mode_geometry_test.dart` 9 项（含往返一致+全覆盖）全过；全量 244 测试绿
2. ✅ 播放器音轨切换——**已存在**（native_player_page `:153` 音轨列表、`:534` 监听、`:2647` 切换面板、`:2673` setAudioTrack），核对时误排，无需编码
3. ✅ 倍速变调补偿——**mpv 默认行为**（native_player 走 `setRate`，mpv `--audio-pitch-correction` 默认开 = 已补偿）；两播放器倍速档均已 0.25~4x 全集，无需编码

**第 2 批（中等，多为已有骨架补全）**
4. ✅ 系统 PiP——已完成（2026-09-11）：原生 `xingmanxia/pip` 通道 + `PipChannel` 封装（install/isSupported/setAspectRatio/enter + `inPip` ValueNotifier），Manifest `supportsPictureInPicture`/`resizeableActivity`，`MainActivity.kt` 实现 `enterPip`/`setPipAspect`/`onPictureInPictureModeChanged`；播放器全屏按钮旁接入 `_toggleSystemPip`（宽高取自 `_vw/_vh`），失败 Snackbar 提示；minSdk 24 + compileSdk 36 天然满足 API 26+；debug APK Gradle 编译过 + MuMu 装机无 FATAL（1.4.3+63）
5. ✅ 本地错误日志导出——已完成（2026-09-11）：`ErrorLogger.exportLogs()` 从合并 txt 升级为 **zip 压缩包**（`archive` 4.x `ZipEncoder` 内存编码，含设备/版本头 `logs.txt` 快速浏览 + 各日 `.log` 独立归档）；设置页保存类型改 zip；`regression_error_logger_test` 升级为解包断言（4 项过）；全量 244 测试绿
6. 更新通知真机实测项——代码已全，等用户真机；本批仅补代码侧缺口

**第 3 批（跨文件，需要规划）**
7. ✅ 年度报告——**已存在**（profile_page `_YearReportSheet`：12 个月柱状图 + 全年总秒数 + 有效阅读天数 + 周报），核对时误排，无需编码
8. ✅ CI/CD 增强——已完成（2026-09-11，本地 commit 74ccbb8，**未 push**）：`build:` job 新增 release 场景 split-per-abi 多架构包 step（`app-*-release.apk` 三档 arm64-v8a/armeabi-v7a/x86_64），artifact glob 已含；新增顶层 `nightly:` job（仅 master push，`concurrency` 取消在途），构建 debug APK 并经 `softprops/action-gh-release@v2` 发布 `nightly-$sha` Pre-release（prerelease: true + 自动生成 release notes）；YAML 缩进结构审查通过；全量 244 测试绿（1.4.3+64）

**第 4 批（大改，最后）**
9. ✅ Impeller——**已存在**（`AndroidManifest.xml` meta-data `io.flutter.embedding.android.ImpellerRenderer` 已开启；既有 Skia 回退注释），核对时误排，无需编码
10. ⚠️ Android TV 适配（遥控器导航+大屏 UI 分支）——**唯一剩余真编码项**，见 §8.4
11. Web beta 实测 / 分享渠道 / 侧键验证——纯实测，等用户排期

**不排入**：AI 上色（专项 agent）、Riverpod 重构（新页面用、旧页面不动，维持渐进，不单独立项）。

**新增线（2026-09-11 调研定案，非 36 项内）**：能力插件化 + 能力市场（AI 上色/插帧做成按需安装插件）——见 §六 批次 C 第 12 项，含可行性结论（三件绕不过的事）、架构、稳定性边界、M1–M4 落地里程碑。

### 8.4 Android TV 适配（唯一剩余真编码项）

> 范围评估（2026-09-11）：TV 归入现有 `ScreenSize.large/expanded` 大屏分支（>1200dp），UI 无需大改，缺口集中在 **遥控器焦点导航** 与 **平台声明**。拆两期，先做可本地验证的基础期，再做需真机验证的增强期。

**基础期（2026-09-11 已闭环，1.4.3+65）**
- [x] Manifest 声明 TV 平台：`uses-feature android.software.leanback required=false` + `android.hardware.touchscreen required=false`（保持手机可装、TV 可装）
- [x] TV 启动入口：`android.app.leanback` category 的 intent-filter（LAUNCHER 之外加 `<category android:name="android.intent.category.LEANBACK_LAUNCHER"/>`）
- [x] 遥控器焦点策略：`HoverEffect` 新增可选 `focusable`/`focusNode`（默认 false，桌面/触屏零影响）；聚焦时主色焦点环 + 复用 hover 放大；方向键交给 Flutter 焦点系统、`LogicalKeyboardKey.select`/`enter` 触发 onTap；侧边栏导航项 `focusable: true` 接入；新增 `test/regression_tv_focus_test.dart` 4 项（非 focusable 无焦点、OK/Enter 触发、方向键移动、焦点环渲染）全过；merged manifest 三声明验证生效；MuMu 装机无崩溃；全量 248 测试绿

**增强期（2026-09-11 已部分闭环，1.4.3+66）**
- [x] 播放器遥控器按键：native_player 与 anime_player 的 `_keyHandler` 补齐 TV 媒体键——`select`/`mediaPlayPause`→播放暂停、`mediaFastForward`/`mediaRewind`→±10s、`mediaTrackNext`/`mediaTrackPrevious`→上下集（复用既有 seek/切集路径）；`mediaPause`/`mediaPlay`/`mediaStop` 由 Android 系统在媒体会话层接管不重复处理；MuMu D-pad 中心键（keyevent 23）实测无崩溃
- [x] 启动器封面：新增 `res/drawable/tv_banner.xml`（320×180 VectorDrawable，深墨底+白五角星，与「墨块+星」logo 同构），manifest `<application android:banner>` 引用；aapt 编译通过
- [~] TV 专用首页（10ft UI）——**内容卡可聚焦已闭环**（2026-09-11）：`PressableScale` 新增可选 `focusable`/`focusNode`（默认 false，桌面零影响），聚焦放大 + 主色焦点环 + OK/Enter 触发；首页轮播大卡/热榜网格卡/分类 chip、动漫轮播/网格/分类 chip、书架继续阅读/条目/下载/标记 4 卡共 10 处接入；`regression_tv_focus_test` 增至 6 项全过；全量 250 测试绿；MuMu 装机无崩溃（1.4.3+67）。**剩余：大间距 10ft 布局与聚焦放大动画细节需 TV 真机视觉确认，暂缓**

### 8.5 纯实测项（代码已全，等用户排期）

| 项 | 状态 |
|---|---|
| 更新推送通知真机存活 | UpdateNotifier 链路全，国产 ROM 后台存活未实测 |
| 书单分享 Android share sheet | 代码已接入（share_plus，v1.4.3+72），分享面板真机弹出待实测 |
| Web beta 真实浏览器阅读 | alpha 构建/浏览过，beta 阅读器未在真实浏览器跑 |
| 桌面鼠标侧键返回/前进 | 快捷键体系在，侧键映射未验证 |
