// 更新清单签名工具（ECDSA P-256 / SHA-256，格式与 lib/utils/index_signature.dart
// 和 lib/net/update_manifest.dart 完全一致：签名对象 = 顶层 JSON 去掉 _sig 后 jsonEncode）。
//
// 复用 tool/sign_index.dart 的密钥文件格式与签名实现——全项目只有一份 ECDSA
// 签名代码，市场索引与更新清单只是「签名字段名不同」。
//
// 用法：
//   dart run tool/sign_update_manifest.dart --genkey [--key <path>]
//       生成密钥对（默认 ~/.xingmanxia/update_signing_key.json）。私钥**绝不进
//       git**；把打印出来的 PUBX:PUBY 填进 lib/net/update_manifest.dart 的
//       kUpdatePublicKeysHex（轮换时追加，不要删旧的）。
//
//   dart run tool/sign_update_manifest.dart \
//        --build --out release-manifest.json \
//        --version 1.5.8 --sequence 12 --min-app 1.5.0 \
//        --asset app-release.apk:android:21678901:<sha256-hex> \
//        --asset app-arm64-v8a-release.apk:android:21678901:<sha256-hex> \
//        --asset xingmanxia-windows-1.5.8-setup.exe:windows:42123456:<sha256-hex>
//       CI 发布时用：现算附件 size/sha256 后生成并签名清单（就地写 --out）。
//       资产规格 `name:platform:size:sha256`，可重复多次。
//
//   dart run tool/sign_update_manifest.dart <manifest.json> [--key <path>]
//       给已存在的清单补/刷新 _sig（就地改写）。
//
// 私钥来源优先级：--key 指定 > 环境变量 UPDATE_SIGNING_KEY（base64 的密钥 JSON，
// CI 用 GitHub Secret 注入，解到系统临时文件后删除）> 默认路径。
import 'dart:convert';
import 'dart:io';

import 'sign_index.dart';

String get _defaultKeyPath {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  return '$home/.xingmanxia/update_signing_key.json';
}

/// 解析 `name:platform:size:sha256`。格式不对返回 null。
Map<String, dynamic>? _parseAsset(String spec) {
  final parts = spec.split(':');
  if (parts.length != 4) return null;
  final size = int.tryParse(parts[2]);
  if (size == null || size < 0) return null;
  final sha = parts[3].toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
  return {
    'name': parts[0],
    'platform': parts[1],
    'size': size,
    'sha256': sha,
  };
}

/// 生成未签名的清单 JSON 文本（键序固定，签名端与验签端一致）。
String buildManifestJson({
  required String version,
  required int sequence,
  String? minApp,
  String? issuedAt,
  required List<Map<String, dynamic>> assets,
}) {
  final m = <String, dynamic>{
    'version': version,
    'sequence': sequence,
  };
  if (minApp != null && minApp.isNotEmpty) m['minApp'] = minApp;
  m['issuedAt'] =
      issuedAt ?? DateTime.now().toUtc().toIso8601String();
  m['assets'] = assets;
  return '${const JsonEncoder.withIndent('  ').convert(m)}\n';
}

/// 私钥路径：--key > 环境变量 UPDATE_SIGNING_KEY(base64) > 默认路径。
/// 环境变量分支会把密钥解到系统临时目录，用完由调用方（main）删除。
String resolveKeyPath(String? keyArg) {
  if (keyArg != null && keyArg.isNotEmpty) return keyArg;
  final env = Platform.environment['UPDATE_SIGNING_KEY'];
  if (env != null && env.isNotEmpty) {
    final tmp = '${Directory.systemTemp.path}/xingmanxia_update_key.json';
    File(tmp).writeAsBytesSync(base64Decode(env));
    return tmp;
  }
  return _defaultKeyPath;
}

void main(List<String> args) {
  String? keyArg;
  var genkey = false;
  var build = false;
  String? out;
  String? version;
  int? sequence;
  String? minApp;
  String? issuedAt;
  final assets = <Map<String, dynamic>>[];
  final positional = <String>[];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '--key':
        if (i + 1 >= args.length) _die('--key 缺参数');
        keyArg = args[++i];
      case '--genkey':
        genkey = true;
      case '--build':
        build = true;
      case '--out':
        if (i + 1 >= args.length) _die('--out 缺参数');
        out = args[++i];
      case '--version':
        if (i + 1 >= args.length) _die('--version 缺参数');
        version = args[++i];
      case '--sequence':
        if (i + 1 >= args.length) _die('--sequence 缺参数');
        sequence = int.tryParse(args[++i]);
        if (sequence == null || sequence < 0) _die('--sequence 必须是非负整数');
      case '--min-app':
        if (i + 1 >= args.length) _die('--min-app 缺参数');
        minApp = args[++i];
      case '--issued-at':
        if (i + 1 >= args.length) _die('--issued-at 缺参数');
        issuedAt = args[++i];
      case '--asset':
        if (i + 1 >= args.length) _die('--asset 缺参数');
        final spec = args[++i];
        final parsed = _parseAsset(spec);
        if (parsed == null) {
          _die('--asset 规格应为 name:platform:size:sha256（64 位小写 hex），实际：$spec');
        }
        assets.add(parsed);
      default:
        positional.add(a);
    }
  }

  if (genkey) {
    // 复用市场索引的密钥生成器（同曲线、同文件格式）。
    genKey(keyArg ?? _defaultKeyPath);
    stdout.writeln('把 PUBX:PUBY 填进 lib/net/update_manifest.dart 的 kUpdatePublicKeysHex');
    return;
  }

  final keyPath = resolveKeyPath(keyArg);

  if (build) {
    if (out == null) _die('--build 需要 --out <manifest.json>');
    if (version == null || version.isEmpty) _die('--build 需要 --version');
    if (sequence == null) _die('--build 需要 --sequence');
    if (assets.isEmpty) _die('--build 至少需要一个 --asset');
    final text = buildManifestJson(
      version: version,
      sequence: sequence,
      minApp: minApp,
      issuedAt: issuedAt,
      assets: assets,
    );
    File(out).writeAsStringSync(text);
    signIndex(out, keyPath);
    _cleanupTempKey(keyPath, keyArg);
    return;
  }

  if (positional.length != 1) {
    stderr.writeln('用法：');
    stderr.writeln('  dart run tool/sign_update_manifest.dart --genkey [--key <path>]');
    stderr.writeln('  dart run tool/sign_update_manifest.dart --build --out <manifest.json> '
        '--version V --sequence N [--min-app X] --asset name:platform:size:sha256 ...');
    stderr.writeln('  dart run tool/sign_update_manifest.dart <manifest.json> [--key <path>]');
    exit(64);
  }
  signIndex(positional.single, keyPath);
  _cleanupTempKey(keyPath, keyArg);
}

void _cleanupTempKey(String used, String? keyArg) {
  if (keyArg != null && keyArg.isNotEmpty) return;
  if (used == _defaultKeyPath) return;
  try {
    final f = File(used);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

Never _die(String msg) {
  stderr.writeln(msg);
  exit(2);
}
