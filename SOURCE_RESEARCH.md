# 漫画/动漫源调研报告（2026-08）

## 调研目的
为"星漫匣"漫画 App 扩充更多可用的漫画源与动漫源。

## 1. 现已接入源（4 个）

| # | 名称 | 类型 | 协议 | 状态 |
|---|------|------|------|------|
| 1 | 豆包漫画 | 漫画 | HTML | ✅ 已跑通 |
| 2 | 禁漫天堂 (JM) | 漫画 (R18) | HTML | ✅ 已跑通 |
| 3 | 哔咔漫画 (Picacg) | 漫画 (R18) | JSON API | ✅ 已跑通（含优选 IP） |
| 4 | 樱漫(YYFun) | 漫画 (R18) | HTML | ✅ 已跑通 |

## 2. 参考项目

### 2.1 [Venera](https://github.com/venera-app/venera)（强烈推荐）
- Flutter 跨平台漫画阅读器，已停止维护但代码可参考
- **支持 JS 自定义图源**（基于 flutter_qjs，QuickJS fork）
- 配置文件仓库：[venera-configs](https://github.com/venera-app/venera-configs)
- 源索引：[cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json](https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json)
- 文档：[comic_source.md](https://github.com/venera-app/venera/blob/master/doc/comic_source.md)
- **最大价值**：自带 33 个漫画源 + 完整的 JS API 规范 — 我们完全可以照搬格式

### 2.2 [Miru](https://github.com/miru-project/miru-app)
- Flutter + QuickJS，支持**视频 / 漫画 / 小说**多类型
- 仓库源系统
- 跨平台：Android/Windows/Web
- 优势：有现成的动漫/视频源仓库可借鉴

### 2.3 [picacg-qt](https://github.com/tonquer/picacg-qt)
- 仅哔咔单源桌面客户端（Python + Qt）
- 我们已在 Flutter 端实现了等价功能

## 3. 候选漫画源列表（来自 Venera index.json）

| # | 名称 | 文件 | key | 可达性 | 优先级 |
|---|------|------|-----|--------|--------|
| 1 | 拷贝漫画 | copy_manga.js | copy_manga | 待测 | ⭐⭐⭐ |
| 2 | 拷贝漫画(多账号) | copy_manga_multi_accounts.js | copy_manga | 待测 | - |
| 3 | Komiic | komiic.js | Komiic | 待测 | ⭐⭐ |
| 4 | 包子漫画 | baozi.js | baozi | 待测 | ⭐⭐ |
| 5 | Picacg | picacg.js | picacg | ✅ 已有 | - |
| 6 | nhentai | nhentai.js | nhentai | 待测 | ⭐ |
| 7 | 紳士漫畫 | wnacg.js | wnacg | 待测 | ⭐⭐ |
| 8 | ehentai | ehentai.js | ehentai | 待测 | ⭐ |
| 9 | 禁漫天堂 | jm.js | jm | ✅ 已有 | - |
| 10 | MangaDex | manga_dex.js | manga_dex | 待测 | ⭐⭐ |
| 11 | 爱看漫 | ikmmh.js | ikmmh | 待测 | ⭐⭐ |
| 12 | 少年ジャンプ＋ | shonen_jump_plus.js | shonen_jump_plus | 待测 | ⭐ |
| 13 | hitomi.la | hitomi.js | hitomi | 待测 | ⭐ |
| 14 | comick | comick.js | comick | 待测 | ⭐⭐ |
| 15 | 优酷漫画 | ykmh.js | ykmh | 待测 | ⭐ |
| 16 | 再漫画 | zaimanhua.js | zaimanhua | 待测 | ⭐⭐ |
| 17 | 漫画柜 | manhuagui.js | ManHuaGui | 待测 | ⭐⭐ |
| 18 | 漫蛙吧 | manwaba.js | manwaba | 待测 | ⭐ |
| 19 | 漫画1234 | mh1234.js | mh1234 | 待测 | ⭐ |
| 20 | CCC追漫台 | ccc.js | ccc | 待测 | ⭐ |
| 21 | GoDa漫画 | goda.js | goda | 待测 | ⭐ |
| 22 | 18漫画 | mh18.js | mh18 | 待测 | ⭐ |
| 23 | 漫小肆 | mxs.js | mxs | 待测 | ⭐ |
| 24 | 漫画人 | manhuaren.js | manhuaren | 待测 | ⭐⭐ |
| 25 | H-Comic | hcomic.js | hcomic | 待测 | ⭐ |
| 26 | jcomic.net | jcomic.js | jcomic | 待测 | ⭐ |
| 27 | 热辣漫画 | hot_manga.js | hot_manga | 待测 | ⭐ |
| 28 | 嗨皮漫画 | happy.js | happy | 大陆/日韩IP不可访问 | ❌ |
| 29 | MYCOMIC | mycomic.js | mycomic | 待测 | ⭐ |

排除：Lanraragi / Komga / Kavita / カドコミ — 自建服务类，非公共图源

## 4. 候选动漫源（视频/番剧）

动漫与漫画是两个**完全不同**的协议：漫画是图集，动漫是 m3u8/HLS 流。
我们项目目前 ComicSource 接口是按漫画设计的（chapterPics: List<String> 图片URL），
**接入动漫源需要新增 VideoSource 接口**或者扩展现有接口。

| # | 名称 | 域名 | 可达性 | 协议 | 备注 |
|---|------|------|--------|------|------|
| 1 | AGE 动漫 | https://www.agedm.io/ | ✅ 200 | HTML + 视频m3u8 | 主力番剧源 |
| 2 | Bilibili 番剧 | https://www.bilibili.com/ | ✅ 200 | JSON API | 官方 API，需要登录 |
| 3 | 樱花动漫 | iyinghua.com | ❌ 0 | - | 大陆封禁 |
| 4 | 动漫之家 | m.dmzj.com | ❌ 0 | - | 大陆封禁 |

## 5. 动漫源主要难点

1. **视频流协议**：m3u8 / mp4 / flv，需要 video_player 或 fijkplayer 插件
2. **CDN 防盗链**：很多动漫站 m3u8 带 Referer/UA 校验
3. **分集接口**：动漫是"剧集 (episode)"概念，与漫画"章节 (chapter)"有差异
4. **弹幕**：番剧通常有弹幕需求
5. **搜索/排行**：动漫站排行榜结构与漫画差异大

## 6. 实施建议（建议用户确认优先级）

### 路径 A：先扩充漫画源（成本低、与现有代码兼容好）
按 Venera 的 JS 源格式，**优先实现前 10 个**漫画源（拷贝/Picacg/包子/紳士/爱看漫/comick/再漫画/漫画柜/漫画人/MangaDex）。

技术方案：
- 选项 1：直接下载并嵌入 Venera 的 JS 源 + 集成 flutter_qjs
- 选项 2：用 Dart 重写每个源（工作量更大但可控）
- **推荐：选项 1**，复用 Venera 33 个现成 JS 源

### 路径 B：新增动漫（视频）支持（成本高、需要大改）
- 新增 VideoSource 接口
- 引入 video_player / fijkplayer / better_player 插件
- 优先接入 AGE 动漫（已验证可达）
- 番剧搜索 → 集数列表 → m3u8 解析 → 播放器

## 7. 立即可做的（无需用户决策）

- 把当前源选择器从 4 个扩到至少 10 个（添加上述漫画源中的 5-6 个轻量级）
- 添加"添加自定义源"功能（粘贴 Venera JS 源 URL）

## 8. 不可访问源说明

以下源在中国大陆/本机环境**确认不可达**（curl 测得 000）：
- iyinghua.com
- dmzj.com / m.dmzj.com
- api.bgm.tv

源 `happy` (嗨皮漫画) 描述明确写"中国大陆及日韩IP无法访问" — 排除。
