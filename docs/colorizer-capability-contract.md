# 能力插件 ↔ colorizer 对接契约（M4）

> 状态：**M4 契约 v1（2026-09-11 撰写，只读调研产出）**
> 范围：定义「能力插件化体系 `lib/capabilities/`」与「上色团队 `lib/utils/colorizer*`」之间的对接边界。
> 红线：**不修改任何 `colorizer*.dart` 文件**；本契约文档仅定义边界与待实现项，改动清单须由上色团队/用户评审后统一落地。
> 依据：本契约全部来自对两个体系真实代码的只读调研（非臆测）。colorizer 侧关键契约以 `colorizer_backend.dart` + `ColorizerManager._inferDdcolor` 实际实现为准，`colorizer_io.dart` 类头注释已过期（见 §4 文档漂移）。

---

## 0. 一句话结论

把「AI 上色」做成能力市场条目时，**能力边界应定在 `ColorizerManager.colorize(Uint8List rgb, int w, int h) -> Uint8List?`，而不是 `ColorizerBackend.inferAsync` 之下**。插件层只做三件事：probe（模型就绪+平台门闸）→ 取权重文件路径 → 把调用包进 `CapabilityRuntime.run` 且**不引入第二把锁**。其余（互斥、超时、降级语义、平台门闸）全部复用 colorizer 现有实现。

---

## 1. 两侧现状全貌

### 1.1 能力插件侧（`lib/capabilities/`，M1–M3 已落地）

- `CapabilityPlugin`：**具体类**（非 abstract），10 个构造字段（id/name/category/version/author/description/builtin/rank/artifact/weights）+ 6 个默认空实现的虚方法（onInstall/onUninstall/onEnable/onDisable/bind/unbind）。`category` 三选一：`ai` / `video` / `utility`。
- `CapabilityArtifact`：桌面 `url`（直链下载）+ Android `jniLibsFile`/`maven`（构建期 bundle）+ `sha256`（per-ABI 键）。**编址约定**：桌面键形如 `windows-x64`，Android 键为规范 ABI 名 `arm64-v8a`/`armeabi-v7a`/`x86_64`。**坑：`CapabilityArtifactStore.download` 取 `sha256.values.first` 作为桌面期望值，桌面哈希必须放 Map 首位**。
- `CapabilityWeight`：name/url/sizeBytes/sha256，统一落 `<support>/.model_cache/<id>/`（红线保持为空，仅运行期下载）。
- `CapabilityRuntime`：**全项目唯一允许 `DynamicLibrary.open` / Isolate 隔离调用的地方**。`run(id, task)` 用 `Isolate.run` 执行闭包；`runNative(id, path, task: (DynamicLibrary) -> …)`。**无超时、无互斥锁**。新 isolate 不共享 FFI 句柄，闭包内必须重新 `open`。
- probe 三步：ABI 校验（仅 Android 查 `sha256.containsKey(abi)`）→ artifact 就绪（url 下载校验 / jniLibs 直接 Ok / embedded Ok）→ 算力标记（M2 暂不探测）。**probe 不检查启用开关**，业务侧用 `acquire`（会先查开关）。
- 内置注册：`CapabilityPluginManager.restore()` 内私有 `_registerBuiltin()` 注册 `utility.stats` + `DemoNativePlugin`（不走 `install`，**不触发 bind**）。`builtin_capabilities.dart` 的 `registerBuiltinCapabilities()` 已是 install 范式但生产未接线。
- 能力中心 UI：**category ∈ {ai,video,utility} 即自动渲染**（卡片/开关/卸载/图标），卸载仅对 `builtin:false` 显示。

### 1.2 上色侧（`lib/utils/colorizer*`，独立 agent 负责，M4 不碰）

- `ColorizerManager`（手写单例）：核心入口 `colorize(Uint8List rgb, int w, int h) -> Future<Uint8List?>`——**失败/超时/未加载/等锁超时一律返回 `null`，永不抛异常**（语义=降级原图）。
- 输入/输出契约（权威，`colorizer_backend.dart` 头注释 + `_inferDdcolor` 实测确认）：
  - 输入：`Uint8List` 交错 RGB，`length == w*h*3`，**无 alpha**（调用方负责用 `img` 库 `ChannelOrder.rgb` 剥 alpha），w/h 任意（manager 内部缩到 256×256）。
  - 输出：`Uint8List?` 同尺寸 RGB 交错，`w*h*3` 字节，无 alpha；`null` = 降级信号。
