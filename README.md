# 星漫匣（XingManXia）

多源聚合的 **漫画 + 动漫（视频）+ 小说** 阅读/追番 App，Flutter（Dart）原创实现。

内置多套内容源引擎（漫画 / 动漫 / 小说），支持源管理与镜像切换；零三方网络依赖，自带 Cloudflare 优选 IP、源熔断、响应缓存等抗抖动能力。

**响应式自适应**：手机上下堆叠、平板左右分栏（首页侧边导航 / 详情页左封面+右章节 / 播放器左视频+右控制面板），一套代码两套布局。

---

## 技术栈
- Dart（Flutter 3.x）
- 网络：零三方依赖，自写 `Net`（`lib/net/http_client.dart`）
- 加密：`crypto` + `pointycastle`；图片：`image`；播放：`media_kit`；WebView：`webview_flutter`

---

## 快速开始
```bash
flutter pub get
flutter build apk --release     # 产物：app-release.apk（仅 arm64-v8a，约 33MB）
flutter build apk --debug       # 全 ABI（含 x86_64，模拟器可跑）
# 或 flutter run 直连设备/模拟器
```
> 发布包仅打包 `arm64-v8a`（现代手机/平板通用），体积从 112MB 降到 33MB；debug 包保留全 ABI 以便 x86 模拟器测试。
> 需要在装有 Flutter SDK 与 Android NDK 的机器上构建。

---

## 已接入源

**漫画（4）**：动漫屋(DM5) ✅(国内免登录默认源) ｜ 豆包 ✅ ｜ 禁漫JM ⚠️(反爬+图片解扰) ｜ MangaDex ✅(英文兜底)

**视频（4）**：AGE动漫 ✅ ｜ TvTFun ✅(需优选IP) ｜ 稀饭动漫 ✅(mp4直链) ｜ Anime1 ✅(WebView播放)

**小说（2）**：笔趣阁 ✅(多镜像可换) ｜ 新笔趣阁 ✅(Base64 章节解密)

---

## 更新日志

### v1.4.0（2026-09-04）
- 📱 **手机/平板字号分档（TypeScale）**：手机（<600dp）保留设计稿原字号（display 19 / title 17 / micro 9），平板/桌面走桌面档（display 22 / title 17 / micro 11）；修复"改平板连带着手机字号一块放大"问题；新增 `test/design_tokens_test.dart` 设计 token 门禁（WCAG AA 对比度 + 字面量棘轮 + 两档字号守卫）
- 🖥️ **桌面端窗口管理（Windows/macOS/Linux）**：window_manager 限定最小尺寸、记忆并恢复上次窗口位置/尺寸、窗口标题"星漫匣"
- 🎨 **主题切换动效**：`AnimatedTheme` 220ms easeOutCubic 平滑过渡；`MaterialApp.builder` 统一系统栏样式（状态栏/导航栏透明、随明暗切换图标亮度）、`TextScaler.noScaling` 固定缩放、`MouseNavListener` 桌面鼠标导航
- 🔋 **WakelockPlus 生命周期常亮**：前台 resumed/inactive 保持屏幕常亮，切后台/销毁恢复系统默认熄屏
- 🐛 **修复首页精选横幅红屏**：`_FeaturedBanner` 把 initState 里读 MediaQuery/Responsive 移入 `didChangeDependencies`（真机首页会红屏刷屏的崩溃）
- 🖼️ **封面图 dpr 钳 2.0**：高分屏（dpr≥3）不再请求 3 倍宽缓存图，封面内存与磁盘缓存压力大降
- 🪟 **Windows WebView2（desktop_webview）**：动漫播放页 Windows 走 WebView2（webview_windows），替代灰屏占位；`webview_flutter` 仅用于移动端
- ⬇️ **视频下载管理器（video_download_manager）**：动漫/视频下载独立管理器
- 🧰 **布局/UI 审计工具**：tools/ 新增 ascii_view、pixel_layout_audit、ui_audit、vision_probe、layout_metrics_test
- 🧪 **新增测试**：desktop_player_fallback、main_shell_large、main_shell_short_landscape、responsive、source_http_retry
- 📦 **CI 升级**：Flutter 3.29.3 → 3.44.0、NDK 26.3 → 28.2（对齐新 API）；新增 Windows 电脑端构建 job（产物 app-windows artifact）

