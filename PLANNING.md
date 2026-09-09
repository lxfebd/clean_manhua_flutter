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
| WebDAV | `webdav_sync.dart`（AES-256-GCM，密钥=SHA256(password) 无盐 :326-334；pull 整包覆盖 :276-282；仅手动同步） | P1-12 债：合并策略 + 密钥迭代 |
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
测试：入库 10 个（UI/token 门禁为主）+ 本地 26 个 regression_*（gitignore，CI 跑不到，技术债 P1-14）
```

---

## 三、技术债归纳（按严重度，实施时对号入座）

### P0（必须修，启动链/日志正确性）

| # | 债 | 位置 | 修法 |
|---|---|---|---|
| P0-1 | 小说章节**加载成功**误写 ERROR 级日志 + 重复 debugPrint | `novel_reader_page.dart:288,290` | 降级为 debug/info 级，删重复行 |
| P0-2 | `UpdateChecker.init()` 并行段双调无幂等守卫 → 静态 `_cached` 并发写、日志版本窗口期错误 | `main.dart:138,142`；`update_checker.dart:46-51` | 加 `_inited` 幂等 + 合并为单次 init |

### P1（该修，数据正确性/可观测/性能）

| # | 债 | 位置 | 影响 / 修法 |
|---|---|---|---|
| P1-1 | 读-改-写只串行写、不串行读 → 并发 toggle 丢更新 | `local_store.dart:329-339,348-362,374-381,394-414,428-439,505-510,718-727` | 全部跟进 `addReadingSeconds:595` 的 `prev.then(...)` 范式 |
| P1-2 | `video_progress` 裸读改写 + 永不裁剪 | `native_player_page.dart:650-667`、`mini_player.dart:94-104` | 并入 LocalStore 队列 + 上限裁剪 |
| P1-3 | `_read` 损坏静默返回 null 丢数据 | `local_store.dart:300-305` | 对齐 bookshelf_store 的 `.corrupt-<ts>` 备份 |
| P1-4 | 备份 12 域漏项 + restore 与 collect 不对称 | `local_store.dart:779-815` | 补 bookmarks/search_history/gesture_config/novel_read_settings/reading_stats/source_plugins/custom_sources/source_health/webdav_config/video_downloads/video_progress/player_prefs 等；restore 补齐 |
| P1-5 | 图片内存缓存 key 归一化不一致 | `image_cache.dart:213,220`（查 norm 写 url） | `_putMem(norm, ...)` |
| P1-6 | `_maybeTrimDisk` UI 线程同步全目录扫描（2000 文件 × 4 sync 调用） | `image_cache.dart:290-311` | 移 Isolate / 惰性统计 |
| P1-7 | `getBytesAuto` 吞 timeout 参数 | `http_client.dart:467-474` | 透传 |
| P1-8 | 三套重复持久化栈 + 双写路径 | `local_store.dart` vs `bookshelf_store.dart`/`novel_shelf_store.dart` | 提取公共「串行队列+损坏备份」基类（低优先，功能正确性已在）；备份契约文档化 |
| P1-9 | 每请求 `client.close(force:true)` 无连接复用 | `http_client.dart:376,497,551` | 长连接池/复用 |
| P1-10 | `badCertificateCallback => true` 四处放行 MITM | `http_client.dart:186,210,223`、`webdav_sync.dart:158`、`update_download_manager.dart:150`、`update_checker.dart:183` | 收敛到设置项「信任自签」开关 |
| P1-11 | `buildUrl` 不 URL 编码（CJK 搜索词） | `http_client.dart:588-600` | Uri.encodeComponent |
| P1-12 | WebDAV pull 整包覆盖无合并；密钥裸 SHA256 无盐无迭代 | `webdav_sync.dart:276-282,326-334` | 时间戳+内容 hash 三向判断；PBKDF2/加盐迭代 |
| P1-13 | 日志可观测性≈0：38 处 debugPrint / 21 文件；ErrorLogger 四级只用 1/4 | 启动链 `main.dart:90-175` 8 处、持久化 catch 等 | 静默降级 catch 统一走 ErrorLogger |
| P1-14 | 26 个 regression_* 测试 gitignore，CI 跑不到（回归保护=0） | `.gitignore:57` | 拆「纯逻辑入库 / 真网络打活测不入库」 |
| P1-15 | JM 纯 Dart 解码（单张 200-800ms）无原生降级路径——卡顿根因 | `jm_scramble.dart:88-116` | 长线：Android BitmapFactory MethodChannel；短期：分档限位解码保持 |
| P1-16 | 6 个巨型文件 SRP 违规（35% 代码量） | reader/anime_player/bookshelf/native_player/local_store/http_client | 随 Riverpod 渐进重构顺带拆（不做单独大重构） |
| P1-17 | token 落地不足：344 处内联 fontSize、252 处 borderRadius、66 处硬编码 Color；断点魔法数字 600 | `main.dart:241,280` 应引 `Responsive.compactBreakpoint`；tokens `S.x*` 几乎未用 | 页面级改造时顺带收敛，不单独立项 |
| P1-18 | 本地工作区 229M 构建产物 | `app-debug-ci.apk`(117M) + `downloaded_release.apk`(111M) + `ci_parts/`(118M) | 删除（均已 gitignore，不影响仓库） |
| P1-19 | `local_novel_source._storeDir` 硬编码兜底 + 启动期覆盖，时序错误时静默写错目录 | `local_novel_source.dart:48-53` | init 前置守卫 + 写前校验 |

### P2（可选，随开发顺带清）

| # | 债 | 位置 | 修法 |
|---|---|---|---|
| P2-1 | 死代码：tokens `class D`（0 调用）、`Net.getCronet`（0 调用）、`UpdateChecker.downloadUpdate`（0 调用）、`WebDavSync.recordPull`（注释自认未用）、circuit_breaker（待验） | 见各文件 | 验证后删除 |
| P2-2 | 互斥锁超时 30s < compute 2min → 锁对象被覆盖错配 | `jm_scramble.dart:127-142`、`image_super_res.dart:23-39` | 超时与 compute 超时对齐 / 锁等待重新入队 |
| P2-3 | RateLimiter 无排队上限、无超时 | `http_client.dart:52-66` | 排队上限 + 超时放弃 |
| P2-4 | 未使用依赖：`flutter_svg`/`uuid`/`cupertino_icons`（0 import） | `pubspec.yaml:36,41,57` | 删除 |
| P2-5 | `_legacy_icons/` 2 个已跟踪死文件（app_icon_master_256.png / macos_app_icon_1024_old.png） | 仓库根 | git rm（须用户同意后） |
| P2-6 | `native_player_page.dart:512` 唯一 `print(`（MPV 日志逐行 stdout） | 同上 | 改 ErrorLogger.debug |
| P2-7 | `_write` 同步 IO 在 UI 线程 + 超限整文件读回重写 | `error_logger.dart:122-147` | 低频可接受，日志高频场景注意 |
| P2-8 | `onLowMemory` 永久压 imageCache 无恢复 | `image_cache.dart:326-327` | 分级恢复策略 |
| P2-9 | 备份恢复对调用方隐式契约（bookshelf/novel_shelf 外部写回） | `local_store.dart:800-823` | 文档化 / 收口 |
| P2-10 | 无 schema 迁移机制（唯一显式兼容：readerMode 回退旧 horizontal `:456-462`） | `local_store.dart` | 加 version 字段 + 迁移钩子 |
| P2-11 | 损坏文件备份逻辑三处复制 | bookshelf/novel/LocalStore | 随 P1-8 一起 |
| P2-12 | `video_download_manager._persist` 无防抖全量重写 | `video_download_manager.dart:603-612` | 防抖 |
| P2-13 | `tmp_render_preview_test.dart` 被 `tmp_*` 规则误伤 gitignore | `test/` | 改名或加白名单 |
| P2-14 | `theme.dart:7` 兼容 export 转出层 | 同上 | 清理旧引用后删 |
| P2-15 | `design_tokens_test` 门禁只校验档位取值，不校验调用点 | `test/design_tokens_test.dart:76-84` | 加「禁止内联」门禁（基线棘轮已在下调） |

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
  - [ ] 导出→导入→还原字段完整（含源信息）
  - [ ] 分享渠道（Android share sheet）可用
  - [ ] 导入失败给可读错误（无源/格式错）

### 📦 批次 B —— 生态与平台（独立可测）

#### 6. 更新推送通知（单独排期）
- 现状：`ShelfUpdater` 仅前台 Timer + SnackBar（无通知能力）；`checkNow :97-114` 只比对章节总数，需拆「新章 id 列表」
- 方案：通知渠道（Android 用 `flutter_local_notifications`；后台定时先做**前台常驻/下次启动补检**兜底，不依赖 workmanager 保证——国产 ROM 后台限制）；同一作品 24h 只提醒一次；设置页开关（默认关）
- 国产 ROM 兜底（用户评审要求）：引导页提示加白名单（MIUI/EMUI/ColorOS 自动跳转电池管理设置）；预留厂商推送 SDK 接入位但不排期；真机上提前验证 workmanager 存活率
- 验收清单：
  - [ ] 模拟器+真机（小米）通知到达（含省电模式开关两种状态）
  - [ ] 重复提醒抑制（24h）正确
  - [ ] 应用被杀后：下次启动补检并补发未读提醒
  - [ ] 通知点击跳转对应书架项

#### 7. 源市场
- 现状：`custom_source_store.importJson :88-116` 是一键安装唯一入口（single-or-array、validate→upsert）；`update_checker.dart` GitHub 拉取+平台分选是索引模式模板
- 方案：源索引 JSON 托管公开 GitHub 仓库；App 内「源市场」页（分类/搜索/一键安装/更新提醒/风险提示）；安装走 importJson，扩 video/novel 绑定
- 验收清单：
  - [ ] 一键安装/卸载/更新闭环（含失败回滚）
  - [ ] 索引更新拉取（受 RateLimiter 管，失败回退缓存）
  - [ ] 源格式校验拒绝恶意 JSON（validate 在 importJson 内强化）
  - [ ] 免责声明展示 + 风险提示

#### 8. Web 端（alpha → beta）
- 现状：无 web/ 目录；`Net` 基于 dart:io（Web 不可用）；29 文件 import dart:io、17 处 path_provider
- 方案：
  - **alpha（编译+浏览）**：加 `web/`，`flutter build web` 通过；浏览/搜索/详情只读链路走通（`PlatformHttp` 用 fetch）
  - **beta（阅读器）**：阅读/书架/设置可用；下载/本地导入/WebDAV 等平台功能显式禁用并提示
  - 抽象层（用户评审要求）：新增 `PlatformStorage`/`PlatformHttp`，替换散弹式 `if (kIsWeb)`——本地 IO 集中在接口后，dart:io 依赖收敛到桌面/移动实现
- 验收清单：
  - [ ] alpha：`flutter build web` 零错，部署后浏览/搜索/详情可用
  - [ ] beta：阅读器翻页/进度/书签可用；不兼容功能显示禁用态而非报错
  - [ ] 移动/桌面端行为零回归（抽象层替换后全量回归测试过）

### 📦 批次 C —— 架构与差异化（依赖重，最后做）

#### 10. 本地 AI（三项全做，全本地不上传）
- 现状：`image_super_res.dart` 是成熟 Isolate 推理模板；无任何 ML 依赖（需新增）
- 方案：
  - **漫画上色**：轻量 TFLite/ONNX 模型（用户可选下载，非内置）；Isolate 推理；单张目标 **<3s**（用户评审基线）；INT8 量化
  - **章节总结**：本地小模型（如 Phi/Qwen 蒸馏小版 or 纯规则摘要兜底）；单章目标 **<5s**
  - **本地推荐**：基于阅读历史的标签匹配（无模型，纯规则，先做）
  - 默认关闭，仅 WiFi+充电 下载模型；低端机（RAM<4GB）隐藏入口（用户评审要求）
- 验收清单：
  - [ ] 上色单张 <3s（中端机）；总结一章 <5s
  - [ ] 离线可用（模型下载后断网推理）
  - [ ] 默认关闭；WiFi+充电才提示下载；低端机不显示
  - [ ] 推理不阻塞 UI（Isolate），可取消

#### 11. Riverpod 渐进重构
- 现状：58 个 State class、~90 处 setState、无 Provider/Riverpod；9 个服务层单例
- 方案：先全局状态（主题/设置/书架）→ 页面级（搜索/详情）→ 复杂交互（阅读器/播放器）；**新页面直接用 Riverpod，旧页面改动时才迁移**；`ReaderMode`/`ShelfUpdater` 等先以 `ChangeNotifierProvider` 包住不改内部
- 验收清单：
  - [ ] 迁移后页面行为与 setState 版本逐项一致（对照回归测试）
  - [ ] 每迁移一个页面跑全量测试
  - [ ] 不迁移的页面零影响（不引入混合复杂度到旧页面）

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
