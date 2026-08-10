# 星漫匣 / 樱漫盒 clean（yingmanhe_clean）

多源聚合的 **漫画 + 动漫（视频）+ 小说** 阅读/追番 App，Flutter（Dart）实现。
是对原「樱漫盒」APK（v1.08，Kotlin + 大量广告 SDK + TTEncrypt 加壳）的**去广告干净重写版**。

> 完整的交接信息（代码地图、架构、源清单、技术暗坑、验证记录、待办、交接清单）见 **[项目交接手册.md](项目交接手册.md)**。本文档为速览。

---

## 技术栈
- Dart（Flutter 3.x），**54 个 Dart 文件 / 约 16,500 行**
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

## 已接入源（含健康度）

**漫画（6）**：包子漫画 ✅(免登录直链) ｜ 豆包 ✅ ｜ 樱漫YYFun ✅ ｜ 哔咔 ⚠️(登录失败) ｜ 禁漫JM ⚠️(反爬+图片解扰) ｜ MangaDex ✅(兜底)

**视频（3）**：AGE动漫 ✅ ｜ TvTFun ✅(需优选IP) ｜ 稀饭动漫 ✅(mp4直链)

**小说（1）**：笔趣阁 ⚠️(默认域名可能404，源管理页可换镜像)

---

## 关键技术暗坑（详情见交接手册 §5）
- **禁漫(JM) 图片加扰**：纵向分块倒序混淆，非简单加密 → `lib/net/jm_scramble.dart`
- **哔咔(Pica) 签名**：真实协议是 HMAC-SHA256（非裸 MD5），key 带 `<>` → `lib/sources/picacg_source.dart`
- **Cloudflare 优选 IP**：当前只配 `www.tvtfun.net`，在 `lib/net/http_client.dart` 的 `preferredHostIps` 增配，勿改源代码 URL
- **源配置外置**：域名/镜像/登录开关外置到 `SourceConfig`（`lib/sources/source_config.dart`），用户可在「源管理」页改，免发版

---

## 架构速览
- `MainShell` 底部 4 Tab（首页/书架/工具/我的）；首页内 漫画/动漫/小说 三态切换
- 源 = 引擎代码（实现 `ComicSource`/`VideoSource`/`NovelSource`）+ 声明式 `SourceConfig`
- 新增源：写实现类 → `source_manager.dart` 注册 → `source_config.dart` 加默认配置

---

## 配套文档
- [项目交接手册.md](项目交接手册.md) —— 交接必读
- `REDESIGN_PLAN.md` / `SOURCE_RESEARCH.md` —— 历史设计调研
- `../analysis/REPORT.md` —— 原 APK 逆向解剖报告
