# 能力市场「一键安装即用」契约

> 2026-09-12。目标：能力市场从「能看到空转圈」变成「拉得到索引、装得上、
> 卸得掉、跨重启还在、装了就能用」。本文档记录本地已接通的部分 + 远端
> 发布清单（需用户实权），两端都齐市场才真正可用。

## 1. 现状盘点（改前）

市场全链路 4 段，改前只有第 2 段的一半：

| 环节 | 状态（改前） | 缺口 |
|---|---|---|
| ① 远端索引可达 | ❌ `lxfebd/xingmanxia-sources` **仓库不存在**（GitHub API 404、raw 404）；源市场《源市场页》共用同一 URL，一起空转 | 需建公开仓库 + 发布 index.json |
| ② 市场页展示/安装 | ✅ 页面/解析/安装/卸载在跑 | 安装是内存态：杀进程就丢；重启后「已安装」永远显示未安装 |
| ③ 下载模型/引擎 | ⚠️ 能力中心只有上色的「下载模型」按钮；插帧引擎无入口 | 权重/引擎直链是 `TODO(publish)` 空串；引擎下载入口缺失 |
| ④ 装了就能用 | ❌ 上色/插帧的调用入口（`colorize`/`interpolate`）没有任何页面调用 | 特征接入待排期（M5+，见 §5） |

## 2. 本次已落地（本地代码层，commit 前）

1. **已安装能力清单持久化**（`capability_plugins.json` v2 新增 `installed` 快照）：
   - `CapabilityPluginManager.install`（市场能力）→ 写 `installed` + 落盘。
   - `restore()` 用快照重建市场能力实例 → 重启后市场「已安装」、能力中心列表都正确。
   - 兼容 v1 旧文件（只有 `disabled`，无 `installed`）：不迁移也正常。
2. **预置壳卸载不重建**（`removed` 集合持久化）：
   - AI 上色/插帧壳随版本预注册（不落盘、不进 installed），用户从市场看是「可安装」。
   - 用户卸载后记 `removed`，重启不再冒出来；重新从市场安装即解除。
   - 修复旧行为：`restore` 无脑 `install(AiColorizePlugin())`，卸载了重启又出现。
3. **卸载 purge 本地构件**：`uninstall` 清 `.model_cache/<id>/` + `capabilities/<id>/`，
   不再「卸载了还占 225MB」。
4. **更新替换**：市场条目同 id 不同版本 → 先 uninstall（含 purge）再装新版本，
   registry 不再卡死旧版本。
5. **CapabilityPlugin 序列化**（`toJson`/`fromJson`）供快照落盘/重建，坏条目跳过。
6. **能力中心卡片**：AI 插帧加「下载引擎」按钮（`ensureEngine`：下载 zip →
   SHA256 → 解压），上色「下载模型」按钮沿用（`ensureModel`）。
7. **市场 tile 安装后刷新**：tile 监听 Manager `revision`，装完立即切到「已安装/
   可更新/卸载」，不用手动刷新。

验证：能力相关 43 测试全绿（新增 9 个：更新替换/purge/installed 快照/roundtrip/
卸载不重建依据），全量 297 过 + 15 skip；`flutter analyze` 仅 theme.dart 既有 2 warning。

## 3. 远端发布清单（需用户实权，见 §6）

一次做完这 3 步，市场「一键安装即用」成立：

1. **建公开仓库** `lxfebd/xingmanxia-sources`（或改现有），推 `index.json`。
   - `capability_market.dart:72` 与 `source_market.dart:53` 的两处 `_indexUrl` 指向它。
   - 源市场条目（`sources:[...]` 完整 CustomSourceDef JSON）与能力条目
     （`capabilities:[...]`）可共存于同一文件。
2. **发布两条能力**的
   - 模型/引擎直链（权重体积大，建议 GitHub Release / 对象存储，勿入仓库）；
   - `weights[].sha256` / `artifact.sha256` 填入代码常量：
     - `ai_colorize_capability.dart:30` `modelSha256`、`:47` `model url`（DDColor ~225MB）
     - `ai_frame_rife_capability.dart:36` 引擎 SHA256（已有 `F2DF…0CF98`，F1 打包产物）、
       `:63` `url`（rife-engine-win.zip 12.2MB）
3. **发布后自检路径**（见 §4）：市场页拉取 → 安装 → 能力中心「下载模型/引擎」→
   就绪 →（上色/插帧特征接入后）调用。

## 4. 一键安装即用的标准自检路径

1. 能力中心 → 能力市场 → 列表出现 2~N 条能力（索引可达）。
2. 点「安装」→ tile 变「已安装」+ SnackBar 成功。
3. 回能力中心 → 卡片带「下载模型」(上色) /「下载引擎」(插帧) 按钮。
4. 点下载 → 权重/引擎下载 + SHA256 校验 →「模型/引擎已就绪」。
5. 杀掉 App 重启 → 能力中心仍有该能力、开关状态保留；市场再进 → 仍显示「已安装」。
6. 卸载 → 本地构件（模型/引擎 zip）被清理，再次进入市场该能力回到「安装」。

## 5. 已知边界与后续（不阻塞本单）

- **特征接入**（装了真能用）：上色入口（阅读器页加按钮）、插帧入口（播放器页加
  模式）未接，是独立 UI 工作，排到能力市场链路之后（M5）。
- **Web 端**：下载/构建/解压全部走 `dart:io`/子进程，`kIsWeb` 门闸恒降级，市场页
  在 Web 打出「能力不可用」提示——不做浏览器端（design §12）。
- **下载进度**：目前是「转圈 → 完成」无百分比（`Net.getBytes` 整包拿），200MB 级别
  权重建议后续接流式进度；不做阻塞本单。
- **iOS/macOS 的引擎**：rife-ncnn-vulkan 引擎包只有 Windows 版，macOS 显示「未配置
  直链」；上色权重跨平台普遍适用。

## 6. 需要用户定夺的远端操作（红线：先同意再执行）

- 新建公开仓库 `lxfebd/xingmanxia-sources` 并推 `index.json`（内嵌能力条目 +
  可选源条目示例）。
- 发布/上传两个权重或引擎包到 GitHub Release（或对象存储）并拿到永久直链 +
  SHA256。
- 把直链/SHA256 填回代码常量并走本地发布流程（本地 commit → 实测 → 用户同意推）。

内部文档/密钥/开发域名一律不入公开仓库（详见 repo-push-governance 红线）。