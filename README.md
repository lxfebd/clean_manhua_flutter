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

**漫画（6）**：包子漫画 ✅(免登录直链) ｜ 豆包 ✅ ｜ 樱漫YYFun ✅ ｜ 哔咔 ⚠️(登录) ｜ 禁漫JM ⚠️(反爬+图片解扰) ｜ MangaDex ✅(兜底)

**视频（3）**：AGE动漫 ✅ ｜ TvTFun ✅(需优选IP) ｜ 稀饭动漫 ✅(mp4直链)

**小说（1）**：笔趣阁 ✅(多镜像可换)

---

## 设计要点
- **源 = 引擎代码 + 声明式配置**：域名/镜像/请求头/登录开关外置到 `SourceConfig`（`lib/sources/source_config.dart`），用户在「源管理」页可改，免发版换域名。
- **网络自愈**：候选 IP 轮询 + DNS 回退 + 短超时 + 每 host 熔断。
- **多类型聚合**：`MainShell` 底部 4 Tab（首页/书架/工具/我的），首页内 漫画/动漫/小说 三态切换。

---

## 架构速览
- 源 = 引擎代码（实现 `ComicSource`/`VideoSource`/`NovelSource`）+ 声明式 `SourceConfig`
- 新增源：写实现类 → `source_manager.dart` 注册 → `source_config.dart` 加默认配置