- DDColor 模型契约：输入 `1×256×256×3 float32` NHWC，通道 0 = **L/100**（L∈[0,1]），通道 1/2 = 0；输出 `1×2×256×256` float32 CHW，ab **已是 Lab 原尺度（≈−128..127），不再缩放**。
- 并发模型：**自管单锁** `_mutex`（Completer），等锁超时 2 分 30 秒 **>** 推理超时 2 分钟；`_timedInfer` 最多 3 次尝试，仅对 `IsolateInterpreter skip`（并发污染，耗时 <100ms 的 skip 假象）重试，其余失败直接降级并置 `_colorized=true`（同页永不再试）。
- 目录约定：**`getApplicationSupportDirectory()/colorizer/model.tflite`** —— 与 `.model_cache/` 不同（私有 const `_modelDir`/`_modelFile`，无法重定向）。
- 平台门闸三层：编译期 web → stub（`isAvailable=false`、load/inferAsync 抛 `StateError`）→ 运行期 `isAvailable`（模型存在+`loadAsync` 就绪）→ UI 期 `DesktopUi.isDesktopPlatform`（`!kIsWeb && {windows,macos,linux}`，**不含 Android 真机**）+ `isLowEndDevice()`（RAM<4GB 隐藏）。
- 唯一依赖注入点：`@visibleForTesting set backendForTest(ColorizerBackend)`——测试专用，正式化需提升。
- 调用方（`reader_page.dart`）：`_tryColorize` 在超分之后调用；输入用 `ImageCacheManager.loadDegraded(...).bytes` 解码后剥 alpha；输出 `img.encodeJpg(q:90)` 回写。触发条件是四条件 getter：`DesktopUi && widget.colorize && !_isJm && enabled && isAvailable`。

---

## 2. 对接方案（能力边界）

### 2.1 插件骨架（落点：新的 `lib/capabilities/ai_colorize_capability.dart`，M4 不写、仅模板）

```dart
class AiColorizePlugin extends CapabilityPlugin {
  static const String modelName   = 'ddcolor.tflite';
  static const String modelSha256 = '…';      // 由权重提供方填
  static const int modelSizeBytes = 225 * 1024 * 1024; // 约 225MB（reader_page 注释量级）

  AiColorizePlugin() : super(
    id: 'ai.colorize.ddcolor',     // CapabilityPlugin 文档预留的示例 id
    name: 'AI 上色',
    category: 'ai',
    version: '1.0.0',
    author: '星漫匣上色团队',
    description: '本地 DDColor 黑白漫画上色（权重运行期下载，仅供参考学习）',
    builtin: false,                // 市场能力：可卸载、走 install/persist
    weights: const [
      CapabilityWeight(name: modelName, url: '…最终权重直链…',
          sizeBytes: modelSizeBytes, sha256: modelSha256),
    ],
  );

  /// 上色调用：**主 isolate 直调 ColorizerManager**，不包 CapabilityRuntime.run。
  static Future<CapabilityResult> colorize(Uint8List rgb, int w, int h) async {
    // 幂等 probe：本能力无 artifact（纯 Dart 壳），probe 只校验「已注册」。
    final p = await CapabilityRuntime.instance.probe('ai.colorize.ddcolor');
    if (p is CapabilityFailure) return p;
    // 启用开关：probe 不查开关，这里显式收口（与 UI 开关一致）。
    if (!CapabilityPluginManager.instance.isEnabledSync('ai.colorize.ddcolor')) {
      return const CapabilityFailure('ai.colorize.ddcolor', '能力未启用，请在能力中心打开');
    }
    final m = ColorizerManager.instance;
    if (!m.isAvailable) {
      return const CapabilityFailure('ai.colorize.ddcolor', '上色模型未就绪（需导入 .tflite 模型）');
    }
    final out = await m.colorize(rgb, w, h); // 失败返回 null = 降级原图，原样透传
    return CapabilityOk('ai.colorize.ddcolor', data: <String, dynamic>{'result': out});
  }
}
```

