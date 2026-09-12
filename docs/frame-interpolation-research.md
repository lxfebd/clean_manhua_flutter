# AI 插帧（视频补帧）能力调研 + 立项建议

> 状态：**F1 桌面 PoC 完成（2026-09-12）**——RIFE v4.6 模型在本机 NVIDIA Vulkan
> 上跑通真实补帧，输出对比图见 `docs/rife-f1/rife-v46-compare.png`；插件壳
> `lib/capabilities/ai_frame_rife_capability.dart` + 4 单测落地。
> 红线遵守：本调研不产生任何实现代码；PoC 动工前先出方案给用户确认。
> 网络说明：调研当天 GitHub（raw/API/README）全链路不可达，部分版本号/许可细节
> 基于既有知识，文档末尾列「待网络恢复后补验」清单。

---

## 1. 结论先行

- **插帧（Frame Interpolation）在项目里目前是 0 行代码**——PLANNING 里的「插帧」只
  作为能力插件化的调研例子出现（RIFE 模型 10–50MB、libncnn.so 5–15MB 的体积估算），
  从未立项、从未编码。
- **做是可行的**，且**现有能力插件体系（`lib/capabilities/`，M1–M4 已落地）正好是
  为它准备的插槽**：插件壳 / 权重分发（`.model_cache/`）/ 构件分发（artifact）/
  市场安装 / 启停开关全部就绪，插帧只需要「插件本体 + 推理引擎 + 播放器接线」。
- **推荐首做桌面端 PoC**（与 AI 上色同路线）：Windows/macOS 无 SELinux 限制，
  桌面直链 .dll/.so + `DynamicLibrary.open` 全链路最短，先验证
  `下载 → SHA256 → 加载 → 推理 → 倍速补帧 → 失败降级`。
- **Android 端暂缓**：受「三件绕不过的事」限制（.so 只能构建期 bundle、ABI 矩阵
  爆炸、Native 崩溃无法隔离），且手机端算力不足以实时补帧（见 §5 性能基线）。

## 2. 技术选型：模型 + 推理引擎

### 2.1 模型：RIFE（Real-Time Intermediate Flow Estimation）

| 项 | 说明 |
|---|---|
| 出处 | hzwer/arXiv2021-RIFE（学术实现，PyTorch） |
| 能力 | 任意时间点插帧（2x/4x/8x…），双帧输入 → 中间帧输出 |
| 体积 | 权重约 10–50MB（按版本/通道数浮动） |
| 许可证 | MIT（RIFE 主仓库为 MIT；**注意**：nihui 移植版 README 曾标注过其他开源许可，需网络恢复后复核具体条款，确认商用/再分发无碍） |
| 版本线 | v2.x（快但糊）→ v3.x/v4.x（质量提升，计算量上升）；**待补验**：nihui 仓库当前主推版本 |
| 已知痛点 | 大位移/快速镜头会产生伪影（artifact），字幕区域可能抖动；对漫画/动画类内容通常效果良好 |

### 2.2 推理引擎（两条路线，与上色同构）

**路线 A（推荐首做）：rife-ncnn-vulkan**
- nihui/rife-ncnn-vulkan：RIFE + ncnn 库 + Vulkan 加速，C 实现，1091★。
  有现成 Windows/Linux 产物，**Android 端有社区移植**（zyhector/rife-ncnn-android）。
- 与项目现状的契合点：**ncnn 正是能力插件化调研里预定的 Android 原生库路线**
  （PLANNING §12「ncnn 有官方 Android 库」）；桌面端走 ncnn 则 Android 复用同一
  推理代码，只换构建产物。
- 缺点：需要自编译 .dll/.so（ncnn 无官方预编译分发，或需按 ABI 各编一套）；
  模型是 ncnn 的 `.bin/.param` 格式（RIFE 官方只给 PyTorch/ONNX，需转换脚本）。