### v1.3.8（2026-08-27）
- 📱 **平板全面适配（响应式分栏范式）**：
  - 首页：左侧常驻侧边栏（4 项垂直均分、整块可点、选中高亮）+ 右内容区
  - 番剧预备选集页：顶部封面图+渐变遮罩、线路卡片视觉区分、剧集选中高亮+历史标记、分页控件、立即播放联动选集
  - 视频播放页：平板左视频(16:9 纯黑底)+右竖控制面板（与手机端同尺寸/同顺序）、可收起全屏
  - 漫画详情页：平板左封面+右信息/按钮/章节列表，统一按钮尺寸
  - 漫画阅读页：`AutomaticKeepAliveClientMixin` 修复上翻抖动/闪烁（重大 bug）
- 🐛 **修复横屏 letterbox（居中留白）**：播放页退出不再全局锁竖屏；App 启动/从后台恢复时平板强制允许横屏（双保险）
- 📦 **APK 体积优化**：仅打包 arm64-v8a，**112MB → 33MB**（降 70%）；debug 保留全 ABI 供模拟器测试
- 🧹 **文件规范**：清理 47 个开发期调试快照（HTML/JSON/XML/JS）；更新 APK 改存到规范下载目录；补充 .gitignore 规则
- ✨ **无封面占位美化**：`_LetterCover` 从单字升级为品牌色渐变+完整标题+更新备注（Anime1/AGE catalog 无封面卡片更友好）
- ⚡ **预备页性能**：`shrinkWrap GridView` → 懒加载 `SliverGrid`（消除卡顿）；AGE catalog 解析加固 + 不满屏自动续页

### v1.3.3–v1.3.7（2026-08-26 ~ 27）
- AGE 动漫分页加载修复（catalog 目录页解析，第 2 页起正常翻页）
- 侧边栏改造（4 项垂直均分、图标在上文字在下、选中高亮）
- 番剧预备页重做（封面区、线路视觉区分、选集高亮、立即播放联动）
- 阅读器上翻抖动根因定位与修复
- 横屏 letterbox 根因定位与修复（方向锁残留）

### v1.3.2（2026-08-25）
- 🚀 **新增 Anime1 视频源**（anime1.me）：接入全量目录分类（全部/連載中/年季度）、分页、搜索、详情剧集解析；纯文本站无封面，列表卡片自动生成首字占位封面；CDN 直链需签名 Cookie，播放走 WebView 由站点播放器处理
- 🚀 **TvTFun 视频源增强**：接入官方 API 分页（pageIndex/pageSize）+ 地区/标签分类（日本/国创/韩国/剧场版/恋爱/搞笑等）+ 年份筛选（2026–2022）+ 元数据（评分/更新集数/tag/配音语言）
- 🎬 **Anime4K 视频超分**：5 档位（关闭/智能降噪/轻量超分/均衡超分/极致超分）CNN 着色器，原生播放器全屏/竖屏均可切换；mpv 画质增强（去色带 + 高质量缩放核）
- 🧪 **视频源端到端验证测试**：`test/verify_tvtfun_test.dart`、`test/verify_anime1_test.dart` 真实请求远端源，覆盖分类/分页/搜索/详情/播放全链路；tvtfun 实时请求加限流降温与有限重试
- 🐛 **修复更新安装"软件包无效"**：统一 debug/release 签名（debug 构建也用 `xingmanxia.jks`），保证测试环境可用 GitHub release APK 覆盖安装
- 🐛 **修复版本号读取**：`UpdateChecker` 改用 `package_info_plus` 读取真实版本（原硬编码 1.0.0 导致更新检查永远误判有新版本）
- ⚡ **更新下载加速**：镜像优化为实测可达的 `ghproxy.net`（14 KB/s → 700+ KB/s），下载慢时更快切换镜像
- 🧪 端到端验证：v1.2.0 → 检测 v1.3.2 → 下载(651KB/s) → 系统安装器 → **安装成功**，版本升级到 1.3.2

