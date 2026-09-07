# architecture.md — 星漫匣 架构与数据流

> 项目整体分层、模块职责、关键数据流与关键实现决策。配套：`AGENTS.md`、`component-api.md`。
> 本文件是 7 层分层架构的权威说明（与 Mellos 架构图 `default` 页一致）。

---

## 1. 分层总览（严格向下依赖）

```
ui-shell (6)    main_shell / bookshelf_page / settings_page / profile_page …
ui (5)          home / detail / reader / player / novel_* / search …
domain (4)      models（ComicItem 等轻量模型）、业务状态
source (3)      comic_source / novel_source / video_source + 各源实现 + source_manager
net (2)         http_client / image_cache / local_store / 各 store / webdav / download …
utils (1)       纯逻辑：image_trim / image_super_res / danmaku / aes / jm_crypto …
native (0)      media_kit / webview / 平台通道
```

铁律：**只允许向下依赖**；纯逻辑必须下沉到 `utils/`，UI 页不得直接写解密/裁剪等算法。

## 2. 模块职责

### 2.1 源层 `lib/sources/`

**三套源契约**（详见 component-api.md）：
- `ComicSource`：漫画 —— 分类 `categories()` / 列表 `listByCategory()` / 排行 `rank()` / 搜索 `search()` / 详情 `detail()` / 章节图片 `pages()`。
- `NovelSource`：小说 —— 详情 `detail()` / 章节内容 `chapterContent()`。
- `VideoSource`：动漫 —— 详情 / 选集 `episodes()` / 播放入口 `playUrl()`。

**注册与切换**：`SourceManager`（漫画 4 源 / 动漫 4 源 / 小说 3 源），带 tier（primary/fallback/disabled）排序；
`SourceConfigStore`（source_config.dart）持久化启用/层级/健康度，UI 变更后调 `enabledSources()` 刷新。

**本地小说源** `LocalNovelSource`（sourceId=`local`）：
- 正文不存 JSON：`{应用目录}/novel_imports/{bookId}/book.json`（元信息）+ `chapters/{seq}.txt`（正文）。
- 章节 id 复合格式 `"{bookId}|{seq}"`，`chapterContent` 凭 chapterId 定位。
- 解析在 Isolate 中进行（大 TXT/EPUB 不阻塞 UI）。

### 2.2 网络/存储层 `lib/net/`

| 模块 | 职责 |
|---|---|
| `http_client.dart` | 全局 `Net`：统一 HttpClient，支持代理、Cloudflare 优选 IP、超时/重试、UA |
| `image_cache.dart` | `ImageCacheManager`：内存+磁盘两级缓存，**分平台容量**（桌面 96MB/移动 40MB），Isolate 解码，`load(url, fetch:)` 统一入口 |
| `local_store.dart` | 设置 + 漫画历史/书签 + 视频记录持久化；`_updateSetting(key, value)` **merge 式**写 |
| `bookshelf_store.dart` | 漫画书架 JSON（绑定 `bookshelf.json`） |
| `novel_shelf_store.dart` | 小说书架 JSON（绑定 `novel_shelf.json`） |
| `webdav_sync.dart` | WebDAV 云同步（书籍/设置），密码仅存占位，AES 加密 |
| `shelf_updater.dart` | 收藏更新检查轮询（后台） |
| `update_checker.dart` | 版本更新检查 |
| `download_manager.dart` / `video_download_manager.dart` | 漫画 / 视频下载 |
| `circuit_breaker.dart` | 源健康度熔断（配合 SourceConfigStore） |
| `cf_ip_picker.dart` | Cloudflare 优选 IP 直连 |
| `smart_prefetch.dart` | 网络感知智能预取（Wifi 下预载下一话） |
| `aes_cbc.dart` / `jm_crypto.dart` / `jm_scramble.dart` | 豆包 AES / 禁漫签名 / 禁漫图片解扰（Isolate 串行） |

### 2.3 页面层 `lib/ui/`（关键页）

| 页面 | 职责 |
|---|---|
| `reader_page.dart` | 漫画阅读器：横/纵/双页/条漫、放大镜、自动裁边、超分、缩放、书签 |
| `anime_player_page.dart` | ★ 网页播放器：WebView 加载站点页 → 拦截/轮询捕获视频直链 → **切原生播放器** |
| `native_player_page.dart` | ★ 原生播放器：media_kit/mpv 硬解 + Anime4K 超分 + 弹幕 + 倍速 |
| `novel_reader_page.dart` | 小说阅读器：字号/行距/段距/首行缩进/背景/色温 + TTS 朗读 |
| `novel_import_page.dart` | TXT/EPUB 本地导入（file_picker + Isolate 解析） |
| `bookshelf_page.dart` | 书架：漫画/动漫/小说记录、书签、续播 |
| `settings_page.dart` | 全部设置项 |