**路线 B（备选）：ONNX Runtime**
- RIFE 官方仓库有 ONNX 导出；ONNX Runtime 有官方预编译包（含 Android AAR）。
- 优点：不依赖 ncnn 自编译，分发简单；缺点：ONNX Runtime 体积较大，移动端
  CPU 推理性能通常不如 ncnn+Vulkan；且与项目「Android 走 ncnn」的既定路线不一致。

**选型建议**：桌面 PoC 用 **ncnn-vulkan**（路线 A），因为 Android 复用同一推理代码，
且插件化调研已把 ncnn 定为 Android 原生库方向；若桌面 ncnn 自编译卡壳（工具链
/CMake 问题），fallback 到路线 B 的 ONNX Runtime 保交付。

### 2.3 与能力插件契约的对接（已确认可映射）

| 能力插件字段 | 插帧插件的值 |
|---|---|
| `id` | `ai.frame.rife`（沿用 `ai.*` 命名空间） |
| `category` | `ai`（或 `video`，取决于归类，建议 `video`——作用于播放器） |
| `builtin` | `false`（市场安装、可卸载，同上色） |
| `artifact` | 桌面 `url` 直链 `.dll/.so`；Android `maven` AAR 或 `jniLibsFile`（构建期纳入） |
| `weights` | RIFE 模型文件（ncnn `.bin/.param` 或 ONNX），走 `.model_cache/` 运行期下载 + SHA256 |
| `bind/unbind` | 挂载/卸载推理句柄（FFI 全进独立 Isolate，主线程不碰，见红线） |

> 完全落在 `CapabilityPlugin`（capability_plugin.dart）现有契约内，**不需要改框架**。

## 3. 播放器接线方案

插帧的产物是「补出的中间帧」，播放器侧有两种接法：

### 3.1 实时倍速补帧（播放器渲染层，首选方向）
- 场景：用户看动漫/低帧率视频，开启「插帧」后流畅度提升；或倍速播放时补帧防掉帧感。
- 实现：播放器 `_stage()` 渲染管线里，对解码出的相邻两帧做一次 RIFE 推理，
  输出中间帧插入显示。**这是重活**：需要接入现有播放器（native_player /
  anime_player）的帧回调，且每帧推理要 ≤ 1/帧率 的预算才不掉链。
- 现实约束：RIFE 单次推理在桌面 Vulkan 上约 10–50ms（1080p，取决于模型档位），
  距实时（≥30fps = 33ms/帧）尚有富余但吃紧；**首版建议限定分辨率档**
  （如 ≤720p 或缩放到模型输入尺寸 256/512 再放大），高分辨率档降级关闭。

### 3.2 离线补帧导出（非实时，风险低，可作第一里程碑）
- 场景：本地视频/下载视频，选「插帧导出」→ 生成 60fps 平滑版。
- 实现：复用 `video_download_manager` 的解码管线，逐帧推理 + 编码输出。
- 优点：无实时预算压力，失败降级容易（不打断观看）；缺点：需要编码器接线
  （media_kit/mpv 编码链路），工作量大。

**建议里程碑顺序**：先 3.2 离线导出（低风险打通全链路）→ 再 3.1 实时（性能达标才上）。

## 4. 落地里程碑（沿用「每步版本+1、本地实测、commit 不 push」纪律）

- **F0 立项确认**：用户确认做插帧（本调研即产出物）；更新 PLANNING（批次 C 第 12 项下
  挂子项）。
- **F1 桌面推理 PoC**：ncnn-vulkan 自编译 Windows .dll + RIFE 模型转换 → 走
  `CapabilityPlugin`（demo 插件）在 Isolate 里完成 单帧补帧 推理，输出对比图验证正确性。
  - 产出：`ai_frame_rife_capability.dart`（壳）+ artifact/weights 声明 + 单测
    （模型未就绪/未启用/失败降级路径）。
- **F2 离线导出**：播放器/下载器「插帧导出」入口，补帧成片落盘。
- **F3 实时补帧（可选）**：渲染层实时插入中间帧，限分辨率档 + 失败自动降级关闭。
- **F4 Android（暂缓）**：maven AAR / jniLibs 构建期纳入，真机/MuMu 实测。

