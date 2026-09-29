import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../net/http_client.dart' show Net;
import '../net/error_logger.dart';
import 'capability_path_safety.dart';
import 'capability_plugin.dart';

/// 能力构件存储：下载 + SHA256 校验 + 落盘（桌面 artifact / 权重统一入口）。
///
/// 设计 §12「三件绕不过的事」的落地：
/// - 桌面 artifact（.dll/.dylib/.so）直链下载到应用支持目录 →
///   `DynamicLibrary.open(绝对路径)`（无 SELinux 限制，M2 先在这验证全链路）。
/// - 权重统一进 `.model_cache/`（项目红线：该目录保持为空，权重仅运行期下载，
///   不入 git、不进 APK）。
/// - **版本钉死**：下载完成必须 SHA256 校验，不匹配即删除并返回明确失败，
///   绝不静默使用未校验文件。
class CapabilityArtifactStore {
  CapabilityArtifactStore._();

  static final CapabilityArtifactStore instance = CapabilityArtifactStore._();

  /// 测试注入：覆盖应用支持目录（flutter_test 下 path_provider 无 platform
  /// channel，直接用临时目录）。
  Directory? testOverrideDir;

  /// 应用支持目录（artifact 落盘根）。
  /// 非 web 平台：getApplicationSupportDirectory；web 端无文件系统返回 null。
  Future<Directory?> _baseDir() async {
    if (testOverrideDir != null) return testOverrideDir;
    if (kIsWeb) return null;
    try {
      return await getApplicationSupportDirectory();
    } catch (_) {
      return null;
    }
  }

  /// 能力 id 合法性：字母开头，其后仅字母/数字/点/下划线/连字符，且不得含 `..`。
  /// id 直接拼进落盘路径（`capabilities` 与 `.model_cache` 下的 id 子目录），
  /// 放开 `../` 会让恶意市场索引越界写文件/递归删目录（purge）。
  /// 必须字母开头：`.` / `..` 若放行会解析成父目录本身，`purge('.')` 会清空整树。
  static bool isValidId(String id) => isValidPathSegment(id);

  /// 落盘文件名白名单（artifact 文件名 / 权重 name 通用）：与 [isValidId]
  /// 同规则。这两处同样是把**远端可控字符串**（URL path 最后一段 percent
  /// 解码后可含 `/`，权重 name 来自市场索引）直接拼进路径——`%2e%2e%2f`
  /// 解码成 `../` 即可写出 id 目录之外，故必须先过白名单再拼接。
  static bool isValidFileName(String name) => isValidPathSegment(name);

