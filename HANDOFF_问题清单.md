# 星漫匣 问题清单与交接说明（供其他 AI 接手修复）

> 更新日期：2026-08-20（本次会话修复了 JM 详情页超时 + 图片加载失败）
> 仓库：lxfebd/clean_manhua_flutter，默认分支 `master`
> 技术栈：Flutter 3.29.3 + Dart；网络：`dart:io` + `cronet_http`（JM 域走 Cronet，但无 GMS 模拟器自动回退 dart:io）
> 测试环境：MuMu 模拟器 `127.0.0.1:7555`（adb 路径 `C:\Users\31672\AppData\Local\Android\Sdk\platform-tools\adb.exe`）

---

## 0. 当前代码状态速览

- 之前三个 P0 均已在模拟器上**验证通过**：
  1. 首页「解析失败: Filter error, bad data」（gzip 双重解压冲突）→ `autoUncompress=false` 已修，首页正常。
  2. 阅读器图片过小 / 工具栏跑到顶部 → `SizedBox.expand` 强制 Stack 铺满，图片全屏、工具栏在底部，已验证。
  3. JM 源 Cloudflare WAF 拦截 → 接入 `cronet_http`（Chromium 网络栈），JM 列表/封面/章节/图片均已跑通。
- **本次新增修复（2026-08-20）**：
  1. **JM 详情页 TimeoutException（15s 超时）**：根因是无 GMS 模拟器上 Cronet 探测失败后回退 dart:io 的过程把整个超时预算耗光。修复：`http_client.dart` 增加一次性 Cronet 可用性探测标志（`_cronetUsable`，失败即永久走 dart:io，不再反复白耗时间）；`detail_page.dart` 外层超时 15s→30s。模拟器实测：详情页正常加载 344 话章节。
  2. **JM 章节图片 404/加载失败**：根因是内置 CDN 域名池不全 + 文件名带 `.webp` 扩展名。修复：`jm_source.dart` 增加 `cdn-msp3.jmapiproxy2.cc`、`cdn-msp3.jmapinodeudzn.net` 兜底域名，且 `chapterPics` 优先从 API 响应动态读取 `imageHost`/`imageHosts` 字段（字段缺失时回退内置列表）。模拟器实测：阅读器 125 页正常渲染，滑动翻页图片持续加载。
- **JM 图片加扰还原已用真实图片双重验证通过**（2026-08-20）：
  - Dart `JmScramble.descramble` 输出与 JMComic Python 参考实现逐像素一致（最大差 ≤ 18，0% 像素超阈值）。
  - 「配对接缝检验」确认 `getNum` 算出的分块数正是服务器实际使用的（专辑 422866 图 00001→num=10、00002→num=14，缝能比 R≈7~9，远超错误候选）。
  - 验证脚本：`tool/jm_real_test.dart`（下载+解扰存 `tool/out/`）、`tool/verify_seam.py`（缝能配对检验）、`tool/verify_descramble.py`（Dart 输出 vs 参考实现比对）。
- 阅读器内点击手势拦截按钮的问题也已修复（`GestureDetector` 下移到 body 层）。
- 工具 Tab 下载列表「下载完成不刷新」已修复（`GlobalKey<ToolboxPageState>.refresh()` 切页触发）。

---

## 1. 本次验证通过的项

### 漫画源（列表 → 详情 → 章节 → 图片全链路）
- **豆包漫画**：首页/分类/搜索/详情（268 话）/章节/图片均正常；详情页 `<h1>` 缺失时已回退解析 `<title>`。
- **JM（禁漫）**：Cronet 接入后列表/封面/章节/图片正常（`Net.getCronet()`，失败自动回退 `dart:io`）。
- 包子漫画等其余源基本流程可跑（包子源对非 App 请求会返回推广图，属源侧限制）。

### 小说源（笔趣阁）
- 章节列表/正文解析已修：章节 ID 用 `novelId|cid` 拼接、跳过 `cid=0` 的无效占位章节；正文可正常渲染。

### 动漫（视频）源
- 多线路接入正常；「精品」线路存在「解析失败：线路响应较慢」的偶发问题（见第 3 节）。

### 功能项
- **搜索**：正常结果展示 + 无结果空态（`_EmptyState`，不再无限转圈）。
- **书架**：加入/展示正常，「全部收藏」3 部，「最近在读」显示进度百分比与相对时间。
- **历史**：阅读历史 12 条，记录章节进度，正常。
- **下载**：章节图片下载成功（54 页落地 `files/data/downloads/doubao/...`）、工具 Tab 切页即刷新、单条删除（含确认弹窗，记录+文件均删除）、清理已完成 / 清空全部均正常。
- **阅读器**：图片铺满全屏、底部工具栏（亮度/目录/翻页/下载）、点击空白切换工具栏显隐、横向/纵向翻页正常。

---

## 2. 尚存的小问题（非阻断）

1. **下载删除后残留空目录**：`files/data/downloads/doubao/` 下删除章节后父级空目录仍保留（文件已确实删除，仅目录清理不彻底，属观感问题）。
2. **历史记录存在无标题条目**：阅读历史里有一条「读到 01」无书名（来源为标题解析缺失的条目）。
3. **下载目录孤儿文件夹**：`doubao/0YWDD7wW6Q/0YWDD7wW6Q` 是早期失败下载遗留的空目录。

---

## 3. 待办/未定论

1. **动漫「精品」线路**：`奇招百出的维多利亚` 等视频解析偶发「解析失败：线路响应较慢」，需核查线路 URL 解析与响应处理。
2. **JM 存活域名**：Cronet 已通，域名池仍建议外置到 `SourceConfigStore` 便于热更新。（加扰还原本身已修好并验证，见第 0 节）
3. **哔咔漫画（picacg）**：签名算法已对，但测试凭据被服务端拒（HTTP 400），需可用账号。
4. **JS 自定义图源引擎**：基于 `flutter_qjs` 重做 + 注册 + 自定义源 UI。
5. **动漫弹幕**：已调研未实现。
6. **CF 优选 IP**：目前只给 `www.tvtfun.net` 配了，其他源按需补。

---

## 4. 复现 / 验证环境

```
adb connect 127.0.0.1:7555        # MuMu 模拟器
adb install -r app-debug.apk
adb shell am start -n com.xingmanxia.app/.MainActivity
adb shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml .
py _dump_text.py ui.xml            # 仓库根脚本，提取界面文案与可点击坐标
```

- 本地构建：`E:\smart\flutter\bin\flutter.bat build apk --debug`
- 注意：仓库根目录的 `_*.py`（`_dump_text.py`、`_find_bands.py` 等）为本次测试辅助脚本，不进版本库。
