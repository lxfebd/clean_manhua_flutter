import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:xingmanxia/net/backup_cipher.dart';

void main() {
  group('BackupCipher', () {
    test('加密后能正确解密还原原文', () {
      const plain = '{"bookshelf":{"items":[1,2,3]},"version":2}';
      final enc = BackupCipher.encrypt(plain, 's3cret口令');
      expect(enc, startsWith('${BackupCipher.magicV2}\n'));
      final dec = BackupCipher.decrypt(enc, 's3cret口令');
      expect(dec, plain);
    });

    test('同一明文两次加密的密文不同（随机 IV）', () {
      const plain = '{"a":1}';
      final enc1 = BackupCipher.encrypt(plain, 'pwd');
      final enc2 = BackupCipher.encrypt(plain, 'pwd');
      expect(enc1, isNot(equals(enc2)));
    });

    test('错误口令解密抛异常', () {
      final enc = BackupCipher.encrypt('{"a":1}', 'right-pwd');
      expect(() => BackupCipher.decrypt(enc, 'wrong-pwd'), throwsA(anything));
    });

    test('非加密内容/篡改内容解密抛异常', () {
      expect(
        () => BackupCipher.decrypt('{"a":1}', 'pwd'),
        throwsA(anything),
      );
      final enc = BackupCipher.encrypt('{"a":1}', 'pwd');
      final parts = enc.split('\n');
      parts[2] = parts[2].substring(1); // 篡改密文
      expect(() => BackupCipher.decrypt(parts.join('\n'), 'pwd'),
          throwsA(anything));
    });

    test('deriveKey 输出 32 字节且不同口令不同', () {
      final k1 = BackupCipher.deriveKey('a');
      final k2 = BackupCipher.deriveKey('b');
      expect(k1.length, 32);
      expect(k2.length, 32);
      expect(k1, isNot(equals(k2)));
    });

    test('历史 v1 备份（xm-backup-enc-v1，SHA-256 派生）仍可解密', () {
      // 手工构造 v1 密文：SHA-256 派生密钥 + AES-256-GCM
      final pt = utf8.encode('{"legacy":true}');
      final key = BackupCipher.deriveKey('legacy-pass');
      final iv = Uint8List.fromList(
          List<int>.generate(12, (_) => Random(42).nextInt(256)));
      final gcm = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
      final out = Uint8List(gcm.getOutputSize(pt.length));
      var off = gcm.processBytes(pt, 0, pt.length, out, 0);
      off += gcm.doFinal(out, off);
      final v1Body = '${BackupCipher.magic}\n${base64Encode(iv)}\n'
          '${base64Encode(Uint8List.sublistView(out, 0, off))}';
      expect(BackupCipher.decrypt(v1Body, 'legacy-pass'), '{"legacy":true}');
    });
  });
}
