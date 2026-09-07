# component-api.md — 星漫匣 组件与契约

> 组件 API 与模块契约速查：三套源契约、关键类、通用组件、存储 API。
> 架构分层见 `architecture.md`；涉及文件都以 `lib/` 为根。

---

## 1. 源契约（`lib/sources/`）

### 1.1 `ComicSource`（漫画，`comic_source.dart`）

```dart
abstract class ComicSource {
  String get id;                 // 源唯一 id（如 'dm5'）
  String get name;               // 显示名
  bool get requiresLogin;        // 默认 false
  bool get isEnabled;            // 默认 true
  SourceTier get tier;           // primary / fallback / disabled
  Future<ConnectionStatus> health();          // 连通性探测（源状态灯）
  Future<List<Category>> categories();
  Future<List<ComicItem>> listByCategory(String categoryId, int page);
  Future<List<ComicItem>> rank(int page);
  Future<List<ComicItem>> search(String keyword, int page);
  Future<ComicDetail> detail(String comicId);            // 详情 + 章节列表
  Future<List<String>> chapterPics(String chapterId);    // 章节图片 URL
  // 书架：默认实现走 BookshelfStore
  Future<void> toggleBookshelf(ComicDetail detail);
  Future<List<ComicDetail>> bookshelf();
  Future<bool> isInBookshelf(String comicId);
}
```

**关键模型**：`Category(id, name)`、`Chapter(id, title)`、`ComicDetail(comic, chapters, description, author, …, sourceId)`、
`ComicItem(comicId, name, pic)`（`lib/models/comic_item.dart`，带 author 等）。
> ⚠️ UI 定位源用 `detail.sourceId`，**不要用 comicId 全局反查**（跨源同名 id 会取错源）。

### 1.2 `NovelSource`（小说，`novel_source.dart`）

```dart
abstract class NovelSource {
  String get id; String get name;
  bool get requiresLogin; bool get isEnabled; SourceTier get tier;
  Future<ConnectionStatus> health();
  Future<List<Category>> categories();
  Future<List<ComicItem>> listByCategory(String categoryId, int page);
  Future<List<ComicItem>> rank(int page);
  Future<List<ComicItem>> search(String keyword, int page);
  Future<NovelDetail> detail(String novelId);
  Future<NovelContent> chapterContent(String chapterId);  // 段落 + 上下章
}
// 书架走 NovelShelfStore；toggleBookshelf / bookshelf / isInBookshelf 同漫画
```

**关键模型**：`NovelChapter(id, title, index)`、`NovelDetail(comic, chapters, …, sourceId)`、
`NovelContent(chapterId, title, paragraphs, prevChapterId, nextChapterId)` —— 阅读器渲染依赖这 5 个字段。

**本地导入实现** `LocalNovelSource`（sourceId = `'local'`）：
- 章节 id 复合格式 `"{bookId}|{seq}"`；`chapterContent` 凭 chapterId 反解。
- 存储：`{应用目录}/novel_imports/{bookId}/book.json` + `chapters/{seq}.txt`（正文惰性加载）。
- 启动时 `LocalNovelSource.setStoreDir(dir)` 绑定目录（main.dart），默认回退 `Directory.systemTemp`。

### 1.3 `VideoSource`（动漫，`video_source.dart`）

```dart
abstract class VideoSource {
  String get id; String get name;
  // 详情 / 选集 / 播放入口（站点播放页 URL）
  Future<VideoDetail> detail(String videoId);
  Future<List<VideoEpisode>> episodes(String videoId, String? seasonSlug);
  Future<String> playUrl(String videoId, int season, int episode); // → 站点播放页 URL
}
```

> ⚠️ `playUrl` 返回的是**站点播放页** URL（交给 AnimePlayerPage 用 WebView 解析直链），
> 不是视频直链。真正的 m3u8/mp4 由 WebView 内拦截捕获后交 NativePlayerPage。

### 1.4 聚合（`source_manager.dart`）

```dart
class SourceManager {
  static List<ComicSource> sources;       // dm5/doubao/jm/mangadex
  static List<VideoSource> videoSources;  // agedm/tvtfun/xifan/anime1
  static List<NovelSource> novelSources;  // biquge/xbiquge/local
  static VideoSource? videoById(String id);
  static NovelSource? novelById(String id);
  static Future<List<ComicSource>> enabledSources();      // 配置优先排序
  static Future<List<NovelSource>> enabledNovelSources();
  static Future<bool> isEnabledOf(String id);
  static Future<void> ensureEnabledCurrent();
}
```
- 源启用/层级/健康度配置持久化：`SourceConfigStore`（`source_config.dart`）。
- 源连通性：`circuit_breaker.dart`（熔断）+ `ConnectionStatus`（`source_result.dart`）。

## 2. 网络与缓存（`lib/net/`）

### 2.1 `Net`（`http_client.dart`）— 全局 HTTP 入口
- 统一 HttpClient、UA、超时/重试、代理（`restoreProxy`）、Cloudflare 优选 IP（`restorePreferredHostIps`）。
- 各源通过 `source_http.dart` 携带自身签名/Cookie。

### 2.2 `ImageCacheManager`（`image_cache.dart`）— 图片缓存统一入口
```dart
static Future<Uint8List> load(String url,
    {Map<String, String>? headers, required Future<Uint8List> Function() fetch});
static Future<void> probeDeviceMemory();   // 内存分档
```
- 两级缓存：内存（桌面 96MB/移动 40MB，保留 24 条）+ 磁盘。
- **缓存键即 URL/标识字符串**：裁边 `'$url|trim|${ImageTrim.algoVersion}'`、超分 `'${_srKey()}'`（裁边开时 `'${_srKey()}|trim|…'`）。