### 2.2 关键约束（务必遵守）

- **不要用 `CapabilityRuntime.run` 包 colorize**。`run` 的闭包走 `Isolate.run`，在新 isolate 里 `ColorizerManager.instance` 是全新单例（模型未加载，`isAvailable=false`），colorize 恒降级 null。`CapabilityRuntime.run/runNative` 只用于 **FFI 原生构件**（demo_math 那种）；上色是纯 Dart 壳，主 isolate 直调即可，ColorizerManager 内部的 TFLite 推理本来就跑在自己的 isolate 里。
- 正因为直调，**不会引入第二把锁**：并发由 `ColorizerManager._mutex`（等锁 2 分 30 秒 > 推理 2 分钟）单一串行化。
- 契约语义：colorizer 失败返回 `null` = 降级原图。插件层**原样透传 null**（`CapabilityOk.data.result == null`），阅读器侧看到 null 依旧显示原图，**不得打断阅读流**、不得抛异常。
- 返回值：只返回 `CapabilityResult`（`CapabilityOk.data` / `CapabilityFailure.reason`），reason 是给用户看的中文文案，**禁止静默降级**。
- **probe 不检查启用开关**（无 artifact 时纯注册校验），本模板在调用前显式 `isEnabledSync` 收口——或业务侧直接用 `CapabilityRuntime.acquire`（先查开关再 probe）。

---

## 3. 接口缺口（上色团队待实现项，需评审后排期）

当前 colorizer 侧**缺失**、能力条目化必需的接口：

| 缺口 | 现状 | 影响 | 建议 |
|---|---|---|---|
| 批量上色 | 仅 `colorize(单张)` | 章节级批量/预下载场景无法用 | 新增 `colorizeBatch(List<(Uint8List,int,int)>)`，内部串行走同一把锁 |
| 取消 | 无 cancel，进入 `_timedInfer` 只能等 2 分钟超时 | 用户退出页面后台仍耗 CPU | 加 `cancelToken`（在等锁与推理间隙检查） |
| 进度回调 | 只落 `ErrorLogger` 日志，UI 零感知 | 阅读器无法显示「上色中…%」 | 加 Stream 或回调参数，UI `RepaintBoundary` 内局部刷新 |
| algoVersion 常量 | 无（对比 `ImageSuperRes.algoVersion`） | 依赖模型/算法升级时图片缓存 key 不失效 | 提 `algoVersion`，随权重 sha256 变而变 |
| 模型路径可配置 | `_modelDir`/`_modelFile` 私有 const | 无法接 `.model_cache/` | 提为构造参数或 `setModelDir()`，默认仍 `colorizer/` 保持兼容 |
| backend 注入正式化 | 只有 `@visibleForTesting backendForTest` | 自定义后端/测试替换困难 | 提升为公开 `registerBackend(ColorizerBackend)` |
| 后端能力描述 | `ColorizerBackend` 抽象只有 5 成员，无元数据 | 插件无法声明尺寸上限/耗时预估 | 扩展可选元数据（模型名/输入尺寸/预估 ms），默认值兼容 |

> 这些缺口**不改现有行为**：默认路径、锁语义、降级语义、平台门闸全保留。只增不改。

---

## 4. 文档漂移告警（上色团队需要修注释，不改逻辑）

`colorizer_io.dart:18-21` 类头注释写的是旧契约（「输入 1×3×256×256 Lab 空间（L/50−1，ab=0）；输出约 ±2，×110 还原 Lab」），与 `colorizer_backend.dart` 头注释及 `_inferDdcolor` 实际实现（L/100 即 L∈[0,1]、ab 已是 −128..127 不再 ×110）矛盾。**以 `colorizer_backend.dart` + 实际代码为准**，`colorizer_io.dart` 类头注释为过期，需更新。

---

## 5. 目录约定冲突与统一

