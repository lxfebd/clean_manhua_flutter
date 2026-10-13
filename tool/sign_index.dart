// 市场索引签名工具（ECDSA P-256，签名格式见 lib/utils/index_signature.dart）。
//
// 用法：
//   dart run tool/sign_index.dart --genkey [--key <path>]
//       首次：生成密钥对。私钥写入 --key（默认 ~/.xingmanxia/index_signing_key.json，
//       0600 语义由所在目录保护；**绝不进 git**），并打印公钥 hex 到 stdout，
//       把它填进 lib/utils/index_signature.dart 的 kIndexPublicKeysHex。
//   dart run tool/sign_index.dart <index.json>
//       给索引补/刷新 _sig 字段（就地改写，缩进 2 空格，键序保持不变）。
//
// 规范化规则必须与 lib/utils/index_signature.dart 的 canonicalIndexBytes 一致：
// 签名对象 = 顶层 JSON 去掉 _sig 后 jsonEncode 的字节。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const _sigField = '_sig';

String get _defaultKeyPath {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  return '$home/.xingmanxia/index_signing_key.json';
}

String _hexOf(BigInt v) => v.toRadixString(16).padLeft(64, '0');

void genKey(String keyPath) {
  final file = File(keyPath);
  if (file.existsSync()) {
    stderr.writeln('密钥已存在，不覆盖：$keyPath');
    stderr.writeln('轮换请先移走旧文件再 --genkey，并把新公钥追加进 kIndexPublicKeysHex。');
    exit(2);
  }
  file.parent.createSync(recursive: true);

  final domain = ECDomainParameters('prime256v1');
  final seed = Uint8List(32);
  final rng = Random.secure();
  for (var i = 0; i < 32; i++) {
    seed[i] = rng.nextInt(256);
  }
  final random = FortunaRandom()..seed(KeyParameter(seed));
  final keyGen = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), random));
  final pair = keyGen.generateKeyPair();
  final priv = pair.privateKey;
  final pub = pair.publicKey;

  final keyJson = jsonEncode({
    'curve': 'prime256v1',
    'd': _hexOf(priv.d!),
    'qx': _hexOf(pub.Q!.x!.toBigInteger()!),
    'qy': _hexOf(pub.Q!.y!.toBigInteger()!),
  });
  file.writeAsStringSync(keyJson);
  stdout.writeln('私钥已写入（勿提交勿外传）：$keyPath');
  stdout.writeln('PUBX=${_hexOf(pub.Q!.x!.toBigInteger()!)}');
  stdout.writeln('PUBY=${_hexOf(pub.Q!.y!.toBigInteger()!)}');
  stdout.writeln('把这些填进 lib/utils/index_signature.dart 的 kIndexPublicKeysHex，格式 PUBX:PUBY');
}

void signIndex(String indexPath, String keyPath) {
  final keyFile = File(keyPath);
  if (!keyFile.existsSync()) {
    stderr.writeln('找不到私钥：$keyPath（先跑 --genkey）');
    exit(2);
  }
  final key = jsonDecode(keyFile.readAsStringSync()) as Map<String, dynamic>;

  final indexFile = File(indexPath);
  if (!indexFile.existsSync()) {
    stderr.writeln('找不到索引：$indexPath');
    exit(2);
  }
  final decoded = jsonDecode(indexFile.readAsStringSync());
  if (decoded is! Map) {
    stderr.writeln('索引顶层必须是 JSON 对象');
    exit(2);
  }

  // 规范化：去 _sig 后 jsonEncode（必须与 canonicalIndexBytes 一致）
  final canonical = jsonEncode(
      Map<String, dynamic>.from(decoded)..remove(_sigField));

  final domain = ECDomainParameters('prime256v1');
  final priv = ECPrivateKey(BigInt.parse(key['d'] as String, radix: 16), domain);
  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(true, PrivateKeyParameter(priv));
  final sig = signer.generateSignature(Uint8List.fromList(utf8.encode(canonical)))
      as ECSignature;

  final buf = BytesBuilder();
  void put32(BigInt v) {
    final h = _hexOf(v);
    for (var i = 0; i < 64; i += 2) {
      buf.addByte(int.parse(h.substring(i, i + 2), radix: 16));
    }
  }

  put32(sig.r);
  put32(sig.s);
  decoded[_sigField] = base64Encode(buf.takeBytes());

  indexFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(decoded)}\n');
  stdout.writeln('已签名：$indexPath  (_sig=${decoded[_sigField]})');
}

void main(List<String> args) {
  var keyPath = _defaultKeyPath;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--key' && i + 1 < args.length) {
      keyPath = args[++i];
    } else {
      rest.add(args[i]);
    }
  }
  if (rest.isNotEmpty && rest.first == '--genkey') {
    genKey(keyPath);
    return;
  }
  if (rest.length != 1) {
    stderr.writeln('用法：dart run tool/sign_index.dart <index.json> [--key <path>]');
    stderr.writeln('      dart run tool/sign_index.dart --genkey [--key <path>]');
    exit(64);
  }
  signIndex(rest.single, keyPath);
}
