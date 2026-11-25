import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:xingmanxia/net/update_checker.dart';
import 'package:xingmanxia/net/update_manifest.dart';
import 'package:xingmanxia/utils/index_signature.dart';

/// 更新清单（签名 + 防回滚 + minApp）回归测试。
///
/// 全部用**临时生成的密钥对**注入 publicKeys，绝不依赖发布机私钥——
/// 与 test/regression_market_index_signature_test.dart 同一套做法。
class _Key {
  _Key(this.entry, this._priv);
  final String entry; // "PUBX:PUBY"
  final ECPrivateKey _priv;

  /// 对「顶层去 _sig 后 jsonEncode」的字节签名，返回 base64(r‖s)。
  /// 规范化规则必须与 lib/net/update_manifest.dart / verifyJsonSignature 一致。
  String sign(String text) {
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final canonical = jsonEncode(
        Map<String, dynamic>.from(decoded)..remove(kUpdateManifestSignatureField));
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter(_priv));
    final sig = signer
            .generateSignature(Uint8List.fromList(utf8.encode(canonical)))
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

final _shaA = 'a' * 64; // 测试用 64 位 hex
final _shaB = 'b' * 64;

void main() {
  final key = _makeKey();
  final keys = [key.entry];

  String manifest({
    String version = '1.5.8',
    int sequence = 12,
    String? minApp = '1.5.0',
    String? issuedAt = '2026-11-21T00:00:00Z',
    List<Map<String, dynamic>>? assets,
    bool withSig = true,
    String? overrideSha,
    int? overrideSize,
  }) {
    final m = <String, dynamic>{
      'version': version,
      'sequence': sequence,
      if (minApp != null) 'minApp': minApp,
      if (issuedAt != null) 'issuedAt': issuedAt,
      'assets': assets ??
          [
            {
              'name': 'app-release.apk',
              'platform': 'android',
              'size': overrideSize ?? 21678901,
              'sha256': overrideSha ?? _shaA,
            },
            {
              'name': 'xingmanxia-windows-1.5.8-setup.exe',
              'platform': 'windows',
              'size': 42123456,
              'sha256': _shaB,
            },
          ],
    };
    final text = jsonEncode(m);
    if (!withSig) return text;
    m[kUpdateManifestSignatureField] = key.sign(text);
    return jsonEncode(m);
  }

  group('verifyJsonSignature / classify', () {
    test('合法签名 → valid，且 tryParse 给出完整字段', () {
      final text = manifest();
      expect(UpdateManifest.classify(text, publicKeys: keys),
          UpdateManifestStatus.valid);
      final m = UpdateManifest.tryParse(text, publicKeys: keys);
      expect(m, isNotNull);
      expect(m!.version, '1.5.8');
      expect(m.sequence, 12);
      expect(m.minApp, '1.5.0');
      expect(m.issuedAt, '2026-11-21T00:00:00Z');
      expect(m.assets.length, 2);
      expect(m.expectedSha256('app-release.apk'), _shaA);
      expect(m.expectedSize('app-release.apk'), 21678901);
    });

    test('tryParse 只在 valid 时返回对象（missing / invalid / unparsable → null）', () {
      expect(UpdateManifest.tryParse(manifest(withSig: false), publicKeys: keys),
          isNull);
      expect(
          UpdateManifest.tryParse('{"version":"1.0.0","assets":[]}',
              publicKeys: keys),
          isNull);
      expect(UpdateManifest.tryParse('not json', publicKeys: keys), isNull);
      expect(UpdateManifest.tryParse('[1,2,3]', publicKeys: keys), isNull);
    });

    test('无 _sig → missing（历史 release 未签清单）', () {
      expect(UpdateManifest.classify(manifest(withSig: false), publicKeys: keys),
          UpdateManifestStatus.missing);
    });

    test('签名后篡改 version / sha256 / size / sequence → invalid', () {
      // 必须先签名、后篡改：helper 的 override* 参数走的是「改完再签」，
      // 那是合法签名的新清单，不是篡改场景。
      final base = jsonDecode(manifest()) as Map<String, dynamic>;
      final variants = <String, Map<String, dynamic>>{
        'version': {'version': '9.9.9'},
        'sha256': {
          'assets': [
            {
              'name': 'app-release.apk',
              'platform': 'android',
              'size': 21678901,
              'sha256': 'c' * 64,
            },
            {
              'name': 'xingmanxia-windows-1.5.8-setup.exe',
              'platform': 'windows',
              'size': 42123456,
              'sha256': _shaB,
            },
          ],
        },
        'size': {
          'assets': [
            {
              'name': 'app-release.apk',
              'platform': 'android',
              'size': 1,
              'sha256': _shaA,
            },
            {
              'name': 'xingmanxia-windows-1.5.8-setup.exe',
              'platform': 'windows',
              'size': 42123456,
              'sha256': _shaB,
            },
          ],
        },
        'sequence': {'sequence': 99},
      };
      variants.forEach((what, patch) {
        final text = jsonEncode(Map<String, dynamic>.from(base)..addAll(patch));
        expect(UpdateManifest.classify(text, publicKeys: keys),
            UpdateManifestStatus.invalid,
            reason: '签名后篡改 $what 必须验不过');
        expect(UpdateManifest.tryParse(text, publicKeys: keys), isNull);
      });
    });

    test('补一个伪造 _sig（用另一把钥匙签）→ invalid', () {
      final other = _makeKey();
      final text = manifest(withSig: false);
      final m = Map<String, dynamic>.from(jsonDecode(text) as Map);
      m[kUpdateManifestSignatureField] = other.sign(text);
      expect(UpdateManifest.classify(jsonEncode(m), publicKeys: keys),
          UpdateManifestStatus.invalid);
    });

    test('顶层键序参与签名：重排键 → invalid', () {
      final text = manifest();
      final m = Map<String, dynamic>.from(jsonDecode(text) as Map);
      final reordered = <String, dynamic>{};
      for (final k in m.keys.toList().reversed) {
        reordered[k] = m[k];
      }
      expect(UpdateManifest.classify(jsonEncode(reordered), publicKeys: keys),
          UpdateManifestStatus.invalid);
    });

    test('签名过了但字段缺失 → invalid', () {
      for (final bad in [
        <String, dynamic>{'sequence': 1, 'assets': []},
        <String, dynamic>{'version': '1.0.0', 'assets': []},
        <String, dynamic>{
          'version': '1.0.0',
          'assets': [{'name': 'a.apk', 'platform': 'android'}],
        },
        <String, dynamic>{
          'version': '1.0.0',
          'assets': [
            {'name': 'a.apk', 'platform': 'android', 'size': -1, 'sha256': _shaA}
          ],
        },
      ]) {
        final text = jsonEncode(bad);
        bad[kUpdateManifestSignatureField] = key.sign(text);
        expect(UpdateManifest.classify(jsonEncode(bad), publicKeys: keys),
            UpdateManifestStatus.invalid);
      }
    });

    test('非对象 / 空文本 → unparsable', () {
      for (final t in ['[]', '"str"', '', '{']) {
        expect(UpdateManifest.classify(t, publicKeys: keys),
            UpdateManifestStatus.unparsable,
            reason: t);
      }
    });

    test('sha256 大小写归一化为小写', () {
      final text = manifest(overrideSha: _shaA.toUpperCase());
      final m = UpdateManifest.tryParse(text, publicKeys: keys);
      expect(m!.expectedSha256('app-release.apk'), _shaA);
    });

    test('asset() 未命中返回 null，期望值查询不抛', () {
      final m = UpdateManifest.tryParse(manifest(), publicKeys: keys)!;
      expect(m.asset('nope.apk'), isNull);
      expect(m.expectedSha256('nope.apk'), isNull);
      expect(m.expectedSize('nope.apk'), isNull);
    });

    test('不传公钥（默认生产公钥）验测试签名 → invalid（不会误放行）', () {
      expect(UpdateManifest.classify(manifest()), UpdateManifestStatus.invalid);
    });
  });

  group('生产公钥常量回归', () {
    test('kUpdatePublicKeysHex 每条都是 64hex:64hex 且非空', () {
      expect(kUpdatePublicKeysHex, isNotEmpty);
      for (final e in kUpdatePublicKeysHex) {
        final p = e.split(':');
        expect(p.length, 2, reason: e);
        for (final half in p) {
          expect(RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(half), isTrue,
              reason: half);
        }
      }
    });

    test('清单资产名常量与发布附件约定一致', () {
      expect(kUpdateManifestAssetName, 'release-manifest.json');
      expect(kUpdateManifestSignatureField, kIndexSignatureField);
    });

    test('内置公钥能验签 tool/sign_update_manifest.dart 的真实产物', () {
      // 真实流程证据：fixtures/release-manifest.sample.json 是
      // dart run tool/sign_update_manifest.dart --build 用**发布私钥**签出的
      // 快照。它锁死「签名脚本 ↔ 内置公钥 ↔ 验签函数」三方格式互认——脚本或
      // 规范化格式被改动时这条立刻红，不用等线上更新翻车。历史快照不随版本
      // 轮换而失效。
      final file = File('test/fixtures/release-manifest.sample.json');
      expect(file.existsSync(), isTrue,
          reason: 'fixture 丢失会让本测试静默失效，必须随仓库存在');
      final text = file.readAsStringSync();
      expect(UpdateManifest.classify(text), UpdateManifestStatus.valid,
          reason: '真实签名脚本的产物必须被内置公钥验证通过');
      final m = UpdateManifest.tryParse(text);
      expect(m, isNotNull);
      expect(m!.assets.length, greaterThanOrEqualTo(1));
      expect(m.sequence, greaterThan(0));
      for (final a in m.assets) {
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(a.sha256), isTrue,
            reason: '清单里的 sha256 必须是 64 位小写 hex：${a.name}');
        expect(a.size, greaterThan(0));
      }
    });

  });

