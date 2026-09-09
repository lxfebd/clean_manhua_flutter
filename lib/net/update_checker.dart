import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
    } catch (_) {}
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
    final body = await Net.get(
      'https://api.github.com/repos/$repo/releases/latest',
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'xingmanxia-android',
      },
      timeout: timeout ?? const Duration(seconds: 12),
    );
    final json = jsonDecode(body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final version = tag.startsWith('v') ? tag.substring(1) : tag;

    // 按当前平台挑选附件：Windows→zip、macOS→dmg、Android→apk。
    final assets = json['assets'] as List<dynamic>? ?? const [];
    final picked =
        pickAssetForPlatform(assets, platformKey: currentPlatformKey());
    final apkUrl = picked?.url ??
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

  /// 当前平台的附件识别关键字：Windows→'-windows'、macOS→'-macos'、其余（Android）→''。
  static String currentPlatformKey() {
    if (Platform.isWindows) return '-windows';
    if (Platform.isMacOS) return '-macos';
    return '';
  }

  /// 从 release 附件中按平台挑选下载项，找不到可下载附件返回 null。
  /// [platformKey] 非空时按平台关键字匹配文件名（如 -windows），
  /// 为空（Android）时取第一个 apk 附件。
  static UpdateAsset? pickAssetForPlatform(
      List<dynamic> assets, {required String platformKey}) {
    if (platformKey.isNotEmpty) {
      for (final a in assets) {
        final m = a as Map<String, dynamic>;
        final name = m['name'] as String? ?? '';
        if (name.contains(platformKey)) {
          final url = m['browser_download_url'] as String? ?? '';
          if (url.isNotEmpty) return UpdateAsset(name, url);
        }
      }
      return null;
    }
    // Android：第一个 apk 附件
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
    final ta = a.split('.').length >= 3 ? a.split('.')[2].split('+').first : '0';
    final tb = b.split('.').length >= 3 ? b.split('.')[2].split('+').first : '0';
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

  /// 下载更新包到临时目录，返回文件路径。
  /// [onProgress] 进度回调（已下载字节, 总字节）；[isCancelled] 返回 true 时中止下载。
  /// 文件名按平台区分（Android→*.apk，Windows/macOS→平台包）。
  static Future<String> downloadUpdate(
    String url, {
    String? assetName,
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final tmpDir = await Directory.systemTemp.createTemp('xingmanxia_update');
    var name = assetName?.isNotEmpty == true
        ? assetName!
        : (Platform.isAndroid
            ? 'xingmanxia.apk'
            : 'xingmanxia${currentPlatformKey()}-update.zip');
    // 文件名不允许带路径分隔符
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File('${tmpDir.path}/$name');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..badCertificateCallback = (c, h, p) => true;
    try {
      final req = await client.getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      req.headers.set('User-Agent', 'xingmanxia-android');
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final total = res.contentLength;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in res) {
        if (isCancelled?.call() == true) {
          await sink.close();
          await file.delete();
          throw Exception('下载已取消');
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress(received, total);
        }
      }
      await sink.close();
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  /// 触发系统安装器安装 APK。
  static Future<void> installApk(String path) async {
    await const MethodChannel('xingmanxia/install')
        .invokeMethod('installApk', {'path': path});
  }
}
