# 多 AI 并行任务协作规矩

> 目标：星漫匣仓库被多个 AI 任务并行触碰时，保持 git 干净、文件不互相覆盖、进度可回退。
> 适用范围：任何同时跑的 AI 会话（上色 agent、能力插件、其他功能线）。
> 状态：2026-09-12 定案。

## 1. 模块隔离（最重要）

每个并行任务**只碰自己的目录/文件**，越界前先确认没有其他任务在用：

| 任务线 | 专属范围 | 红线 |
|---|---|---|
| 能力插件化（M1–M4） | `lib/capabilities/`、`docs/colorizer-capability-contract.md` | 不碰 `colorizer*.dart` |
| AI 上色（独立 agent） | `lib/utils/colorizer*.dart` | 不碰 `lib/capabilities/` |
| 播放器 | `lib/ui/native_player_page.dart`、`lib/ui/anime_player_page.dart` | — |
| 阅读器 | `lib/ui/reader_page.dart`、`lib/ui/reader_mode_geometry.dart` | — |
| 源/网络 | `lib/sources/`、`lib/net/` | — |
| 通用共享 | `lib/ui/responsive.dart`、`lib/theme.dart`、`pubspec.yaml`、`PLANNING.md` | 改前先 `git status`，短时间占用 |

**规则**：共享文件（responsive.dart / theme.dart / pubspec.yaml / PLANNING.md）一次只允许一个任务在改；改完立即 commit 释放。

## 2. 开工前检查

```bash
git status --short        # 必须为空或只有自己预期的文件
git log --oneline -3      # 确认别人没刚提交新东西
```

- 非空 → 先搞清楚是谁的改动，**不要在自己不理解的脏工作区上开工**。
- 看到陌生文件被改 → 问对应任务线，或直接 commit 前 review 差异。

## 3. 每个任务完成立即 commit（本地即可，不用 push）

```bash
git add <自己的文件>          # 只 add 自己的，绝不 git add -A 吞掉别人的未提交改动
git commit -m "中文描述：改了什么（版本+x）"
```

- **禁止 `git add -A` / `git add .`** 在有他人未提交改动时使用。
- commit 粒度：一个功能一个 commit，消息写清楚「任务线 + 内容 + 版本号」。
- 红线：**不 push**（公开仓库，需用户明确同意才远程操作）。

## 4. 别用会把历史搞乱的操作

- 不做 `git rebase`、`git reset --hard`、`git commit --amend`、`git push -f`（这些会产生 dangling commit / 覆盖历史，多任务下尤其危险）。
- 需要撤销自己的本地提交 → 用 `git reset --soft`（保留改动）或问主会话。

## 5. 版本号纪律

- 每个 batch 实测/交付前，`pubspec.yaml` 版本 `+1`（当前 1.4.3+71 → 下一个 +72）。
- 版本号是并行任务之间**检测冲突的哨兵**：如果两个任务都改了版本号，说明撞车了。

## 6. 红线总表（跨任务生效）

- 绝不 push 到 GitHub（任何远程写操作先展示清单 + 用户同意）
- `.model_cache/` 永远为空（权重仅运行时下载，不入 git、不进 APK）
- 不碰 `colorizer*.dart`（上色独立 agent 专属）
- `.gitignore` 已忽略的调试产物（tool/、*.log、tmp_* 等）不主动入库
- PLANNING.md 每次任务后同步勾选状态
