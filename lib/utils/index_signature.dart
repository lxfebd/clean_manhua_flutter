import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// 市场索引的**来源校验**（ECDSA P-256 / SHA-256）。
///
/// ## 为什么需要
/// 索引内容决定装进 App 的源定义（请求 URL、选择器、请求头），而它经由第三方
/// 分发：gh-proxy 代理、jsDelivr CDN，乃至被入侵的仓库内容本身。索引此前
/// **没有任何完整性校验**，任何一环被替换，App 都会把伪造的源定义当合法内容
/// 安装——这是实打实的供应链风险。
///
/// ## 与镜像链排序的关系（正交，两者都需要）
/// - `kMarketIndexUrls` 的顺序解决「拿到的是不是**最新**内容」；
/// - 本文件解决「拿到的是不是**作者签发**的内容」。
/// 签名**不解决过期**：签名合法但内容陈旧的索引照样验签通过。
///
/// ## 算法
/// ECDSA P-256 而非 Ed25519：pointycastle 4.0 已移除 Ed25519（实测类不存在，
/// 见 test/regression_market_index_signature_test.dart 顶注），只有
/// ECDSA/RSA/PSS。为一个签名功能新增依赖包与「减少供应链依赖」的初衷相悖。
///
/// ## 规范化（签名端与验签端必须完全一致）
/// 签名对象 = 顶层 JSON 去掉 [_kSigField] 后 `jsonEncode` 的 UTF-8 字节。
/// 排版差异不影响验签，但**顶层键序参与签名**——签名脚本总是重写 `_sig`，
/// 手工编辑索引后必须重跑 `dart run tool/sign_index.dart index.json`。
/// 索引签名所在的顶层字段名。
const String kIndexSignatureField = '_sig';

/// 验签公钥（prime256v1 的 Q 点坐标，格式 "PUBX:PUBY"，各 32 字节 hex）。
///
/// 公开信息，可硬编码。私钥在发布机 `~/.xingmanxia/index_signing_key.json`，
/// 不进仓库。轮换：在 tool/ 跑 `--genkey`，把新公钥**追加**到这里（旧公钥
/// 保留，存量已签索引才能继续验过），下次发布自动改用新私钥签名。
const List<String> kIndexPublicKeysHex = [
  'd6f12ee4fa02b25bd57aede7dafb241cbacda96099736c817fc563bd1a490946:'
      '5dad4d7b7c7b1a5d1f10755792cd2945d72cb1825b28c7dc51d903ed36b1df0d', // 2026-10-13
];

/// 校验结果。
enum IndexSignatureStatus { valid, missing, invalid }

Uint8List _bytes32(String hex) {
  if (hex.length != 64 ||
      !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
    throw FormatException('坐标应为 64 位十六进制，实际 "${hex.length} 位"');
  }
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 参与签名的规范化字节（见库注释「规范化」）。
Uint8List canonicalIndexBytes(Object? decoded) {
  if (decoded is! Map) throw const FormatException('索引顶层必须是 JSON 对象');
  final copy = Map<String, dynamic>.from(decoded)
    ..remove(kIndexSignatureField);
  return Uint8List.fromList(utf8.encode(jsonEncode(copy)));
}

/// base64( r‖s ，各 32 字节大端）。形状不对返回 null。
ECSignature? _parseSig(String sigB64) {
  try {
    final bytes = base64Decode(sigB64);
    if (bytes.length != 64) return null;
    BigInt be(int from) {
      var v = BigInt.zero;
      for (var i = from; i < from + 32; i++) {
        v = (v << 8) | BigInt.from(bytes[i]);
      }
      return v;
    }

    return ECSignature(be(0), be(32));
  } on FormatException {
    return null;
  }
}

bool _verifyWith(String pubKeyEntry, Uint8List data, ECSignature sig) {
  final parts = pubKeyEntry.split(':');
  if (parts.length != 2) return false;
  try {
    final domain = ECDomainParameters('prime256v1');
    final q = domain.curve.decodePoint(Uint8List.fromList(
        <int>[0x04, ..._bytes32(parts[0].trim()), ..._bytes32(parts[1].trim())]));
    if (q == null) return false;
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(false, PublicKeyParameter(ECPublicKey(q, domain)));
    return signer.verifySignature(data, sig);
  } catch (_) {
    // 点解码失败/坐标越界等一律视为无效，不让异常冒进市场 UI。
    return false;
  }
}

/// 校验索引文本签名。纯函数；格式问题一律归入 invalid，不抛异常。
/// [publicKeys] 仅供测试注入自己的密钥，生产用默认值。
IndexSignatureStatus verifyIndexSignature(
  String indexText, {
  List<String> publicKeys = kIndexPublicKeysHex,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(indexText);
  } catch (_) {
    return IndexSignatureStatus.invalid;
  }
  if (decoded is! Map) return IndexSignatureStatus.invalid;

  final raw = decoded[kIndexSignatureField];
  if (raw == null) return IndexSignatureStatus.missing;
  if (raw is! String || raw.isEmpty) return IndexSignatureStatus.invalid;

  final sig = _parseSig(raw);
  if (sig == null) return IndexSignatureStatus.invalid;

  final Uint8List data;
  try {
    data = canonicalIndexBytes(decoded);
  } catch (_) {
    return IndexSignatureStatus.invalid;
  }

  for (final entry in publicKeys) {
    if (_verifyWith(entry, data, sig)) return IndexSignatureStatus.valid;
  }
  return IndexSignatureStatus.invalid;
}

/// 市场拉取索引后的统一策略：**缺失告警放行，篡改拒绝**。
///
/// - `missing` → 放行但告警。渐进上线的妥协：直接收紧为拒绝的话，任何一次
///   漏签名的发布都会让全网市场空白；观察一段时间后再改（见 TODO）。
/// - `invalid` → 拦。有签名却验不过是「有人在改」的强信号，调用方应视为
///   拉取失败并回退缓存。
///
/// TODO(签名收紧): 确认全部在架索引均已签名后，missing 也返回 false。
bool checkIndexOrTrust(String indexText, {required String what}) {
  switch (verifyIndexSignature(indexText)) {
    case IndexSignatureStatus.valid:
      return true;
    case IndexSignatureStatus.missing:
      debugPrint('[$what] 索引未签名：无法验证来源，暂按放行处理');
      return true;
    case IndexSignatureStatus.invalid:
      debugPrint('[$what] 索引签名校验失败：可能被篡改，按拉取失败处理');
      return false;
  }
}