  /// artifact 落盘目录：`support/capabilities/` 下的 id 子目录
  /// （id 必须通过 [isValidId]）。
  Future<Directory?> artifactDir(String id) async {
    if (!isValidId(id)) return null;
    final base = await _baseDir();
    if (base == null) return null;
    final d = Directory('${base.path}/capabilities/$id');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 权重落盘目录：`support/.model_cache/` 下的 id 子目录
  /// （id 必须通过 [isValidId]）。
  /// 项目红线：`.model_cache/` 保持为空（权重仅运行期下载，不入 git/APK）。
  Future<Directory?> weightDir(String id) async {
    if (!isValidId(id)) return null;
    final base = await _baseDir();
    if (base == null) return null;
    final d = Directory('${base.path}/.model_cache/$id');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// jniLibs 提取目录里的候选文件路径（Android 专用）。
  ///
  /// ⚠️ Android 上 `Platform.resolvedExecutable` 是 `/system/bin/app_process64`
  /// 而非 base.apk，**不能**用它推 nativeLibraryDir。这里从 `/proc/self/maps`
  /// 提取本进程已加载的自身 so（libflutter.so 等）所在目录 —— extractNativeLibs
  /// 开启时它就是 nativeLibraryDir（`/data/app/…/lib/<abi>`，ABI 子目录名与
  /// jniLibs 目录名还不一致，如 `arm64-v8a`→`arm64`）。返回按优先级排序的候选。
  static List<String> nativeLibCandidates(String fileName) {
    if (kIsWeb || !Platform.isAndroid) return const [];
    final cands = <String>[];
    try {
      final maps = File('/proc/self/maps').readAsStringSync();
      final m = RegExp(r'(/data/app/[^/\s]+/[^/\s]+/lib/[a-zA-Z0-9_]+)/lib')
          .firstMatch(maps);
      if (m != null) cands.add('${m.group(1)}/$fileName');
    } catch (_) {}
    return cands;
  }

  /// 计算本地文件 SHA256（hex 小写）。文件不存在返回 null。
  Future<String?> sha256Of(File f) async {
    try {
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return sha256.convert(bytes).toString();
    } catch (_) {
      return null;
    }
  }

  /// artifact 落盘文件名：取 URL 最后一段，过白名单；非法（percent 解码后
  /// 含 `/`、`..`、空等）则退回 `<id>.artifact`——id 已过 [isValidId]，
  /// 派生名恒安全。纯函数，便于单测锁死「恶意 URL 不产生越界路径」。
  static String artifactFileName(String id, String url) {
    final raw = Uri.parse(url).pathSegments
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    return (raw != null && isValidFileName(raw)) ? raw : '$id.artifact';
  }

  /// 按当前平台从 per-ABI SHA256 map 中选出期望值。
  ///
  /// 远端索引若把 `arm64-v8a` 排在首位、`windows-x64` 排在后位，直接取
  /// `values.first` 会在 Windows 上拿到 arm 的 hash，本地 DLL 校验必失败。
  /// 这里按当前 [Platform] 优先匹配已知 ABI key，找不到（或 key 集为空）再
  /// 退回首值——保留「索引只提供一个通用 hash」的兼容路径。
  ///
  /// key 命名约定：与 [CapabilityRuntime._currentAbi] 同源但更细：桌面按
  /// `-x64` 后缀（`windows-x64` / `macos-x64` / `linux-x64`），Android 走
  /// NDK ABI 名（`arm64-v8a` / `armeabi-v7a` / `x86_64` / `x86`）。索引里
  /// 若仅写平台名（如 `windows` / `macos` / `linux` / `android`）也一并匹配。
  ///
  /// [platformKeyOverride] 仅测试用：VM 的 [Platform] 常量无法在 flutter_test
  /// 里改成 macOS/Android，单测要覆盖「arm 在前 win 在后」这类跨平台取 key
  /// 场景时通过它显式指定平台键。
  static String? expectedSha256ForCurrentPlatform(
    Map<String, String> sha256, {
    String? platformKeyOverride,
  }) {
    if (sha256.isEmpty) return null;
    final platformKey = platformKeyOverride ?? _currentPlatformKey();
    // 优先精确 ABI key；未声明再退平台名；再退首值（单一 hash 兼容）。
    return sha256[_abiKeyForPlatform(platformKey)] ??
        sha256[platformKey] ??
        sha256.values.first;
  }

  /// 平台键：与 [CapabilityRuntime._currentAbi] 语义一致（`windows` /
  /// `macos` / `linux` / `android` / `web`）。
  static String _currentPlatformKey() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 平台键 → 优先 ABI key（索引里通常把桌面写成 `<platform>-x64`）。
  static String _abiKeyForPlatform(String platformKey) {
    switch (platformKey) {
      case 'windows':
        return 'windows-x64';
      case 'macos':
        return 'macos-x64';
      case 'linux':
        return 'linux-x64';
      case 'android':
        // Android 默认 arm64（新设备主流）；老设备 armeabi-v7a / x86_64 由
        // 索引里同名键覆盖，或走平台键兜底。
        return 'arm64-v8a';
      default:
        return platformKey; // web/unknown：不做架构细化
    }
  }

  /// [f] 是否确实落在 [dir] 之内（兜底校验：白名单是第一道闸，这里防未来
  /// 改动把带 `..` 的字符串再拼进来）。按段解析 `.`/`..` 后逐段比较——
  /// `File.absolute` 不解析 `..`，直接前缀比较会把 `base/../x` 误判成在 base 内。
  static bool isInside(Directory dir, File f) {
    // 解析为规范化段列表；`..` 越过根时返回 null（越界，一律不算在内）。
    List<String>? segs(String p) {
      final out = <String>[];
      for (final s in p.replaceAll('\\', '/').split('/')) {
        if (s.isEmpty || s == '.') continue;
        if (s == '..') {
          if (out.isEmpty) return null;
          out.removeLast();
        } else {
          out.add(s);
        }
      }
      return out;
    }

    final base = segs(dir.absolute.path);
    final path = segs(f.absolute.path);
    if (base == null || path == null) return false;
    if (path.length <= base.length) return false; // 必须是 dir 下的文件，不是 dir 本身
    for (var i = 0; i < base.length; i++) {
      if (base[i] != path[i]) return false;
    }
    return true;
  }

  /// 下载/就绪单个 artifact，返回本地文件。
  /// - 桌面（[CapabilityArtifact.url]）：直链下载到应用支持目录。
  /// - Android：构建期 bundle（jniLibs / Maven AAR），运行期系统 loader 直接
  ///   加载，不经过本方法（见 CapabilityRuntime.probe 的 embedded 分支）。
  /// 失败返回 null（原因可由调用方通过 [lastError] 读取）。
  Future<File?> download(
    String id,
    CapabilityArtifact artifact, {
    String? proxy,
  }) async {
    final dir = await artifactDir(id);
    if (dir == null || artifact.url == null) return null;
    final url = artifact.url!;
    final target = File('${dir.path}/${artifactFileName(id, url)}');
    if (!isInside(dir, target)) {
      _lastError = '构件文件名非法，已拒绝落盘';
      ErrorLogger.instance.warn('[capability] artifact path escapes dir ($id)');
      return null;
    }

    // 已存在且 SHA256 匹配 → 直接复用（幂等，避免重复下载）。
    // 按当前平台选期望 hash：远端索引可能按 arm 在前 / win 在后排列，
    // 直接取 values.first 会在桌面机误取手机 ABI 的 hash 导致校验必失败。
    final expected = expectedSha256ForCurrentPlatform(artifact.sha256);
    if (await target.exists()) {
      final cur = await sha256Of(target);
      if (expected == null || cur == expected) {
        return target;
      }
      // 校验失败 → 删除损坏文件，重新下载。
      try {
        await target.delete();
      } catch (_) {}
    }

    // 下载（Net.getBytesAuto：优先 Cronet；proxy 覆盖时走 dart:io）。
    final List<int> bytes;
    try {
      bytes = await Net.getBytesAuto(url, proxy: proxy);
    } catch (e) {
      _lastError = '构件下载失败，请检查网络后重试';
      ErrorLogger.instance.warn('[capability] artifact download failed ($id): $e');
      return null;
    }
    if (expected != null) {
      final got = sha256.convert(bytes).toString();
      if (got != expected) {
        _lastError =
            '构件 SHA256 校验失败（期望 $expected，实际 $got），已拒绝使用';
        return null;
      }
    }
    // 校验完成 → 原子落盘（先写 .tmp 再 rename，避免崩溃留下半截构件；
    // 与权重落盘同套路）。tmp 与目标同目录保证 rename 原子性。
    final tmp = File('${target.path}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      return target;
    } catch (e) {
      _lastError = '构件写入本地失败，请检查存储空间与权限';
      ErrorLogger.instance.warn('[capability] artifact write failed ($id): $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
  }

  /// 下载/就绪单个权重（[CapabilityWeight]），返回本地文件。
  ///
  /// 统一落 `<support>/.model_cache/<id>/<name>`（项目红线：仅运行期下载）。
  /// - 已存在且 SHA256 匹配 → 直接复用（幂等，避免重复下载 225MB）。
  /// - 缺失/损坏 → 下载 + SHA256 校验，不匹配即删除并返回 null（明确失败）。
  /// 失败返回 null（原因由调用方通过 [lastError] 读取）。
  Future<File?> downloadWeight(
    String id,
    CapabilityWeight weight, {
    String? proxy,
  }) async {
    final dir = await weightDir(id);
    if (dir == null || weight.url.isEmpty) return null;
    // 权重 name 来自市场索引（完全远端可控）：白名单 + 包含校验双重闸，
    // 含 `../` 的 name 会让 `writeAsBytes` 越出 `.model_cache/<id>/`。
    if (!isValidFileName(weight.name)) {
      _lastError = '权重文件名非法，已拒绝落盘';
      ErrorLogger.instance
          .warn('[capability] weight filename rejected ($id): ${weight.name}');
      return null;
    }
    final target = File('${dir.path}/${weight.name}');
    if (!isInside(dir, target)) {
      _lastError = '权重文件名非法，已拒绝落盘';
      ErrorLogger.instance
          .warn('[capability] weight path escapes dir ($id): ${weight.name}');
      return null;
    }

    // 幂等：已存在且哈希匹配直接复用。
    if (await target.exists()) {
      final cur = await sha256Of(target);
      if (weight.sha256.isEmpty || cur == weight.sha256) {
        return target;
      }
      // 校验失败 → 删除损坏文件，重新下载。
      try {
        await target.delete();
      } catch (_) {}
    }

    // 下载（Net.getBytesAuto：优先 Cronet；proxy 覆盖时走 dart:io）。
    // 权重可达数百 MB，必须给足超时（Net 默认 15s 会必超时失败）。
    final List<int> bytes;
    try {
      bytes = await Net.getBytesAuto(weight.url,
          proxy: proxy, timeout: const Duration(minutes: 10));
    } catch (e) {
      _lastError = '权重下载失败，请检查网络后重试';
      ErrorLogger.instance.warn('[capability] weight download failed ($id): $e');
      return null;
    }
    if (weight.sha256.isNotEmpty) {
      final got = sha256.convert(bytes).toString();
      if (got != weight.sha256) {
        _lastError =
            '权重 SHA256 校验失败（期望 ${weight.sha256}，实际 $got），已拒绝使用';
        return null;
      }
    }
    // 校验完成 → 原子落盘：先写 `.tmp` 再 rename。直接 writeAsBytes 时
    // 若中途崩溃/断电，目标文件是半截内容——下次运行 sha256 不匹配会重新
    // 下载（浪费几百 MB），更糟的是被误读成"已存在"直接复用（幂等分支
    // 只认 hash 不认完整性以外的任何信息，此路径 hash 必不匹配，安全）。
    // tmp 文件名 = 目标名 + .tmp 后缀：同目录保证 rename 原子性（跨目录
    // rename 在 Windows 上可能因文件系统不同而失败）。
    final tmp = File('${target.path}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      return target;
    } catch (e) {
      _lastError = '权重写入本地失败，请检查存储空间与权限';
      ErrorLogger.instance.warn('[capability] weight write failed ($id): $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
  }

  /// 最近一次失败原因（供 UI 展示明确错误）。
  String? _lastError;
  String? get lastError => _lastError;
  void clearError() => _lastError = null;

  /// 删除某能力的全部本地构件（卸载/重新安装时清理）。
  Future<void> purge(String id) async {
    for (final d in [await artifactDir(id), await weightDir(id)]) {
      try {
        if (d != null && await d.exists()) {
          await d.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
}
