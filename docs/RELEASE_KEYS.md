# 发布链与签名密钥（接手必读）

> 这份文档是给**接手这个项目的人或 AI** 看的。
> 本仓库是 **public**，所以这里**只写机制、路径和验证方法，绝不写任何私钥内容**。
> 你需要的东西在哪、缺了会怎样、怎么验证，下面全有。

---

## 一、先分清两套密钥（最容易搞错的地方）

这个项目有**两套完全独立**的密钥。混为一谈会导致严重误判——比如把"不能自动更新"错当成"装不上"。

| | 第一套：APK 签名 | 第二套：更新清单签名 |
|---|---|---|
| **Secret 名** | `KEYSTORE_BASE64`<br>`KEY_ALIAS`<br>`KEY_PASSWORD`<br>`STORE_PASSWORD` | `UPDATE_SIGNING_KEY` |
| **算法/格式** | Java keystore（`.jks`） | ECDSA P-256 私钥（JSON，base64 后存 Secret） |
| **作用** | 给 APK 做**系统签名** | 给 `release-manifest.json` 签名 |
| **决定什么** | 能不能**安装**、能不能**覆盖升级** | 能不能**自动安装**（不弹手动下载） |
| **缺失的后果** | 🔴 装不上 / 覆盖安装报签名冲突 | 🟡 只能手动下载，安全性不降低 |
| **状态** | 一直有，勿动 | 2026-11-26 起 |

**一句话：覆盖安装只看第一套。第二套缺了只是不能自动更新，不会导致装不上。**

---

## 二、第二套密钥（更新清单签名）的完整机制

### 为什么需要

更新包从 GitHub Releases 下载，但可能经过第三方镜像（ghproxy / ghfast）。
长度对得上 ≠ 是作者发的包。所以发布时给一份清单签名，App 端验签 + 验哈希，
通过才允许安装，镜像彻底降级为**不可信传输层**。

### 发布端（CI 自动做）

`.github/workflows/build.yml` 的 `manifest` job：

1. 枚举该 Release 的真实资产并下载
2. 现算每个附件的 `size` / `sha256`
3. 用私钥生成并签名 `release-manifest.json`（含 `version` / `sequence` / `minApp` / `assets`）
4. **自签自验**：调 `tool/verify_update_manifest.dart`，用 App 同一套验签代码检查
5. 通过才上传到 Release

任一步失败 → job 失败 → **不产出清单**（fail-closed，绝不伪造可信状态）。

### App 端（`lib/net/`）

| 文件 | 职责 |
|---|---|
| `update_manifest.dart` | 清单模型 + `kUpdatePublicKeysHex`（公钥锚点）+ `classify()` 可信度分级 |
| `update_checker.dart` | 拉 GitHub Release、匹配附件、读清单 |
| `update_download_manager.dart` | 下载 + 验哈希 + 决定装或不装 |

**关键闸门**（`update_download_manager.dart`）：

- `manifestVerified == false` → `_failUnverified()` → **一个安装器都不调**，改成提示手动下载
- 哈希不匹配 → 同样拒绝安装
- `_triggerInstall()` 里还有第二道纵深防御，防止新增调用点绕过

所以：**没有清单 = 不会装错东西，只是不能自动装。**

### 私钥在哪

| 位置 | 说明 |
|---|---|
| 发布机 `~/.xingmanxia/update_signing_key.json` | ⚠️ **不在仓库内，不入 git**。这是唯一的本地副本 |
| GitHub Secret `UPDATE_SIGNING_KEY` | base64 后的同一份密钥，CI 用 |

`.gitignore` 已兜底拦截 `*_signing_key.json` 和 `**/.xingmanxia/`，
即使有人手滑把私钥拷进仓库也不会被提交。

### 🔑 私钥不是秘密口令，但仍然是秘密

它**不能**写在任何会被提交的地方（包括这份文档、代码注释、issue、PR 描述）。
需要实际使用时，从 `~/.xingmanxia/update_signing_key.json` 读，
或从 GitHub Secret 取（本地无法读回 Secret，只能重新填）。

