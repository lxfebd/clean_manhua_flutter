import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// 备份加密：导出备份支持用户口令 AES-256-GCM 加密（随机 IV + 派生密钥），
/// GCM 自带认证，篡改/错误口令会抛异常。复用 WebDAV 同步已验证的加密模式，
/// 密码丢失无法找回（无后门）。
class BackupCipher {
  BackupCipher._();

  static const String magic = 'xm-backup-enc-v1';

  /// 口令 → 32 字节密钥（SHA-256 派生）。
  static Uint8List deriveKey(String password) {
    final digest = SHA256Digest();
    final input = utf8.encode(password);
    final out = Uint8List(32);
    var off = 0;
    digest.update(input, 0, input.length);
    off += digest.doFinal(out, off);
    return out;
  }

  /// AES-256-GCM 加密：返回 `magic\nivB64\ncipherB64` 三段式文本。
  static String encrypt(String json, String password) {
    final key = deriveKey(password);
    final iv = Uint8List.fromList(
        List<int>.generate(12, (_) => Random.secure().nextInt(256)));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final pt = utf8.encode(json);
    final out = Uint8List(gcm.getOutputSize(pt.length));
    var off = gcm.processBytes(pt, 0, pt.length, out, 0);
    off += gcm.doFinal(out, off);
    return '$magic\n${base64Encode(iv)}\n${base64Encode(Uint8List.sublistView(out, 0, off))}';
  }

  /// 解密：输入 [encrypt] 的输出文本。口令错误/内容篡改抛异常。
  static String decrypt(String body, String password) {
    final lines = body.split('\n');
    if (lines.length < 3 || lines[0].trim() != magic) {
      throw ArgumentError('不是加密备份文件');
    }
    final iv = base64Decode(lines[1].trim());
    final ct = base64Decode(lines.sublist(2).join('\n').trim());
    final key = deriveKey(password);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final out = Uint8List(gcm.getOutputSize(ct.length));
    var off = gcm.processBytes(ct, 0, ct.length, out, 0);
    off += gcm.doFinal(out, off);
    return utf8.decode(Uint8List.sublistView(out, 0, off));
  }
}
