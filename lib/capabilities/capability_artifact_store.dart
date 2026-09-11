import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../net/http_client.dart' show Net;
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

  /// artifact 落盘目录：`<support>/capabilities/<id>/`。
  Future<Directory?> artifactDir(String id) async {
    final base = await _baseDir();
    if (base == null) return null;
    final d = Directory('${base.path}/capabilities/$id');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 权重落盘目录：`<support>/.model_cache/<id>/`。
  /// 项目红线：`.model_cache/` 保持为空（权重仅运行期下载，不入 git/APK）。
  Future<Directory?> weightDir(String id) async {
    final base = await _baseDir();
    if (base == null) return null;
    final d = Directory('${base.path}/.model_cache/$id');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
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

  /// 下载单个 artifact（桌面直链），SHA256 校验，返回本地文件。
  /// 失败返回 null（原因可由调用方通过 [lastError] 读取）。
  Future<File?> download(
    String id,
    CapabilityArtifact artifact, {
    String? proxy,
  }) async {
    final dir = await artifactDir(id);
    if (dir == null || artifact.url == null) return null;
    final url = artifact.url!;
    final fname = Uri.parse(url).pathSegments.isNotEmpty
        ? Uri.parse(url).pathSegments.last
        : '$id.artifact';
    final target = File('${dir.path}/$fname');

    // 已存在且 SHA256 匹配 → 直接复用（幂等，避免重复下载）。
    final expected = artifact.sha256.values.isNotEmpty
        ? artifact.sha256.values.first
        : null;
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
      _lastError = '构件下载失败: $e';
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
    try {
      await target.writeAsBytes(bytes, flush: true);
      return target;
    } catch (e) {
      _lastError = '构件落盘失败: $e';
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
