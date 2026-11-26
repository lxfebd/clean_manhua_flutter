# AGENTS.md —— 接手这个项目前必读

> 给任何接下来要动这个项目的 AI / 开发者。
> 这里只写**容易踩错、且靠读代码不容易发现**的事。通用规范看 README。

星漫匣（XingManXia）—— Flutter 多源聚合漫画 / 动漫 / 小说阅读器。
仓库 `lxfebd/clean_manhua_flutter`（**public**），包名 `com.xingmanxia.app`。

---

## 一、动手前先跑这两条

```bash
dart analyze lib test tool          # 必须 0 issues
flutter test                        # 必须全绿（当前基线 1217 passed / 41 skipped）
```

`flutter test` 在 Git Bash 里跑会因 heredoc 把脚本写到 `/tmp`（Windows 下映射到别的盘）而失败，
**改用 PowerShell 执行 `C:\flutter\bin\flutter.bat test`**。

真网契约测试默认跳过，需要时加 `--dart-define=LIVE_SOURCE_TESTS=true`（慢，别在每次提交都跑）。

---

## 二、发布相关（最容易出错，必读 `docs/RELEASE_KEYS.md`）

⚠️ **有两套完全独立的密钥，别搞混：**

- `KEYSTORE_*`（4 个 secret）→ APK **系统签名** → 决定能不能**覆盖安装**
- `UPDATE_SIGNING_KEY` → **更新清单签名** → 决定能不能**自动安装**

**覆盖安装只看第一套。** 第二套缺了只是不能自动更新，**不会**导致装不上。
历史上曾把这个搞混，误判成"密钥不对导致装不上"，白折腾一轮。

其他发布约定：

- **版本号唯一事实源是 `pubspec.yaml`**。CI 会校验 tag 名与之相等，不等直接失败。
  改版本只改 pubspec（`1.5.8+86` 的形式，`+` 后是 build number）。
- 发布 = commit → `git push origin main` → `git tag -a vX.Y.Z` → `git push origin vX.Y.Z`。
- **私钥绝不入库**：正常在 `~/.xingmanxia/*_signing_key.json`。`.gitignore` 已兜底拦截，
  但别去写死任何密钥内容到代码/文档/issue 里——仓库是公开的。
- 发布链是 **fail-closed**：缺 secret 就红，不要为了"让 CI 绿"把它改成警告放行。

---

## 三、源（内容抓取）的三个必守规则

### 1. 源配置三层必须同步

改源站域名时，**三处都要改**，漏一处就会出现"改了但没生效"：

1. 解析器里的 `_defaultHosts`
2. `lib/sources/source_config.dart` 的 `defaults()`
3. 老用户的 `sources_config.json`（靠 `_deadHosts` 黑名单兜底）

**`SourceHttp.pickHost()` 只读 `source_config.dart`**，只改解析器里的域名等于没改。

### 2. UA 是分域名的，不能一刀切

| 目标 | UA 策略 | 原因 |
|---|---|---|
| 国内源（动漫屋 DM5、风车、禁漫等） | 伪装浏览器（`NetConn.defaultUA`） | 不伪装直接 403 / 掉内容 |
| **MangaDex 全线**（api / uploads / *.mangadex.network） | **必须如实标识应用**，见 `lib/sources/mangadex_ua.dart` | 伪装浏览器会被 POWBlock 返回 **200 + HTML 挑战页** |
| 其它 CDN 图片 | 浏览器 UA | 通用 |

MangaDex 那个坑特别隐蔽：**接口**拿到 HTML 会抛 `FormatException`（看着像 API 契约变更，
实际去改解析器完全无效）；**图片**拿到 HTML 会被解码端当成"损坏图"，表现为封面全灰、
章节图全裂，日志里完全看不出是反爬。改 UA 相关代码前先读 `mangadex_ua.dart` 的注释。

### 3. 判断"源坏了"之前先怀疑请求特征

真实案例：MangaDex 被判定"API 契约变更、FormatException"，实际只是 UA 伪装触发反爬。
**判死前先做同机对照**：换 UA、换协议头、带/不带参数各试一遍，看是不是"请求特征被拦"
而不是"站点改版"。三路交叉验证（App 同款 Dart 栈 / 各源 verify 测试 / 市场源 live 测试）。

---

## 四、几条容易踩的工程约定

- **设计 token 有棘轮门禁**：`test/design_tokens_test.dart` 把硬编码圆角种类钉死在 ≤1、
  fontSize 种类 ≤12。新增硬编码圆角/字号会**直接让 CI 红**。用 `StyleTokens.*Or()` /
  `Theme.of(context).textTheme`。
- **阅读器 keepAlive 恒关**（P0-05）。曾经"横向关、纵向开"，理由（纵向受 cacheExtent
  限制不会累积）是错的，长章内存会单向增长。别改回去。
- **Wakelock 用引用计数**（`WakelockGuard`），不要直接调 `WakelockPlus.enable()`，
  否则离开阅读器后屏幕还亮着。
- **`consumed` / 代际 token**：阅读器切章、图片加载都有代际防旧响应覆盖，
  改异步逻辑时别把代际判断删了。
- 桌面构建在本机沙箱不可行（MSBuild 被拦），Windows 包只能靠 CI 出。
  本机模型不能读图，**不要声称看过截图**。

---

## 五、能力边界（如实记录，别做伪修复）

| 源 | 限制 | 状态 |
|---|---|---|
| 禁漫 JM | 全部域名被 Cloudflare「Just a moment」JS 挑战拦截 | 保留 fallback，需 WebView 过挑战才有解 |
| 笔趣阁 | 新章节服务端加密下发 | 识别后给明确提示，无解密能力 |
| TvTFun 播放 | 站点有播放人机验证（`/cap/`） | 走 WebView，用户验证一次后注入脚本截 m3u8 |

**不要**为了"看起来能跑"做伪修复（比如明知必然 403 还留着请求）。做不到就如实标注。

---

## 六、AI 视频超分 / 插帧 —— 已搁置，不是项目重点

- App 内的 AI 视频超分/插帧**早已剥离**（备份在 `_revert_safety/ai_video_strip_20260916/`）。
- 播放器里的 **Anime4K** 仍在（mpv VO 着色器），验证判据只看 `vo-passes`。
- `lib/utils/image_super_res.dart` 是 **Lanczos-3 重采样，不是 AI**（漫画图放大用）。
- 工作区根的 `xmq-video-ai/` **与本项目完全解耦**，是独立离线工具，已搁置。
  实测 ≥720p 全平台无法实时（桌面 6.1× 慢于实时，移动端 ≤16fps）。

别把这块当项目进展讲，也别主动推进。

---

## 七、当前进度锚点

- 版本 v1.5.8，HEAD 见 `git log`。完整待办见 `.workbuddy/memory/MEMORY.md`
  （该目录在工作区根，不在本仓库内）。
- 2026-11-20 做过一次全维度审查，70 项清单在
  `../星漫匣_全维度审查与优化清单_2026-11-20.md`（工作区根目录，不入库）。
  代码里修过的条目都带 `Pn-nn` 标记，可直接 grep 定位。
