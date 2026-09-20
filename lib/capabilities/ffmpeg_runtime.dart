import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../net/error_logger.dart';
import '../ui/responsive.dart' show DesktopUi;
import 'capability_artifact_store.dart';
import 'capability_plugin.dart';

/// ffmpeg 运行期分发（F2 离线导出依赖）：直链下载 zip + SHA256 校验 + 幂等。
///
/// 复用 CapabilityArtifactStore（与 AI 插帧引擎包同套路）：
/// - 落盘 `<support>/capabilities/tool.ffmpeg/`
/// - 已就绪（exe 已在目录）→ 直接复用；未就绪 → 下载 zip + 解压（幂等）
/// - **版本钉死**：zipUrl/zipSha256 由发布方配置，空值绝不下载（红线：
///   绝不静默使用未校验文件）。待发布：发布方把 ffmpeg zip 打包（根目录含
///   ffmpeg(.exe)）上传后填 [zipUrl] / [zipSha256]。
///
/// 与 AI 插帧引擎包差异：ffmpeg 是通用导出依赖，不是用户可开关的「能力」，
/// 故不注册成 CapabilityPlugin（能力中心不出现卡片），仅作为运行时构件。
///
/// Android（F4）：ffmpeg 交叉编译为静态二进制后以 `libffmpeg.so` 名义打进
/// jniLibs（PM 提取到 nativeLibraryDir —— Android 10+ 唯一可靠的 exec 路径；
/// targetSdk≥29 的应用不允许 exec 应用可写目录里的文件）。也支持把 ffmpeg
/// 放到 artifactDir 作手动兜底（debug 实测用）。
class FfmpegRuntime {
  FfmpegRuntime._();

  static const String capabilityId = 'tool.ffmpeg';

  /// 下载包名（zip，根目录含 ffmpeg(.exe)）。
  static const String zipZipName = 'ffmpeg-win-x86_64.zip';

  /// jniLibs 打包名（Android）：PM 会解包到 nativeLibraryDir。
  static const String androidLibName = 'libffmpeg.so';

  /// exe 文件名（平台相关，解压后）。
  static String get exeName => Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';

  /// 分发直链 / SHA256（hex 小写）。**发布方待填**；空值 = 未配置，
  /// ensure() 返回明确原因，绝不下载未钉死的文件。
  static String zipUrl = '';
  static String zipSha256 = '';

  /// 是否已配置直链（供 UI/导出服务判断是否需要提示发布方配置）。
  static bool get isConfigured => zipUrl.isNotEmpty && zipSha256.isNotEmpty;

  /// 平台门闸（桌面 + Android；ffmpeg 构件只在这两类平台有分发）。
  static bool get isSupported =>
      !kIsWeb && (DesktopUi.isDesktopPlatform || Platform.isAndroid);

  /// 已就绪的 exe 绝对路径；未就绪返回 null。
  static Future<String?> locate() async {
    // Android：jniLibs 提取目录优先（SELinux 允许 exec 的唯一常规路径；
    // ABI 子目录名与 jniLibs 不一致 → 用枚举候选，见
    // CapabilityArtifactStore.nativeLibCandidates），其次 artifactDir 兜底。
    for (final c
        in CapabilityArtifactStore.nativeLibCandidates(androidLibName)) {
      final f = File(c);
      if (f.existsSync()) return f.path;
    }
    final dir = await CapabilityArtifactStore.instance.artifactDir(capabilityId);
    if (dir == null) return null;
    final exe = await _findExe(dir);
    return exe;
  }

  /// ffmpeg 就绪检查/准备：zip 下载 + SHA256 校验 + 解压（幂等）。
  ///
  /// 返回 null = 就绪；否则用户可读原因（未配置直链/下载失败/校验失败/
  /// 解压失败/解压后缺 exe）。下载前绝不使用未校验文件。
  static Future<String?> ensure() async {
    if (!isSupported) {
      return 'ffmpeg 分发仅支持桌面端与 Android';
    }
    final dir = await CapabilityArtifactStore.instance.artifactDir(capabilityId);
    if (dir == null) return '当前平台不支持本地构件';

    // 已就绪 → 直接复用（幂等，避免重复下载）。
    if (await _findExe(dir) != null || await locate() != null) return null;

    // Android：jniLibs 内置 + artifactDir 都没有 → 直接失败（Android 无
    // unzip/PowerShell，运行期 zip 解压路径走不通；引擎随 APK 打包）。
    if (Platform.isAndroid) {
      return 'Android ffmpeg 未内置（需 jniLibs 提供 $androidLibName）';
    }

    // 未就绪：直链未配置 → 明确提示（版本红线：空 SHA256 绝不下载）。
    if (zipUrl.isEmpty || zipSha256.isEmpty) {
      return 'ffmpeg 分发未配置（待发布方提供直链 + SHA256），'
          '本机开发可用 FFMPEG_PATH/PATH 兜底';
    }

    // 下载（download 内部完成 SHA256 校验，不匹配即拒绝落盘）。
    final store = CapabilityArtifactStore.instance;
    final zip = await store.download(
      capabilityId,
      CapabilityArtifact(
        url: zipUrl,
        sha256: {Platform.operatingSystem: zipSha256},
      ),
    );
    if (zip == null || !await zip.exists()) {
      return store.lastError ?? 'ffmpeg 包下载失败';
    }
    // 解压 zip 到 artifactDir（覆盖式，幂等）。
    try {
      if (Platform.isWindows) {
        // 参数用数组逐项传入，幂等命令由 dash args 组装——不把路径拼进
        // 命令文本，避免含空格路径被错误引号破坏。
        final out = await Process.run('powershell', [
          '-NoProfile', '-Command',
          'Expand-Archive',
          '-LiteralPath', zip.path,
          '-DestinationPath', dir.path,
          '-Force',
        ]);
        if (out.exitCode != 0) {
          ErrorLogger.instance
              .warn('[capability] ffmpeg unzip failed: ${out.stderr}');
          return 'ffmpeg 解压失败，请检查磁盘空间与权限';
        }
      } else {
        final out = await Process.run('unzip', ['-o', zip.path, '-d', dir.path]);
        if (out.exitCode != 0) {
          ErrorLogger.instance
              .warn('[capability] ffmpeg unzip failed: ${out.stderr}');
          return 'ffmpeg 解压失败，请检查磁盘空间与权限';
        }
      }
    } catch (e) {
      ErrorLogger.instance.warn('[capability] ffmpeg unzip error: $e');
      return 'ffmpeg 解压失败，请重试';
    }
    if (await _findExe(dir) == null) {
      return 'ffmpeg 包解压后未找到 ${Platform.operatingSystem} 的 $exeName';
    }
    return null; // 就绪
  }

  /// 在 artifactDir 内查找 exe（根 + 一层子目录，兼容 zip 带顶层目录）。
  static Future<String?> _findExe(Directory dir) async {
    final direct = File('${dir.path}/$exeName');
    if (direct.existsSync()) return direct.path;
    if (!dir.existsSync()) return null;
    for (final e in dir.listSync()) {
      if (e is Directory) {
        final f = File('${e.path}/$exeName');
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }
}