### 2.4 工具层 `lib/utils/`

- `image_trim.dart`：**漫画自动裁边**。Isolate 单次解码扫描（灰度 `(r*77+g*150+b*29)>>8`，白>250 且行白比≥0.95，连续 3 白线起算），四边限裁 35%、小图/小边跳过；裁边结果按 `url|trim|版本` 磁盘缓存。
- `image_super_res.dart`：Anime4K 超分（Isolate），小图预检跳过。
- `danmaku.dart`：弹幕解析（XML/Bilibili 兼容）。

## 3. 关键数据流

### 3.1 动漫播放（重点，双播放器叠音已根治）

```
书架/首页点播
  → SourceManager.videoById(sourceId).playUrl(videoId, s, e)   // 拿到站点播放页 URL
  → AnimePlayerPage（WebView 加载播放页）
      ├─ _injectApiInterceptor / _hlsHookJs：拦截 resolve-play-url API / Hls.loadSource
      ├─ _videoPollTimer 轮询 _videoPollJs：捕获直链（m3u8/mp4/flv）
      │    ├─ 解析期间持续 _muteWebMedia（静音压制，防止网页抢先出声）
      │    └─ 8 秒超时 _resolving=false → 降级为网页播放（解除静音）
      └─ _onVideoSrcCaptured(src)
           → _killWebMedia()：JS 暂停清源 + about:blank + **物理移除 WebView（_webViewRemoved=true，WebView2 stop）**
           → Navigator.pushReplacement → NativePlayerPage（mpv + Anime4K + 弹幕）
```

**叠音根治要点**：切原生播放器前 WebView 从视图树**同步物理移除**（`_webView()` 顶部 `if (_webViewRemoved) return SizedBox.shrink()`），
转场动画期间旧页不再渲染/出声；`dispose` 兜底同样置位。**禁止只做 JS 静音**（跨域 iframe 杀不到）。

### 3.2 漫画阅读（缓存链）

```
ComicSource.pages(chapterId) → 图片 URL 列表
  → ImageCacheManager.load(url)（内存 → 磁盘 → fetch）
      → 超分（可选，_srKey）→ 裁边（可选，trimKey=`url|trim|版本`）→ 显示
```

- 超分缓存键：`'${_srKey()}'`，裁边开启时 `'${_srKey()}|trim|${algoVersion}'`，避免缓存冲突。
- 低端机：`ImageCacheManager.probeDeviceMemory()` 按内存分档收紧/放开缓存。

### 3.3 本地小说导入

```
novel_import_page: file_picker 选 TXT/EPUB
  → Isolate 解析（archive 解包 EPUB / 编码识别 TXT）
  → LocalNovelSource.store 落盘 novel_imports/{bookId}/（book.json + chapters/{seq}.txt）
  → NovelShelfStore 登记 → 小说书架展示 → NovelReaderPage 读取
```

### 3.4 设置持久化（merge 式）

```
UI 改设置 → LocalStore.setXxx(value) → _updateSetting(key, value)（合并写，不整表覆盖）
novel_read_settings = { fontSize, lineHeight, theme, paragraphGap, firstIndent, colorTemp, … }（merge）
```

## 4. 启动流程（main.dart）

1. 首帧立即 `runApp`（避免灰窗）。
2. 后置 init（各自 try/catch）：`LocalStore` → `UpdateChecker` → `VideoDownloadManager` → 优选 IP 恢复 → **代理恢复** → `WebDavSync.restore` → `ShelfUpdater.restore` → `ImageCacheManager.probeDeviceMemory`。
3. 桌面端：窗口管理（最小 480×640、标题、尺寸记忆）。
4. 绑定书架文件（bookshelf.json / novel_shelf.json）+ 本地导入目录。

## 5. 关键实现决策（为什么要这样）

| 决策 | 原因 |
|---|---|
| 动漫先 WebView 后切原生 | 站点直链需网页内 WASM/API 解密，只有 WebView 能拿到；拿到后必须原生播放（超分+硬解） |
| 切原生前物理移除 WebView | JS 静音杀不到跨域 iframe；物理移除保证零残留音频（双音轨根治） |
| 裁边/超分都走磁盘缓存 + Isolate | 避免每页重复解码；大图处理不阻塞 UI |
| 本地小说正文不存 JSON | 大文件避免全局 JSON 读写卡顿，按章惰性加载 |
| 书架 JSON 独立文件 | 与设置分离，更新检查可独立轮询 |
| cronet_http 仅 Android | iOS 外部编译，平台 API 差异自动降级 |
| 手机/平板/桌面字号分档 | 防止手机被桌面档连带放大（历史教训） |
