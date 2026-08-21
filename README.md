# 星漫匣（XingManXia）

多源聚合的 **漫画 + 动漫（视频）+ 小说** 阅读/追番 App，Flutter（Dart）原创实现。

内置多套内容源引擎（漫画 / 动漫 / 小说），支持源管理与镜像切换；零三方网络依赖，自带 Cloudflare 优选 IP、源熔断、响应缓存等抗抖动能力。

---

## 技术栈
- Dart（Flutter 3.x）
- 网络：零三方依赖，自写 `Net`（`lib/net/http_client.dart`）
- 加密：`crypto` + `pointycastle`；图片：`image`；播放：`media_kit`；WebView：`webview_flutter`

---

## 快速开始
```bash
flutter pub get
flutter build apk --debug          # 产物：build/app/outputs/flutter-apk/app-debug.apk
# 或 flutter run 直连设备/模拟器
```
> 需要在装有 Flutter SDK 的机器上构建。

---

## 已接入源

**漫画（4）**：动漫屋(DM5) ✅(国内免登录默认源) ｜ 豆包 ✅ ｜ 禁漫JM ⚠️(反爬+图片解扰) ｜ MangaDex ✅(英文兜底)

**视频（3）**：AGE动漫 ✅ ｜ TvTFun ✅(需优选IP) ｜ 稀饭动漫 ✅(mp4直链)

**小说（1）**：笔趣阁 ✅(多镜像可换)

---

## 更新日志

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
