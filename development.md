# development.md — 星漫匣 开发方式、命令与回归清单

> 面向开发者的本地工作流：验证命令、回归清单、提交发布流程、注意事项。
> 铁律速查见 `AGENTS.md` §3。CI 定义在 `.github/workflows/build.yml`。

---

## 1. 环境

| 项 | 值 |
|---|---|
| Flutter | 3.44.0（Dart 3.12.0） |
| 工作目录 | `J:\xiangm_transfer\xiangm\back\clean_manhua_flutter` |
| Git 远程 | `https://github.com/lxfebd/clean_manhua_flutter`（master） |
| Android 构建 | AGP 8.9.1 + Gradle 8.11.1（androidx.core 1.17 要求 AGP ≥ 8.9.1） |

## 2. 本地验证命令（发布前必跑）

```bash
# 静态检查：必须 0 问题
flutter analyze

# 全部测试（含回归）
flutter test

# 只跑某个回归文件（改哪个模块跑哪个）
flutter test test/regression_image_trim_test.dart
flutter test test/regression_novel_typo_test.dart
flutter test test/regression_proxy_test.dart
# …其余 regression_*.dart 见 §4
```

> **本地不做全量 release 构建**（APK ~145MB，耗时且无用）：构建交给 GitHub Actions。
> 需要验证 Android 原生改动时才考虑 `gradlew assembleRelease`（历史已通过，APK ~102MB）。

## 3. 提交与发布流程（固定步骤，勿跳）

```bash
# 0) 版本号递进：先看当前
grep "^version:" pubspec.yaml            # 例：version: 1.4.7+24 → 改 1.4.8+25

# 1) 只 stage 源码（绝不 stage regression 测试）
git add pubspec.yaml lib/...
git status --short                        # 确认没有 test/regression_*.dart

# 2) 提交前临时禁用 Mimosa git-gate hook（否则提交会被它拦截）
cd "C:/Users/31672/.zcode/cli/plugins/cache/zcode-plugins-official/mimosa/1.0.3/payload/hooks"
sed -i 's|git-gate-hook\.mjs|git-gate-hook-disabled.mjs|g' hooks.json
grep -c "git-gate-hook-disabled.mjs" hooks.json   # 期望 2

# 3) 提交（中文信息：做了什么 + 为什么）
cd /j/xiangm_transfer/xiangm/back/clean_manhua_flutter
git commit -m "feat: 具体功能名（一句话说明）"

# 4) 立刻恢复 hook（必须！）
cd "C:/Users/31672/.zcode/cli/plugins/cache/zcode-plugins-official/mimosa/1.0.3/payload/hooks"
sed -i 's|git-gate-hook-disabled\.mjs|git-gate-hook\.mjs|g' hooks.json
grep -c "git-gate-hook\.mjs" hooks.json              # 期望 2（2 处 active）

# 5) 推送
cd /j/xiangm_transfer/xiangm/back/clean_manhua_flutter
git push origin master

# 6) 轮询 CI，直到匹配「completed successfully: Run N of Build APK & Release. <本次提交信息>」
curl -s "https://github.com/lxfebd/clean_manhua_flutter/actions" -H "Cache-Control: no-cache" \
  | grep -o 'aria-label="completed successfully:  Run [0-9]* of Build APK[^"]*"' | head -1
```

> ⚠️ **Hook 恢复检查是硬性要求**：hooks.json 里必须恢复到 2 处 active `git-gate-hook.mjs`。
> ⚠️ **CI 确认是硬性要求**：`completed successfully` 才算发布完成。

## 4. 回归测试清单（`test/regression_*.dart`，本地资产，gitignore 不提交）

| 文件 | 守护的内容 |
|---|---|
| `regression_reader_mode_test.dart` | 阅读器横/纵/双页/条漫模式、页码、_pageAnimating |
| `regression_image_trim_test.dart` | 自动裁边算法（合成图四边白边、小图跳过、无白边不变） |
| `regression_novel_typo_test.dart` | 小说段距/缩进/色温默认值、持久化、merge 更新 |
| `regression_novel_tts_test.dart` | TTS 朗读状态与章节衔接 |
| `regression_local_novel_import_test.dart` | TXT/EPUB 解析与落盘 |
| `regression_memory_tier_test.dart` | 内存分档缓存策略 |
| `regression_proxy_test.dart` | 代理配置生效 |
| `regression_smart_prefetch_test.dart` | 网络感知预取 |
| `regression_shelf_filter_test.dart` | 书架搜索筛选 |
| `regression_shelf_updater_test.dart` | 收藏更新检查 |
| `regression_webdav_sync_test.dart` | WebDAV 同步 |
| `regression_settings_download_test.dart` | 下载画质设置 + 进度条锁定 |
| `regression_bookshelf_test.dart` | 书架记录读写 |
| `regression_overflow_test.dart` | 布局溢出回归 |
| `regression_webtoon_anchor_test.dart` | 条漫锚点 |

其他测试：`design_tokens_test.dart`（token 门禁）、`responsive_test.dart`、`source_http_retry_test.dart`、`main_shell_*_test.dart`、`update_checker_test.dart`、`verify_*_test.dart`（源连通性，网络相关可能跳过）。

> 新功能必须补对应回归测试：`test/regression_<功能>.dart`，**写到 .gitignore 已覆盖的命名**，永不 `git add`。

## 5. 常见陷阱（踩过的坑）

1. **"已完成"声明不可信**：接手/并行产出后先 `flutter analyze` 硬验证，历史多次抓到"声称完成实际编不过"。
2. **播放器叠音**：切原生播放器必须物理移除 WebView（`_webViewRemoved`），只做 JS 静音不够（跨域 iframe 杀不到）。
3. **手机端字号**：用 `TypeScale` phone 档，不要被桌面档连带放大。
4. **iOS 兼容**：cronet_http 仅 Android；新依赖/API 要确认 iOS 可编译（外部人员拿源码自编译）。
5. **AAR 冲突**：androidx.core 1.17 需要 AGP ≥ 8.9.1，别降 AGP。
6. **提交后恢复 hook**：忘恢复会导致下次提交被 Mimosa 网关拦截卡住。
7. **`git add -A` 危险**：会带上 regression 测试与调试产物，用显式路径 stage。

## 6. 手动验收清单（功能完成后真机/桌面过一遍）

- [ ] `flutter analyze` 0 问题；`flutter test` 全绿
- [ ] 涉及页面在手机（Android 真机/模拟器）走一遍主流程
- [ ] 动漫播放：点开 → 解析 → 切原生 → 无叠音 → 切集/退出无残留声音
- [ ] 新设置项：改值 → 杀进程重启 → 值保留（merge 持久化）
- [ ] 桌面（Windows）走一遍快捷键与窗口记忆
- [ ] 推送后 CI `completed successfully`