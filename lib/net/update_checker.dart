import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'error_logger.dart';
import 'http_client.dart';

/// GitHub Releases 上的最新版本信息。
class UpdateInfo {
  final String version;
  final String? notes;
  final String apkUrl;
  final String? tagName;

  /// 附件文件名（用于提示用户手动下载时确认文件）。
  final String? assetName;

  const UpdateInfo({
    required this.version,
    this.notes,
    required this.apkUrl,
    this.tagName,
    this.assetName,
  });
}

/// 选中的 release 附件（文件名 + 下载地址）。
class UpdateAsset {
  final String name;
  final String url;
  const UpdateAsset(this.name, this.url);
}

/// 版本更新检查：从 GitHub Releases 拉取最新版，与本机版本比对。
/// 数据源为公开仓库 lxfebd/clean_manhua_flutter 的 Releases API，无需鉴权。
class UpdateChecker {
  /// 仓库全名（owner/repo），写死为当前开源仓库。
  static const String repo = 'lxfebd/clean_manhua_flutter';

  /// 本机版本号缓存（启动时从 PackageInfo 异步获取）。
  static String _cached = '';

  /// init 幂等守卫：版本号取过一次就不再重复读 PackageInfo。
  static bool _inited = false;

  /// 启动时调用：从系统 PackageInfo 读取真实版本号缓存起来。
  static Future<void> init() async {
    if (_inited) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _cached = info.version;
      _inited = true;
    } catch (e) {
      ErrorLogger.instance.warn('UpdateChecker 读取本机版本号失败，可能影响更新判断: $e');
    }
  }

  /// 本机版本号。优先取启动时缓存的 PackageInfo 真实版本，
  /// 其次取构建时注入的 APP_VERSION（CI 通过 --dart-define 注入），
  /// 兜底用 1.0.0。
  static String currentVersion() {
    if (_cached.isNotEmpty) return _cached;
    const injected = String.fromEnvironment('APP_VERSION');
    if (injected.isNotEmpty) return injected;
    return '1.0.0';
  }

  /// 拉取最新 release 信息。若已是最新返回 null；网络/解析失败抛异常。
  static Future<UpdateInfo?> checkLatest({Duration? timeout}) async {
    if (kIsWeb) return null; // Web 端无自更新
    Map<String, dynamic> json;
    try {
      final body = await Net.get(
        'https://api.github.com/repos/$repo/releases/latest',
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'xingmanxia-android',
        },
        timeout: timeout ?? const Duration(seconds: 12),
      );
      json = jsonDecode(body) as Map<String, dynamic>;
    } on HttpStatusException catch (e) {
      // GitHub API 未鉴权限流（60 次/小时/IP，共享出口 IP 极易触顶）。
      // 403/429 时降级抓 releases 网页（不占 API 配额），保证检查更新仍可用。
      if (e.statusCode == 403 || e.statusCode == 429) {
        ErrorLogger.instance.warn('更新检查 API 限流(HTTP ${e.statusCode})，降级网页抓取');
        return _checkLatestFromHtml(timeout: timeout);
      }
      rethrow;
    }
    final tag = json['tag_name'] as String? ?? '';
    final version = tag.startsWith('v') ? tag.substring(1) : tag;

    // 按当前平台挑选附件：Windows→exe 安装包（无 exe 退让 zip）、macOS→dmg、Android→apk。
    final assets = json['assets'] as List<dynamic>? ?? const [];
    final picked = pickAssetForPlatform(
      assets,
      platformKey: currentPlatformKey(),
      // Windows 上「检查更新」要能静默覆盖安装，因此优先 .exe 安装包；
      // macOS 是 dmg（手动挂载）、Android 走 apk 分支，都不设优先后缀。
      prefer: Platform.isWindows ? '.exe' : null,
    );
    final apkUrl =
        picked?.url ??
        // 无附件时回退到 release body 里的直链
        _extractApkUrl(json['body'] as String?);

    if (apkUrl == null) {
      throw const FormatException('release 未找到可下载附件');
    }

    final info = UpdateInfo(
      version: version,
      notes: json['body'] as String?,
      apkUrl: apkUrl,
      tagName: tag,
      assetName: picked?.name,
    );

    final cmp = compareVersions(version, currentVersion());
    return cmp > 0 ? info : null;
  }

  /// API 被限流（403/429）时的降级：直接抓取 GitHub releases 网页（不占 API 配额），
  /// 从 HTML 里的附件下载链接解析版本，再复用 [pickAssetForPlatform] 按平台挑选。
  /// 解析不到可用附件/版本时抛异常，由上层按「检查更新失败」统一处理。
  static Future<UpdateInfo?> _checkLatestFromHtml({Duration? timeout}) async {
    final html = await Net.get(
      'https://github.com/$repo/releases/latest',
      timeout: timeout ?? const Duration(seconds: 12),
    );
    final assets = parseReleasePageAssets(html);
    if (assets.isEmpty) {
      throw const FormatException('release 页面未找到可下载附件');
    }
    final picked = pickAssetForPlatform(
      assets,
      platformKey: currentPlatformKey(),
      prefer: Platform.isWindows ? '.exe' : null,
    );
    if (picked == null) {
      throw const FormatException('release 未找到可下载附件');
    }
    // 版本：取所选附件链接里的 tag（去 v 前缀）
    const marker = '/releases/download/';
    final idx = picked.url.indexOf(marker);
    if (idx < 0) {
      throw const FormatException('release 链接异常，无法解析版本');
    }
    final rest = picked.url.substring(idx + marker.length);
    final slash = rest.indexOf('/');
    final tag = slash < 0 ? rest : rest.substring(0, slash);
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    final cmp = compareVersions(version, currentVersion());
    return cmp > 0
        ? UpdateInfo(
          version: version,
          apkUrl: picked.url,
          assetName: picked.name,
        )
        : null;
  }

  /// 从 GitHub releases 网页 HTML 中提取附件列表（name + browser_download_url），
  /// 形状与 GitHub API 的 assets 一致，可复用 [pickAssetForPlatform]。
  /// 附件下载链接形如 /owner/repo/releases/download/`<tag>`/`<name>`。
  @visibleForTesting
  static List<Map<String, dynamic>> parseReleasePageAssets(String html) {
    final assets = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final m in RegExp(r'releases/download/([^\s"?&]+)').allMatches(html)) {
      final path = m.group(1)!;
      final slash = path.indexOf('/');
      if (slash <= 0) continue;
      final rawName = path.substring(slash + 1);
      final name = Uri.decodeComponent(rawName);
      if (!name.contains('.')) continue;
      // 完整路径（tag + 文件名）拼 URL：GitHub 下载链接必须带 tag 段
      final url = 'https://github.com/$repo/releases/download/$path';
      if (seen.add(url)) {
        assets.add({'name': name, 'browser_download_url': url});
      }
    }
    return assets;
  }

  /// 当前平台的附件识别关键字：Windows→'-windows'、macOS→'-macos'、其余（Android）→''。
  /// Web 无自更新，返回空串（调用方已按 kIsWeb 短路）。
  static String currentPlatformKey() {
    if (kIsWeb) return '';
    if (Platform.isWindows) return '-windows';
    if (Platform.isMacOS) return '-macos';
    return '';
  }

  /// 当前平台是否支持一键自动安装。
  /// Windows 走 NSIS 静默安装器（exe 附件），Android 拉起系统安装器；
  /// macOS 仍是 dmg 手动挂载，Web 无自更新，都不算自动。
  static bool get canAutoInstall =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid);

  /// 关闭应用（仅 Windows）。自动更新的前提：必须先退出自身，否则正在运行的
  /// exe 处于文件锁状态，安装器覆盖会失败。
  /// 用 window_manager.destroy() 走 WM_CLOSE → PostQuitMessage 正常退出链，
  /// 触发 Flutter 引擎完整清理，比直接 ExitProcess 干净。
  /// window_manager 是全平台依赖且已在 main.dart/desktop_fullscreen.dart 直接
  /// import，Web 构建不受影响；本方法只在 Windows 分支被调用。
  static Future<void> quit() async {
    if (Platform.isWindows) {
      await windowManager.destroy();
    }
  }

  /// 从 release 附件中按平台挑选下载项，找不到可下载附件返回 null。
  /// [platformKey] 非空时按平台关键字匹配文件名（如 -windows），
  /// 为空（Android）时取第一个 apk 附件。
  ///
  /// 同平台有多个候选时按 [prefer] 后缀优先 —— Windows 上同时挂了
  /// `...-windows-1.5.0-setup.exe`（安装包）和 `...-windows-1.5.0.zip`（免安装），
  /// 优先 exe，因为 app 内可以静默覆盖安装；只有旧 release 没打 exe 时才退让给 zip。
  static UpdateAsset? pickAssetForPlatform(
    List<dynamic> assets, {
    required String platformKey,
    String? prefer,
  }) {
    // Android：第一个 apk 附件
    if (platformKey.isEmpty) {
      for (final a in assets) {
        final m = a as Map<String, dynamic>;
        final name = m['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          final url = m['browser_download_url'] as String? ?? '';
          if (url.isNotEmpty) return UpdateAsset(name, url);
        }
      }
      return null;
    }

    UpdateAsset? fallback;
    for (final a in assets) {
      final m = a as Map<String, dynamic>;
      final name = m['name'] as String? ?? '';
      if (!name.contains(platformKey)) continue;
      final url = m['browser_download_url'] as String? ?? '';
      if (url.isEmpty) continue;
      final asset = UpdateAsset(name, url);
      if (prefer != null && name.endsWith(prefer)) return asset;
      fallback ??= asset;
    }
    return fallback;
  }

  /// 从 release body 文本中提取形如 https://xxx.apk 的直链。
  static String? _extractApkUrl(String? body) {
    if (body == null) return null;
    final m = RegExp(r'https?://[^\s\)\]]+\.apk').firstMatch(body);
    return m?.group(0);
  }

  /// 比较版本号（支持 1.2.3 与 1.2.3+4）。返回 >0 表示 a 更新。
  static int compareVersions(String a, String b) {
    final pa = a.split('.').first;
    final pb = b.split('.').first;
    final sa = a.split('.').length >= 2 ? a.split('.')[1] : '0';
    final sb = b.split('.').length >= 2 ? b.split('.')[1] : '0';
    final ta =
        a.split('.').length >= 3 ? a.split('.')[2].split('+').first : '0';
    final tb =
        b.split('.').length >= 3 ? b.split('.')[2].split('+').first : '0';
    final va = int.tryParse(pa) ?? 0;
    final vb = int.tryParse(pb) ?? 0;
    if (va != vb) return va - vb;
    final ma = int.tryParse(sa) ?? 0;
    final mb = int.tryParse(sb) ?? 0;
    if (ma != mb) return ma - mb;
    final ta2 = int.tryParse(ta) ?? 0;
    final tb2 = int.tryParse(tb) ?? 0;
    return ta2 - tb2;
  }

  /// 触发系统安装器安装 APK。
  static Future<void> installApk(String path) async {
    await const MethodChannel(
      'xingmanxia/install',
    ).invokeMethod('installApk', {'path': path});
  }
}
