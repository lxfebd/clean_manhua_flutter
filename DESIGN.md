# DESIGN.md — 星漫匣 视觉与设计规则

> 本文件是**整个项目的视觉规则**：设计 token、字号分档、配色、布局断点、动效、组件风格。
> 新写 UI 一律从这里取值，禁止在页面里手写散落的 fontSize / borderRadius / alpha 字面量。
> Token 代码权威源：`lib/ui/tokens.dart`；响应式断点：`lib/ui/responsive.dart`。

---

## 1. 设计基调

- **风格**：极简（Minimalist）—— 卡片层级靠 hairline 描边，阴影退为极淡中性投影（`D.soft`），不使用辉光（`D.glow` 返回空阴影）。
- **明暗**：支持亮 / 暗 / 跟随系统，Material 3 seed 换肤；播放器类页面（动漫）恒为纯黑影院底。
- **目标**：信息密度适中、可读性优先、动效克制（160/280/480ms 三档）。

## 2. 设计 Token（唯一取值来源）

### 2.1 间距 `S`（6 档）

| Token | 值 | 用途 |
|---|---|---|
| `S.x4` | 4 | 微距（图标与文字间） |
| `S.x8` | 8 | 紧凑间距 |
| `S.x12` | 12 | 常规间距 |
| `S.x16` | 16 | 页面内边距 |
| `S.x24` | 24 | 区块间距 |
| `S.x32` | 32 | 大区块间距 |

### 2.2 圆角 `R`（5 档）

| Token | 值 | 用途 |
|---|---|---|
| `R.control` | 8 | 按钮 / 输入框 / chip |
| `R.card` | 12 | 卡片 / 封面 |
| `R.hero` | 16 | 横幅 / 大图 |
| `R.sheet` | 24 | 底部弹层（抽屉） |
| `R.pill` | 999 | 胶囊全圆 |

### 2.3 文字透明度 `T`（6 档）

`TextTier { high, mid, low, disabled, hairline, fill }` → `T.alphaFor(tier, brightness)`：

| 档位 | 亮色主题 | 说明 |
|---|---|---|
| `high` | 1.0 | 正文 |
| `mid` | 0.78 | 次要文字 |
| `low` | 0.62 | 弱化文字（**亮色下 WCAG AA ≥ 4.5**） |
| `disabled` | 0.45 | 禁用态 |
| `hairline` | 0.08 | 分隔线 |
| `fill` | 0.06 | 填充底色（卡片底） |

用法：`T.color(baseColor, TextTier.mid, brightness: b)`。

### 2.4 字号阶 `TypeScale`（6 档 × 手机/大屏）

页面一律 `Theme.of(context).textTheme.xxx`，**禁止内联 fontSize**。

| 档位 | TextTheme | 平板/桌面 | 手机（<600dp） |
|---|---|---|---|
| display | displaySmall | 22 / w700 | 19 |
| title | titleLarge | 17 / w600 | 17 |
| section | titleMedium | 15 / w600 | 14 |
| body | bodyMedium | 14 / w400 | 14 |
| meta | bodySmall | 12 | 12 |
| micro | labelSmall | 11 / w500 | 9 |

> ⚠️ **手机档独立**：`TypeScale.textTheme(color, isTablet: false)` 在手机端用 phone 档，
> 避免手机端被桌面档字号连带放大（历史教训：手机端曾因共用桌面档被放大）。

## 3. 配色

- **全局**：Material 3 `ColorScheme.fromSeed`，用户可在设置里换种子色（`_themeId`）。
- **正文层级**：`onSurface` 搭配 `T` 透明度档位，不写死灰度。
- **强调色**：`colorScheme.primary`；选中态 chip/按钮用 primary 填充 + 白字。
- **特殊页**：
  - 动漫播放页：纯黑背景（`Colors.black`），控件白/白30 层级，`PlayerColors.accent` 做强调。
  - 小说阅读器：支持自定义背景（米白/浅绿/深青 + 跟随），色温护眼滤镜（0~100，暖色 `0xFFFF9E4D` 半透明叠加）。
  - 错误/空态：`state_view.dart` 统一组件，图标 + 弱化文字 + 重试按钮。

## 4. 响应式断点（`lib/ui/responsive.dart`）

| 断点 | 阈值 | 行为 |
|---|---|---|
| 手机 | 宽 < 600dp | 单列堆叠，字号用 phone 档 |
| 平板 | ≥ 600dp | 播放页横屏分栏：左视频 16:9 + 右 `kPlayerPanelWidth` 控制面板 |
| 桌面 | DesktopUi | 键盘快捷键可用、窗口记忆、小说阅读器限宽 `novelReaderMaxWidth` |

- 平板始终允许竖屏+横屏旋转（避免 letterbox）；手机阅读/播放页按需锁横屏、退出恢复竖屏。
- 小说阅读器正文区用 `ConstrainedBox(maxWidth: novelReaderMaxWidth)` 限宽，长行不铺满。

## 5. 动效（`D` token）

| Token | 值 | 用途 |
|---|---|---|
| `D.fast` | 160ms | 按压反馈 / 小元素过渡 |
| `D.medium` | 280ms | 面板/抽屉出现 |
| `D.slow` | 480ms | 大场景过渡 |

曲线：`D.easeOut`（easeOutCubic）、`D.easeInOut`、`D.spring`（回弹，用于弹幕等）。

## 6. 组件风格约定

- **按钮**：`FilledButton` / `OutlinedButton` / `TextButton` 标准组件；小按钮用 `TapTarget`（见 component-api）。
- **底部弹层**：`showModalBottomSheet` 圆角 `R.sheet`(24)，顶部 36×4 白色拖拽条，标题 16/w700。
- **选项 chip**：胶囊圆角，选中态 primary 填充 + 白字 + primary 描边，未选中白 6% 底 + 白 10% 描边。
- **卡片**：`R.card`(12) 圆角，层次靠 hairline 描边（`T.hairline`），阴影用 `D.soft(dark)`。
- **播放器控件**：自绘半透明黑底圆角，常用 `PlayerColors.accent` 强调当前状态。
- **错误/空态**：`StateView` 统一（图标 34 + 弱化文字 + 可选重试按钮）。

## 7. 禁止事项

- 禁止内联 `fontSize` / `BorderRadius.circular(随意值)` / 随手 alpha（应用 `T` 档位）。
- 禁止在页面里硬编码间距数值（应用 `S`）。
- 禁止给手机端引入桌面档字号（用 phone 档）。
- 禁止新增散落 `Colors.white.withValues(alpha: …)` 字面量（播放器深色面板除外，走 `PlayerColors`）。