### v1.3.1（2026-08-25）
- 🚀 **网络工具新增「优选 IP」**：对指定域名（默认 TvTFun）并发扫描 Cloudflare 节点（TCP 443 + TLS 握手），按延迟排序展示结果；一键应用前 N 个到 `Net.preferredHostIps` 直连加速，结果持久化、重启自动恢复，可一键清除回退系统 DNS
- 🚀 **网络工具新增「源检测」**：一键并发检测所有启用源主机（漫画/动漫/小说）的 HTTPS 连通性与延迟，直观判断当前网络哪些源可用，配合「源管理」换镜像
- 🔧 优选 IP 扫描采样加随机抖动：多次扫描会探索不同 CF 节点，提高找到低延迟 IP 的概率

### v1.3.0（2026-08-24）
- 🚀 **JM 源性能优化**：图片解扰移入 Isolate（`compute()`），内存缓存 LRU + 40MB 上限，`Image.memory` 全部加 `cacheWidth`，Flutter ImageCache 收紧到 30MB
- 🚀 **全面性能审计修复**（低端机流畅运行）：
  - `CachedImage` / `Image.file` / `Image.network` 全部加 `cacheWidth`（封面内存降 60-80%）
  - `LocalStore` / `BookshelfStore` / `NovelShelfStore` 同步文件 IO 改异步 + 防抖写盘
  - `JmCrypto` AES-256-ECB / `AesCbc` AES-128-CBC 解密卸载到 `compute()` Isolate
  - `LocalStore` 大 JSON(>64KB) 解析走 Isolate
  - `BookshelfStore.sourceIdOf` 从 O(n) 线性扫描改为 O(1) 索引
  - 所有热点路径 RegExp 提取为 `static final`（`jm_scramble` / `dm5` / `biquge`）
  - 阅读器章节列表/页码网格移除 `shrinkWrap`（懒加载）
  - 网格卡片加 `RepaintBoundary`（滚动不重绘）
  - 播放器 `position`/`buffer` 流 setState 节流到 5Hz
  - `detail_page._sortedChapters` 加缓存避免 build 内重复调用
- 🔥 **超分辨率真实化**：
  - 图片超分：`CachedImage.superRes` 从假遮罩改为**真实 Lanczos-3 2x 上采样**（Isolate 执行，磁盘缓存）
  - 阅读器"高清(2x)"档接入真实 Lanczos-3 超分
  - 视频 Anime4K：确认是真实 bloc97 CNN 着色器（libmpv `glsl-shaders`）
  - WebView"超分"诚实改名"Web 调色"（CSS 滤镜，非真超分）
  - 删除孤儿资产 `assets/shaders/anime4k/`
- 🛡️ **阅读器防误触**：
  - `PopScope` 二次返回确认（再按一次退出）
  - 翻页动画进行中禁止手势（`_pageAnimating` 锁）
  - 防掌按：时间+距离双重判定
  - 双击锁定/解锁触摸（躺卧阅读）
- ✨ **屏幕常亮**：阅读时 `WakelockPlus` 保持屏幕不熄灭
- ✨ **亮度条真实化**：阅读器亮度条从假遮罩改为 `screen_brightness` 真实控制系统亮度，退出还原
- ✨ **RTL 反向翻页**：日漫从右往左阅读习惯，设置页开关
- ✨ **多主题色彩**：5 种种子色（墨蓝/东京夜/翡翠绿/暖橙/薰衣草），设置页圆点选择器即时切换
- ✨ **详情页批量下载**：多选章节弹窗 → 逐章下载带实时进度 → 可取消
- ✨ **下载队列管理**：`DownloadManager` 加全局取消 + 重试，工具箱下载列表加重试按钮
- 🐛 修复 `scrollDown`/`scrollUp` 手势定义但未实现的 Bug
- 🐛 修复 NDK 版本不兼容（27→26.3.11579264）