| 约定 | colorizer 现状 | 能力体系约定 | 冲突点 |
|---|---|---|---|
| 模型权重目录 | `getApplicationSupportDirectory()/colorizer/model.tflite` | `getApplicationSupportDirectory()/.model_cache/<id>/` | 不一致 |
| 分发方式 | 用户文件选择器导入（`FilePicker`，.tflite/.tflite.zip） | `CapabilityWeight` 运行期下载（.model_cache） | 非同一链路 |
| 校验 | `importModel` 复制即用，无 SHA256 | 下载强制 SHA256 | 缺校验 |

**统一方案（推荐）**：能力条目化后，权重经 `CapabilityWeight` 下载到 `.model_cache/<id>/ddcolor.tflite` 并 SHA256 校验；`resolveModelPath()` 落盘后**交给 colorizer 侧加载**。最小侵入做法：colorizer 侧把 `_modelDir`/`_modelFile` 提为可配置（见 §3），默认仍 `colorizer/`，插件 `onEnable` 时把 `.model_cache` 路径透传。**不做文件复制**（225MB 复制浪费 IO + 双份占空间），只做路径注入。

过渡期：在 colorizer 完成路径注入之前，插件可把权重下载到 `.model_cache/<id>/` 后通过 `importModel(sourcePath)` 现有入口载入（`importModel` 设计是「复制用户选中的文件到模型目录」，可复用为「复制权重新文件」，代价是双份 225MB，仅作过渡）。

---

## 6. 平台门闸与 probe 聚合

插件 `probe()`/`isEnabled()` 返回值必须聚合三层（与 UI 现有 `canUse = isAvailable && !kIsWeb && !_lowEnd` 对齐）：

```
probe('ai.colorize.ddcolor') 返回 CapabilityOk 的充要条件（全部为真）：
1. 平台：!kIsWeb 且 (io 平台)；Android 真机是否可用由「产品决策」定——
   注意：现有 UI 门闸 DesktopUi.isDesktopPlatform 不含 Android，若插件声明「io 即可用」会与现有行为不一致；
2. 模型：ColorizerManager.isAvailable == true（模型存在 + loadAsync 就绪）；
3. 算力：!ColorizerManager.isLowEndDevice()（RAM ≥ 4GB）。
```

注意：`capability_runtime.probe` 本身只看 artifact/weights，**不知道 colorizer 的模型是否就绪**——插件需在 `onEnable`/`bind` 里挂一次 `ensureLoaded`，并把 `isAvailable` 纳入自检。**不建议**把这三层塞进 capability_plugin 基类（那是通用设施，上色是特例）。

---

## 7. 验收清单（M4 交付 = 本文档 + 评审）

- [ ] 契约文档已产出（本文件），含输入/输出协议、并发/超时、目录、平台门闸、接口缺口
- [ ] 上色团队评审：接口缺口表（§3）排期（批量/取消/进度/algoVersion/路径注入）
- [ ] 文档漂移（§4）修正：`colorizer_io.dart` 类头注释更新（上色团队执行）
- [ ] metadata shell（`ai_colorize_capability.dart`）落地，走 `install` 范式（**不碰 colorizer*.dart**）
- [ ] 权重真实直链 + SHA256 填入（发布时）
- [ ] MuMu/桌面实测：上色条目可见、可启停、调用走 colorizer 锁不崩、降级不打断阅读
- [ ] 全量单测绿（含新增 capability 注册/自检测试）

---

## 8. 相关文件索引

- 能力侧：`lib/capabilities/capability_plugin.dart` / `capability_plugin_manager.dart` / `capability_runtime.dart` / `capability_artifact_store.dart` / `builtin_capabilities.dart` / `demo_native_capability.dart`（对接范本）
- 上色侧（只读参照，不碰）：`lib/utils/colorizer.dart`（条件导出）/ `colorizer_manager.dart`（单例+锁）/ `colorizer_backend.dart`（抽象+权威契约）/ `colorizer_io.dart`（TFLite 实现，类头注释过期）/ `colorizer_stub.dart`（web 兜底）
- UI 调用方：`lib/ui/reader_page.dart`（`_tryColorize` 管线）/ `lib/ui/settings_page.dart`（`_ColorizerSection` 门闸四元 switch）
- 辅助：`lib/ui/responsive.dart`（`DesktopUi.isDesktopPlatform` 定义）