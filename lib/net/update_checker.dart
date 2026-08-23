import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'http_client.dart';

/// GitHub Releases 上的最新版本信息。
class UpdateInfo {
  final String version;
  final String? notes;
  final String apkUrl;
  final String? tagName;

  const UpdateInfo({
    required this.version,
    this.notes,
    required this.apkUrl,
    this.tagName,
  });
}

/// 版本更新检查：从 GitHub Releases 拉取最新版，与本机版本比对。
/// 数据源为公开仓库 lxfebd/clean_manhua_flutter 的 Releases API，无需鉴权。
class UpdateChecker {
  /// 仓库全名（owner/repo），写死为当前开源仓库。
  static const String repo = 'lxfebd/clean_manhua_flutter';

  /// 本机版本号。优先取构建时注入的 APP_VERSION（CI 通过 --dart-define 注入），
  /// 兜底用 pubspec 版本常量。
  static String currentVersion() {
    const injected = String.fromEnvironment('APP_VERSION');
    if (injected.isNotEmpty) return injected;
    return '1.0.0';
  }

  /// 拉取最新 release 信息。若已是最新返回 null；网络/解析失败抛异常。
  static Future<UpdateInfo?> checkLatest({Duration? timeout}) async {
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

    String? apkUrl;
    final assets = json['assets'] as List<dynamic>? ?? const [];
    for (final a in assets) {
      final map = a as Map<String, dynamic>;
      final name = map['name'] as String? ?? '';
      if (name.endsWith('.apk')) {
        apkUrl = map['browser_download_url'] as String?;
        break;
      }
    }
    // 无附件时回退到 release body 里的直链
    apkUrl ??= _extractApkUrl(json['body'] as String?);

    if (apkUrl == null) {
      throw const FormatException('release 未找到 APK 附件');
    }

    final info = UpdateInfo(
      version: version,
      notes: json['body'] as String?,
      apkUrl: apkUrl,
      tagName: tag,
    );

    final cmp = compareVersions(version, currentVersion());
    return cmp > 0 ? info : null;
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

  /// 下载 APK 到临时目录，返回文件路径。
  /// [onProgress] 进度回调（已下载字节, 总字节）；[isCancelled] 返回 true 时中止下载。
  static Future<String> downloadApk(
    String url, {
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final tmpDir = await Directory.systemTemp.createTemp('xingmanxia_update');
    final file = File('${tmpDir.path}/xingmanxia.apk');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..badCertificateCallback = (c, h, p) => true;
    try {
      final req = await client.getUrl(Uri.parse(url));
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
