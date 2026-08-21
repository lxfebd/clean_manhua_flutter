# 工作交接文档 — 星漫匣

## 项目概况

**星漫匣（xingmanxia）** — Flutter 漫画聚合阅读 App。
- 源码路径：`e:\xiangm\back\clean_manhua_flutter`
- 包名：`com.xingmanxia.app`
- 框架：多源聚合架构，每个漫画站实现一个 `ComicSource`，由 `SourceManager` 统一管理

---

## 已完成的工作

### 1. 漫画超分辨率（画质增强）修复
- 根因：reader_page.dart 的 `_resLevel` 被硬编码为 0，设置面板"画质增强"选项被删
- 修复：local_store.dart 新增 `resLevel()`/`setResLevel()` 持久化；阅读器设置新增三档：原图 / 平滑 / 高清

### 2. 封面错位修复
- 根因：首页 `Hero(tag: 'cover_${item.id}')` 缺 sourceId，多源下不同漫画 id 冲突
- 修复：全部改为 `cover_${sourceId}_${comicId}`，sourceId 传入各卡片组件

### 3. MangaDex 报错修复
- 根因：已下架章节返回 `{hash:"",data:[]}` 未判空
- 修复：逐层判空返回 `[]`，阅读器显示友好提示

### 4. 换源：删除不可用源，新增动漫屋
- 删除：包子漫画（baozimh）— 打开显示"下载APP"落地页；樱漫(YYFun) — 写真 APP 内容需登录
- 新增：动漫屋（dm5.com）— 国内可直连、免登录
- 源列表：动漫屋（默认）→ 豆包漫画 → 禁漫天堂 → MangaDex

### 5. 动漫屋 packer 解码 + 章节 ID 修复 ✅（2026-08-21 完成）
- 根因 1：`_extractPacker` 用正则匹配 eval 参数失败——p 参数含大量 `\'` 转义，正则的 `'(.*?)'` 提前截断
- 根因 2：`_chapterRe` 提取章节 id 时用 `split('/').last`，对 `/m123/` 得到空串；且有 `m` 前缀导致请求 `mm123` 404
- 修复：
  - `_extractPacker` 改为精确字符串解析（定位 `eval(function(p,a,c,k,e,d)` → 找 `}(` → `_parseCallArgs` 引号配对、逗号分隔提取 p/a/c/k），对齐 Python 方案
  - 章节 id：`split('/')[1].replaceFirst('m', '')`
- 验证：排行榜→详情（173 章）→章节图片（22 页直链）端到端通过；章节页 `m615293` 单独验证 9 张图片直链
- 注意：海贼王/一拳超人等人气漫画详情页**无章节列表**（版权移除，页面含"已不再提供在线阅读"注释），但冷门漫画正常

### 6. 阅读器设置抽屉 UI 修复（2026-08-21）

**问题 1：画质/翻页按钮选中状态不实时更新**
- 根因：`_ReaderSettingsSheet` 用 `widget.resLevel` / `widget.horizontal` 判断选中态，但 modal 期间父组件更新后子组件不会重建
- 修复：`_ReaderSettingsSheetState` 新增 `_localResLevel` / `_localHorizontal` 本地状态，点击时立即 `setState`

**问题 2：亮度滑块不实时生效**
- 根因：`_dim` 在父组件是 `bool` 类型，但滑块回调传 `double`，赋值后 `bool` 永远为 `true`，`AnimatedOpacity` 无法细粒度调节
- 修复：`_dim` 改为 `double` 类型（0.0~1.0），`AnimatedOpacity` 透明度改为 `_dim * 0.45`

### 7. 豆包封面错位修复
- 根因：`_itemRe` 正则从 `<a href="/detail/..." title="...">` 开始匹配，但每个漫画卡片有两个 `<a>`（封面区 + 名称区），名称区的 `<a>` 没有 `data-original`，正则跨到下一张卡片的封面
- 修复：正则前加 `pic">` 锚定封面区域，确保 `data-original` 取自同一卡片

### 8. 动漫屋章节图片「加载失败」修复 ✅（2026-08-21 实机验证）
- 根因 1：dm5 图片 CDN（cdndm5.com）**无 Referer 头返回 404**（Python/curl 实测：无 Referer → 404，带 Referer → 200 421KB）
- 根因 2（关键）：`_prefetch()` 用**无 Referer** 的 `ImageCacheManager.preload()` 启动 in-flight 请求 → 随后 `_CachedReaderImage` 带 Referer 的 `load()` 因 URL 相同**复用失败 future** → 全部 404
- 修复：
  - 新增共享方法 `_ReaderPageState._headersForUrl(url)`：dm5 图片带 `Referer: https://m.dm5.com/m{cid}/`（从 URL 的 cid 参数还原章节页），豆包带 doubaomanhua.com
  - `_prefetch()` 与 `_CachedReaderImage._load()` 统一走 `_headersForUrl`，避免 in-flight 复用无头请求