**如果私钥丢了怎么办**：生成新的，把新公钥**追加**到 `kUpdatePublicKeysHex`
（旧公钥保留，让存量清单还能验过），再把新私钥填进 Secret。旧清单从此失效，
但 App 会走 fail-closed 拒绝安装 → 用户手动下载即可，不会出错。

### 手上有私钥时怎么用

```bash
# 生成密钥对（首次 / 轮换）
dart run tool/sign_update_manifest.dart --genkey
# 会打印 PUBX / PUBY，把 "PUBX:PUBY" 追加进 lib/net/update_manifest.dart

# 给已有清单补/刷新签名
dart run tool/sign_update_manifest.dart <manifest.json>

# 从零生成并签名（CI 用的就是这条）
dart run tool/sign_update_manifest.dart --build \
  --out release-manifest.json --version 1.5.8 --sequence 12 --min-app 1.5.0 \
  --asset app-standalone-release.apk:android:<size>:<sha256>
```

私钥来源优先级：`--key <path>` > 环境变量 `UPDATE_SIGNING_KEY`（base64）> 默认路径 `~/.xingmanxia/update_signing_key.json`。

### 验证密钥是否配好（不需要私钥）

```bash
# 看仓库有哪些 secret（只列名字，不会泄露值）
gh api repos/lxfebd/clean_manhua_flutter/actions/secrets --jq '.secrets[].name'

# 验一份清单是否可被 App 接受（退出码 0=valid，1=invalid，2=用法错误）
dart run tool/verify_update_manifest.dart <release-manifest.json>
```

**发布前必查**：Release 上必须有 `release-manifest.json`。
没有 → 说明 `manifest` job 失败 → 自动更新对这批用户是关闭的。

---

## 三、第一套密钥（APK 签名）

`android/app/build.gradle.kts` 从 `android/key.properties` 读（**该文件不入库**）：

```properties
storePassword=...
keyPassword=...
keyAlias=...
storeFile=xingmanxia.jks
```

CI 里 `Decode signing key` 步骤把 `KEYSTORE_BASE64` 解成 `android/app/xingmanxia.jks`，
再写出 `key.properties`。

**fail-closed 规则**（P0-02）：tag/Release 构建时，四个 secret 缺任何一个
**直接 `exit 1`**，绝不用 debug 签名冒充正式包。

⚠️ 历史坑：这条检查最初写在 `signingConfig` 表达式里，Gradle **配置期**就求值，
导致缺 `key.properties` 时连 `flutter build apk --debug` 都失败（CI 连红两轮）。
现改为**惰性触发**——只在真正需要 release 签名时才检查。改这块务必注意这个区别。

nightly（内测包）用**同一把**正式密钥，否则装过内测包就装不上正式包。
唯一例外：仓库变量 `ALLOW_DEBUG_SIGNING=true` 时允许 debug 签名，会打警告。

---

## 四、市场索引签名（第三套，别搞混）

`lib/utils/index_signature.dart` 的 `kIndexPublicKeysHex` 是**能力市场 / 源市场
索引**的验签公钥，私钥在 `~/.xingmanxia/index_signing_key.json`
（与更新清单的私钥**不是同一把**）。

两者共用同一份签名实现（`tool/sign_index.dart`），只是签名对象和公钥列表不同。

---

## 五、排查速查表

| 现象 | 原因 | 处理 |
|---|---|---|
| Release 上没有 `release-manifest.json` | manifest job 失败（多半缺 `UPDATE_SIGNING_KEY`） | 补 Secret 后重跑该 job |
| App 更新时提示"无法验证更新包来源…请手动下载" | 正常 fail-closed，无清单 | 补清单，或直接手动装 |
| App 更新时提示"完整性校验失败" | 清单在但哈希不匹配（包被换/下载损坏） | 从官方 Release 重下 |
| 覆盖安装报签名冲突 | 第一套密钥（keystore）不一致 | 查 `KEYSTORE_*` 四个 secret，**与第二套无关** |
| CI 因缺秘钥直接红 | fail-closed 按设计 | 补 secret，别改成"警告放行" |
