# 构建环境基线（P2-28）

本地与 CI 统一使用下面这套版本。**改版本必须同时改这里与 workflow。**

| 组件 | 版本 | 来源 |
|---|---|---|
| Flutter | **3.41.9**（stable） | 本机 `flutter --version` 实测；CI `flutter-version` |
| Android compileSdk | **36** | `android/app/build.gradle.kts` |
| Android SDK Platform | **android-36** | CI `sdkmanager` 显式安装 |
| Android Build Tools | **36.0.0** | 本机 `flutter doctor` / CI |
| Android NDK | **28.2.13676358** | 与 cronet / media_kit 原生依赖对齐 |
| Java | **21** | 本机 `java -version`；CI setup-java |

## 为什么钉死

此前本机是 Flutter 3.41.9、Android SDK 36，CI 却写 Flutter 3.44.0、
`platforms;android-34`。这意味着「本地全绿」与「CI 全绿」说的不是同一套
编译器与平台库；而 `compileSdk=36` 还会让 CI 在构建时隐式补下载 SDK，
进一步掩盖环境漂移。

现在 CI 会显式安装 `android-36` / `build-tools;36.0.0`，并把
`flutter --version` 与 `sdkmanager --list_installed` 打进日志。

## 本机注意事项

本机用户级环境变量里 `FLUTTER_ROOT` / `PUB_CACHE` / `DART_SDK` /
`GRADLE_USER_HOME` 仍指向已不存在的 G: 盘。跑命令前必须清掉：

```bash
unset FLUTTER_ROOT PUB_CACHE DART_SDK GRADLE_USER_HOME
```

 Flutter 实际位置：`C:/flutter`。