- 验证：`Net.getBytes` 带 Referer 下载 421KB 成功（无 Referer 失败乱码）；released APK 已重装模拟器，UI 树不再出现「图片加载失败」

### 9. AGE 动漫封面错位 + 搜索为空修复 ✅（2026-08-22）
- 根因 1（封面错位）：`_cardRe` 只匹配标题 `<a>`（145 条——含导航/推荐区），而封面 `_coverRe` 只匹配 20 条；旧的「找最近 card 位置」关联逻辑导致封面与标题错位
- 根因 2（搜索为空）：搜索页卡片结构与首页不同（首页 `div.video_item` + 标题块；搜索页 `card cata_video_item` + `<a title=...><img data-original=...></a>`），原正则匹配 0 条
- 根因 3（封面加载失败）：百度图床代理 URL 含 **`&amp;` HTML 实体**，`Uri.queryParameters['src']` 无法识别 `src=` 参数 → 返回含 `&amp;` 的无效 URL → 图片无法加载
- 修复：
  - `_cardRe` 改为**整卡片块匹配**（`div.video_item` → data-original → detail/ID → 标题），封面/ID/标题一一对应，零错位
  - 新增 `_searchCardRe`（`<a ... detail/ID title="标题">...<img data-original>`）兼容搜索页结构
  - `_resolveCover()` 先 `_unescape`（`&amp;`→`&`）再 `Uri` 解析，取出真实 `src` 直链
- 验证：首页 20 条一一对应；搜索「高达」24 条；详情 28 集；封面 URL 解析为 `aqdstatic.com:966` 直链（无 Referer 68KB 下载 OK）；实机截图 1.4MB 封面正常显示
- 注意：AGE 图源 `https://cdn.aqdstatic.com:966/age/covers/{id}.jpg` 直链可访问，无需 Referer

### 10. 禁漫天堂（JM）API 请求修复 ✅（2026-08-22）
- 根因：`_getJson` 使用 `Net.getCronet()`（Chromium Cronet 网络栈），在模拟器上 Cronet 发送的请求头/指纹被 JM 服务器拒绝，返回 HTTP 400 "Our API changed year ago"
- 修复：改为 `Net.get()`（dart:io HttpClient），API 和 CDN 均正常响应
- 验证：
  - rank 80 条 ✅
  - detail 345 章 ✅
  - chapterPics 125 图 ✅
  - 5 个图片 CDN 全部可下载（24KB 封面 ✅）

---

## 待解决事项

### B. 豆包源 HTTP 500（部分情况）
- 豆包源**列表/详情/章节图片均可用**（已验证），但部分漫画详情页无章节（如"配角回归指南"显示"马上更新"）
- Cloudflare 质询页在部分请求下出现，需增加请求头伪装或换域名

---

## 全源端到端测试记录（2026-08-21）

| 源 | 排行榜/列表 | 搜索 | 详情 | 章节 | 说明 |
|----|--------|------|------|---------|------|
| 动漫屋 (dm5) | ✅ 120条 | ✅ | ✅ 173章 | ✅ 22页 | 默认源，完整可用 |
| 豆包漫画 (doubao) | ✅ 60条 | ✅ | ✅ 5章 | ✅ 3页 | 需选有章节的漫画；部分漫画无章节 |
| 禁漫天堂 (jm) | ✅ 80条 | ✅ | ✅ 344章 | ✅ 125页 | App API 正常 |
| MangaDex | ✅ 20条 | ✅ | ✅ 98章 | ✅ 47页 | 英文向，兜底源 |
| AGE 动漫 (agedm) | ✅ 20部 | ✅ 24条 | ✅ 28集 | — | 2026-08-22 修复封面错位+搜索 |

测试方式：`flutter test` 直接调用各源 `rank/detail/chapterPics`（测试文件已清理）

---

## 开发环境

- Flutter：`E:\smart\flutter\bin\flutter.bat`
- 构建命令：`$env:FLUTTER_SYMLINK_PLUGINS='false'; flutter build apk --release`
- 模拟器：MuMu `E:\MuMuPlayer\nx_main\MuMuManager.exe`，竖屏 vmindex 3（DCO-AL00，900x1600）
- 常用 adb 命令：
  - 安装 APK：`MuMuManager.exe adb -v 3 install <apk路径>`
  - 启动：`MuMuManager.exe adb -v 3 shell am start -n com.xingmanxia.app/.MainActivity`
  - 截取 UI 树：`MuMuManager.exe adb -v 3 shell uiautomator dump /sdcard/ui.xml && MuMuManager.exe adb -v 3 pull /sdcard/ui.xml <本地路径>`