  group('manifestSequenceAcceptable（防回滚，双键判定）', () {
    // 回归：最初实现只用「序号严格大于已记录」，于是用户第二次点
    // 「检查更新」时同一份清单会被判为回滚而拒绝——更新列表直接消失。
    test('同一序号同一版本的重复检查必须接受', () {
      expect(
        UpdateChecker.manifestSequenceAcceptable(12, '1.5.8',
            lastSeq: 12, lastVer: '1.5.8'),
        isTrue,
        reason: '用户会反复检查更新，不能第二次就拒');
    });

    test('首次（无记录）接受', () {
      expect(
          UpdateChecker.manifestSequenceAcceptable(12, '1.5.8',
              lastSeq: 0, lastVer: ''),
          isTrue);
    });

    test('序号递增接受', () {
      expect(
          UpdateChecker.manifestSequenceAcceptable(13, '1.5.9',
              lastSeq: 12, lastVer: '1.5.8'),
          isTrue);
    });

    test('序号回滚拒绝', () {
      expect(
          UpdateChecker.manifestSequenceAcceptable(11, '1.5.7',
              lastSeq: 12, lastVer: '1.5.8'),
          isFalse,
          reason: '旧版清单替换新版 = 回滚攻击');
    });

    test('同序号复用给别的版本拒绝', () {
      expect(
          UpdateChecker.manifestSequenceAcceptable(12, '9.9.9',
              lastSeq: 12, lastVer: '1.5.8'),
          isFalse,
          reason: '同一序号签两份不同内容 = 可疑');
    });
  });

}