### v1.2.1（2026-08-23）
- ✨ 阅读统计：今日/本周/累计阅读时长 + 7 天柱状图周报弹窗（「我的」页）
- ✨ 阅读器手势自定义：左/中/右三等分区域可自定义点击操作（上一页/下一页/菜单/亮度/滚动）
- ✨ 书架更新角标：头部「N 更新」红色角标 + 卡片右上角红点，点书架自动检查所有收藏新章节
- ✨ 章节缓存状态：详情页「查看全部章节」弹窗显示每章已缓存 ✓ + 「已缓存 N 话」计数
- ✨ 跨源统一搜索：搜索框输入后点🌐地球图标，并发搜索所有启用源，按源分组展示结果
- ✨ 备份/恢复：设置页新增导出/导入 JSON（含书架+小说书架+历史+设置+源配置）
- ✨ 小说阅读器自定义：字号/行距/背景纸色（跟随/米白/浅绿/深青）设置抽屉
- ✨ 阅读器图片双指缩放（0.5x~4x）
- 🐛 修复详情页「查看全部」点击直接跳进第一章（改为弹出完整章节目录）
- 🐛 修复详情页「正序」不可点击（新增正/倒序切换）
- ✨ 阅读器沉浸式连读：读完最后一页出现「下一话」尾页自动加载
- ✨ 书架进度精确到页（记录 pageIndex + chapterTotalPages）
- ✨ 后台更新下载：全局单例管理，关闭弹窗/返回页面不中断，通知栏实时进度+速度
- ✨ 更新下载多镜像加速：直连→gh-proxy→mirror.ghproxy→ghproxy.net→github.moeyy 自动回退
- ✨ 更新下载断点续传：Range 头 + 固定路径复用 + 不支持 Range 时清空重下
- ✨ 阅读器跳页精确化（按实际图片加载高度累积偏移，替代 560 魔数）

### v1.2.0（2026-08-22）
- 🐛 修复动漫屋(dm5)章节图片解码（packer 字符串解析代替正则）
- 🐛 修复动漫屋章节图片加载失败（CDN 需 Referer 头 + preflight 复用修复）
- 🐛 修复阅读器画质/翻页按钮选中态不实时更新（本地状态管理）
- 🐛 修复阅读器亮度滑块不生效（`_dim` 类型从 bool 改为 double）
- 🐛 修复豆包封面错位（正则锚定 `pic>` 避免跨卡片匹配）
- 🐛 修复 AGE 动漫封面错位（整卡片块正则 + `&amp;` HTML 实体解码）
- 🐛 修复 AGE 动漫搜索返回为空（新增搜索页正则）
- 🐛 修复禁漫天堂 API 400 错误（Cronet → dart:io）
- ➕ 新增动漫屋源（dm5），删除不可用的包子漫画/樱漫
- 🔧 全源端到端实机验证通过

### v1.1.0（2026-08-21）
- 🐛 修复漫画超分辨率（画质增强）硬编码为 0 的问题
- 🐛 修复多源下封面 Hero 错位（tag 加 sourceId）
- 🐛 修复 MangaDex 已下架章节判空

---

## 设计要点
- **源 = 引擎代码 + 声明式配置**：域名/镜像/请求头/登录开关外置到 `SourceConfig`（`lib/sources/source_config.dart`），用户在「源管理」页可改，免发版换域名。
- **网络自愈**：候选 IP 轮询 + DNS 回退 + 短超时 + 每 host 熔断。
- **多类型聚合**：`MainShell` 底部 4 Tab（首页/书架/工具/我的），首页内 漫画/动漫/小说 三态切换。

---

## 架构速览
- 源 = 引擎代码（实现 `ComicSource`/`VideoSource`/`NovelSource`）+ 声明式 `SourceConfig`
- 新增源：写实现类 → `source_manager.dart` 注册 → `source_config.dart` 加默认配置
