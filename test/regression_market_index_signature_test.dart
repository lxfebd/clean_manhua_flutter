import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:xingmanxia/utils/index_signature.dart';

/// 索引签名回归测试。
///
/// 算法背景（都是实测结论，别再踩）：
/// - pointycastle 4.0 **没有 Ed25519**（Ed25519Signer 类不存在，编译期即报
///   "'Ed25519Signer' isn't a type"），也没有公开的 BigInteger 类型（就是
///   Dart BigInt）；EC 密钥类叫 ECPublicKey/ECPrivateKey（4.0 去掉了
///   Parameters 后缀）。故 scheme 定为 ECDSA P-256。
/// - 测试全部用**临时生成的密钥对**注入 publicKeys，绝不依赖发布机私钥。
class _Key {
  _Key(this.entry, this._priv);
  final String entry; // "PUBX:PUBY"，注入 verifyIndexSignature 用
  final ECPrivateKey _priv;

  String sign(String indexText) {
    final canonical = utf8.decode(canonicalIndexBytes(jsonDecode(indexText)));
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter(_priv));
    final sig =
        signer.generateSignature(Uint8List.fromList(utf8.encode(canonical)))
            as ECSignature;
    final bytes = Uint8List(64);
    void put(BigInt v, int at) {
      final h = v.toRadixString(16).padLeft(64, '0');
      for (var i = 0; i < 32; i++) {
        bytes[at + i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
      }
    }

    put(sig.r, 0);
    put(sig.s, 32);
    return base64Encode(bytes);
  }
}

_Key _makeKey() {
  final domain = ECDomainParameters('prime256v1');
  final seed = Uint8List(32);
  final rnd = Random.secure();
  for (var i = 0; i < 32; i++) {
    seed[i] = rnd.nextInt(256);
  }
  final random = FortunaRandom()..seed(KeyParameter(seed));
  final pair = (ECKeyGenerator()
        ..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), random)))
      .generateKeyPair();
  String hex(BigInt v) => v.toRadixString(16).padLeft(64, '0');
  return _Key(
    '${hex(pair.publicKey.Q!.x!.toBigInteger()!)}:'
        '${hex(pair.publicKey.Q!.y!.toBigInteger()!)}',
    pair.privateKey,
  );
}

void main() {
  final key = _makeKey(); // 全文件共用一对临时密钥（EC 生成慢）
  const indexText = '{"name":"测试市场","sources":[{"id":"a"},{"id":"b"}]}';

  String signed(String text, _Key k) {
    final m = Map<String, dynamic>.from(jsonDecode(text) as Map);
    m[kIndexSignatureField] = k.sign(text);
    return jsonEncode(m);
  }

  group('verifyIndexSignature', () {
    test('合法签名通过', () {
      expect(verifyIndexSignature(signed(indexText, key), publicKeys: [key.entry]),
          IndexSignatureStatus.valid);
    });

    test('无 _sig 字段 → missing', () {
      expect(verifyIndexSignature(indexText, publicKeys: [key.entry]),
          IndexSignatureStatus.missing);
    });

    test('签名后篡改内容条目 → invalid', () {
      final s = signed(indexText, key);
      final tampered = s.replaceAll('"id":"b"', '"id":"evil"');
      expect(tampered, isNot(s)); // 确认替换真的发生了
      expect(verifyIndexSignature(tampered, publicKeys: [key.entry]),
          IndexSignatureStatus.invalid);
    });

    test('签名后在 sources 追加条目 → invalid（数组长度参与签名）', () {
      final s = signed(indexText, key);
      final tampered = s.replaceAll('{"id":"b"}', '{"id":"b"},{"id":"evil"}');
      expect(tampered, isNot(s));
      expect(verifyIndexSignature(tampered, publicKeys: [key.entry]),
          IndexSignatureStatus.invalid);
    });

    test('别的密钥的合法签名 → invalid（公钥不认第三方）', () {
      final other = _makeKey();
      expect(verifyIndexSignature(signed(indexText, other), publicKeys: [key.entry]),
          IndexSignatureStatus.invalid);
    });

    test('公钥列表含多把时任一命中即 valid（密钥轮换）', () {
      final old = _makeKey();
      final s = signed(indexText, key);
      expect(
          verifyIndexSignature(s, publicKeys: [old.entry, key.entry]),
          IndexSignatureStatus.valid);
    });

    test('_sig 形状错误不抛异常，归入 invalid', () {
      for (final bad in ['', 'not-base64!!', base64Encode(List.filled(63, 0))]) {
        final m = Map<String, dynamic>.from(jsonDecode(indexText) as Map);
        m[kIndexSignatureField] = bad;
        expect(verifyIndexSignature(jsonEncode(m), publicKeys: [key.entry]),
            IndexSignatureStatus.invalid);
      }
    });

    test('非 JSON / 顶层数组 → invalid 不抛', () {
      expect(verifyIndexSignature('not json', publicKeys: [key.entry]),
          IndexSignatureStatus.invalid);
      expect(verifyIndexSignature('[1,2,3]', publicKeys: [key.entry]),
          IndexSignatureStatus.invalid);
    });

    test('键序不变时排版差异（缩进/空白）不影响验签', () {
      final s = signed(indexText, key);
      final pretty =
          const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
      expect(verifyIndexSignature(pretty, publicKeys: [key.entry]),
          IndexSignatureStatus.valid);
    });
  });

  group('生产公钥常量', () {
    test('kIndexPublicKeysHex 形状正确且不含占位符', () {
      expect(kIndexPublicKeysHex, isNotEmpty);
      for (final e in kIndexPublicKeysHex) {
        expect(e, isNot(contains('<')), reason: '占位公钥没换成真实值');
        final parts = e.split(':');
        expect(parts, hasLength(2));
        for (final p in parts) {
          expect(p.trim(), matches(RegExp(r'^[0-9a-f]{64}$')));
        }
      }
    });

    test('内置公钥能验签 tool/sign_index.dart 产出的真实签名索引', () {
      // 真实流程证据：fixtures/market_signed_sample.json 是
      // dart run tool/sign_index.dart 用**真实私钥**对线上 index.json 签名的
      // 快照。它证明「签名脚本 ↔ 内置公钥 ↔ 验签函数」三方格式互认；脚本或
      // 规范化格式被改动时这条立刻红，不用等真机市场翻车。它是历史快照，
      // 索引轮换不影响其恒为 valid。
      final file = File('test/fixtures/market_signed_sample.json');
      expect(file.existsSync(), isTrue,
          reason: 'fixture 丢失会让本测试静默失效，必须随仓库存在');
      expect(verifyIndexSignature(file.readAsStringSync()),
          IndexSignatureStatus.valid,
          reason: '真实签名脚本的产物必须被内置公钥验证通过');
    });
  });
}