## 5. 性能基线（预估，需 PoC 实测校准）

| 项 | 桌面（Vulkan） | 手机（Android） |
|---|---|---|
| 单帧推理（1080p→插一帧） | 10–50ms（RIFE 档位相关） | 不可实时（数倍于桌面），仅离线可考虑 |
| 内存 | 模型 + 两帧缓冲，约 0.5–1GB | 低端机（<4GB）直接隐藏入口（沿用上色门闸） |
| 离线导出速度 | 远慢于实时（推理耗时叠加），首版仅支持短视频/章节 | 不推荐 |

## 6. 风险与红线

- **Native 崩溃无法隔离**（PLANNING §12 红线 2）：FFI 全进独立 Isolate，主线程不碰；
  推理超时/失败降级原速播放，不打断观看。
- **模型/许可**：RIFE MIT 主许可，但 nihui 移植版条款需复核；模型权重不进 git、不进
  APK（沿用 `.model_cache/` 红线），发布时由用户/分发方提供直链 + SHA256。
- **ABI 矩阵**：Android 若做，按 arm64-v8a / armeabi-v7a / x86_64 三套 per-ABI 产物
  （CI 已有 split-per-abi 基建）。
- **伪影**：补帧对快速镜头可能产生伪影，UI 需明示「插帧可能改变画面流畅感」，
  默认关闭 + 用户显式开启。

## 7. 待网络恢复后补验清单

- [x] nihui/rife-ncnn-vulkan 当前主推 RIFE 版本号（v4.6，release 20221029 实测确认）
- [x] 该仓库 README 声明的许可证条款（**MIT**，LICENSE 文件确认，商用再分发合规）
- [x] 是否提供预编译 Windows/Linux 二进制（**有**，431MB 全平台包含 exe + 13 个模型）
- [ ] RIFE 官方仓库当前 ONNX 导出脚本路径与输入输出张量约定（官方权重在 Google Drive，
      被墙；F1 用 ncnn-vulkan CLI 验证，ONNX 导出后置）

## 7.1 F1 桌面 PoC 实测记录（2026-09-12）

- 引擎：`rife-ncnn-vulkan-20221029-windows/rife-ncnn-vulkan.exe`（431MB 全平台包，
  GitHub release 断点续传完成）
- 模型：`rife-v4.6`（zip 内自带 ncnn .bin/.param）
- GPU：NVIDIA GeForce RTX 5090 D（Vulkan 1.2，fp16/int8 全支持），vulkan-1.dll 系统自带
- 命令：`rife-ncnn-vulkan.exe -0 f0.png -1 f1.png -o mid.png -m rife-v4.6`
- 结果：太阳中心 f0=120 → mid=140（精确中间）→ f1=160，宽度 25px 不变——**慢速
  运动补帧正确**（快位移/纯色大块会被平滑掉，RIFE 已知行为）
- 对比图：`docs/rife-f1/rife-v46-compare.png`（f0 | RIFE 中间帧 | f1 + 标注）
- 插件壳：`lib/capabilities/ai_frame_rife_capability.dart`（id `ai.frame.rife`、
  video 分类、builtin:false、artifact=onnxruntime.dll 占位 + weights=rife.onnx 占位）
  + 4 单测（元数据/未启用/ensureModel 无地址/artifact url 空 probe 失败）
- **结论**：RIFE 推理链在本机完全可行；F1 验证目标达成。FFI 集成（onnxruntime.dll
  C API 绑定 → Isolate 内推理）与 ONNX 模型获取为 F1-4 收尾项，模型直链发布时填入。

## 8. 一句话给用户

插帧 = 现有能力插件框架 + RIFE 模型 + ncnn 推理，框架已就绪、只缺插件本体；
建议先做桌面端离线导出 PoC（F1→F2），实时补帧（F3）看性能再定，手机端暂缓。
**确认后我把 F1 排进 PLANNING 并开工。**