### 2.3 `LocalStore`（`local_store.dart`）— 设置/历史/书签
- **merge 式写**：`_updateSetting(key, value)`（设置按 key 合并，不整表覆盖）。
- 设置读取器：`fontSize()`/`readerMode()`/`trimBorder()`/`novelParagraphGap()`/`novelFirstIndent()`/`novelColorTemp()`/`windowGeometry()`/`proxy()` 等。
- 历史/书签：`HistoryEntry`（续读：pageIndex + scrollOffset 纵向精确位）、`ComicBookmark`、`VideoRecord`。
- 本地小说阅读设置：`setNovelReadSettings(fontSize:, lineHeight:, theme:, paragraphGap:, firstIndent:, colorTemp:)` 全部 merge 到 `novel_read_settings` map。

### 2.4 书架存储
- `BookshelfStore`（漫画）：`bindFile()` → `bookshelf.json`；`add/remove/contains/listBySource`。
- `NovelShelfStore`（小说）：`novel_shelf.json`；同上。

## 3. 工具（`lib/utils/`）

### 3.1 `ImageTrim`（`image_trim.dart`）— 漫画自动裁边
```dart
class ImageTrim {
  static const String algoVersion = 'gray-v1';   // 缓存键版本
  static const double maxTrim = 0.35;            // 每侧限裁 35%
  static TrimRect computeTrimRect(Uint8List bytes);
  static Uint8List cropToContent(Uint8List bytes, TrimRect trim);
  static Future<Uint8List> trimAndCrop(Uint8List bytes); // Isolate 单次解码扫描+裁剪
}
class TrimRect { top/bottom/left/right; isEmpty; toJson/fromJson; none; }
```
- 灰度 `(r*77+g*150+b*29)>>8`，白 > 250 且行白比 ≥ 0.95，连续 ≥ 3 白线起算；
  距边缘不足 16px 全白保护（防全白图误裁）；比例 < 0.015 或小图（边 < 400px）跳过。

### 3.2 `ImageSuperRes`（`image_super_res.dart`）— Anime4K 超分
- Isolate 处理；小图预检跳过（maxEdge ≤ 1400 不进 Isolate）。

## 4. 页面组件（`lib/ui/`）

### 4.1 播放器（`widgets/player_widgets.dart`）
- `kPlayerPanelWidth`：平板分栏右侧面板宽度（两播放页共用）。
- `PanelOptionTile`：面板选项行（title/subtitle/selected/onTap）。
- `showPlayerPanel(...)`：播放器底部弹层（title/fromRight/builder）。
- `PlayerColors`：深色面板配色 token（accent 强调色）。
- 倍速档位常量：`[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 3.5, 4.0]`。

### 4.2 图片组件
- `CachedImage`（`widgets/cached_image.dart`）：走 ImageCacheManager，支持 headers/超分/裁边参数。
- `JmScrambleImageWidget`（`widgets/jm_scramble_image.dart`）：禁漫解扰图（cacheHeight 限位防 OOM）。

### 4.3 状态/杂项
- `StateView`（`widgets/state_view.dart`）：错误/空态统一视图（icon/title/message/action）。
- `SectionHeader`：区块标题；`SettingsRow`：设置行（title/subtitle/trailing/onTap）。
- `TapTarget`：小点击目标放大（无障碍）；`Motion`（`widgets/motion.dart`）：动效封装。
- `DanmakuOverlay`（`widgets/danmaku_overlay.dart`）：弹幕浮层。

### 4.4 响应式与设计 token
- `responsive.dart`：`Responsive.isTablet(ctx)` / `DesktopUi` / `novelReaderMaxWidth(ctx)` / 断点。
- `tokens.dart`：`S`（间距）/ `R`（圆角）/ `T`（透明度）/ `TypeScale`（字号）/ `D`（动效）。见 DESIGN.md。

## 5. 播放器双页职责（重要契约）

| | `AnimePlayerPage` | `NativePlayerPage` |
|---|---|---|
| 容器 | WebView（webview_flutter / WebView2） | media_kit（mpv） |
| 职责 | 加载站点页、拦截/轮询捕获直链 | 直链播放、超分、弹幕、倍速、画质 |
| 切换 | 捕获直链 → `_killWebMedia()`（**物理移除 WebView**）→ `pushReplacement` | 换集拿到网页地址 → `pushReplacement` 回 AnimePlayerPage |
| 叠音防线 | 解析期 `_muteWebMedia`；切走 `_webViewRemoved` + WebView2 `stop()` | 新页出现前旧页已 dispose |

**换集链路**：原生播放器内 `_switchTo(ep)` → `resolveUrl(season, episode)` →
- 直链 → `_open(url)` 继续原生播放；
- 网页地址（非直链）→ `pushReplacement` 回 `AnimePlayerPage` 重新解析。

## 6. 扩展指南（新增功能的落点）

| 要做的事 | 改哪里 |
|---|---|
| 新增漫画源 | 实现 `ComicSource`，注册进 `SourceManager.sources` |
| 新增小说源 | 实现 `NovelSource`，注册进 `SourceManager.novelSources` |
| 新增动漫源 | 实现 `VideoSource`，注册进 `SourceManager.videoSources` |
| 新设置项 | `LocalStore` 加 getter + `_updateSetting` 写；设置页加行 |
| 新阅读器功能 | `reader_page.dart` / `novel_reader_page.dart`，纯算法下沉 `utils/` |
| 新播放器功能 | 原生功能进 `native_player_page.dart`；网页相关进 `anime_player_page.dart` |
| 新通用组件 | `ui/widgets/`，遵循 tokens 取值 |
| 新回归测试 | `test/regression_<功能>.dart`（gitignore，不提交） |