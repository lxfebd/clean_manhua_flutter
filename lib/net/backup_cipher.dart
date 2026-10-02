import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// 备份/同步加密：AES-256-GCM（随机 IV + 派生密钥），GCM 自带认证，
/// 篡改/错误口令会抛异常。v1 = 裸 SHA-256 派生（历史备份/同步文件），
/// v2 = PBKDF2-HMAC-SHA256 迭代派生（新写入），解密自动识别格式。
/// 密码丢失无法找回（无后门）。
class BackupCipher {
  BackupCipher._();

  /// v1 备份加密魔数（本地备份文件）。
  static const String magic = 'xm-backup-enc-v1';

  /// v1 同步加密魔数（WebDAV 历史文件，与 [magic] 同构：SHA-256 + GCM）。
  static const String syncMagicV1 = 'XMX-SYNC-1:';

  /// v2 同步/备份加密魔数（PBKDF2 派生，新写入统一走它）。
  static const String magicV2 = 'XMX-SYNC-2:';

  static final List<String> _allMagic = [magic, syncMagicV1, magicV2];

  /// 内容是否为加密格式（任一 v1/v2 魔数开头）。
  static bool isEncrypted(String body) =>
      _allMagic.any(body.startsWith);

  /// 口令 → 32 字节密钥。`v2=false` 走旧裸 SHA-256（仅用于解密历史 v1 文件）。
  static Uint8List deriveKey(String password, {bool v2 = false}) {
    if (!v2) {
      final digest = SHA256Digest();
      final input = utf8.encode(password);
      final out = Uint8List(32);
      var off = 0;
      digest.update(input, 0, input.length);
      off += digest.doFinal(out, off);
      return out;
    }
    // 固定盐 + 固定迭代：同步/备份场景密钥只用于本机解密自己的文件，
    // 盐由应用统一生成（多端必须一致才能互相解密，不能存随机盐在云端）。
    const salt = 'xingmanxia-webdav-v2';
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(utf8.encode(salt), 120000, 32));
    return Uint8List.fromList(pbkdf2.process(utf8.encode(password)));
  }

  /// AES-256-GCM 加密：返回 `magicV2\nivB64\ncipherB64` 三段式文本（v2 派生）。
  static String encrypt(String json, String password) {
    final key = deriveKey(password, v2: true);
    final iv = Uint8List.fromList(
        List<int>.generate(12, (_) => Random.secure().nextInt(256)));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final pt = utf8.encode(json);
    final out = Uint8List(gcm.getOutputSize(pt.length));
    var off = gcm.processBytes(pt, 0, pt.length, out, 0);
    off += gcm.doFinal(out, off);
    // 只编码实际写入的字节：getOutputSize 按块对齐会含尾部零填充，
    // 全量编码会把零填充带进密文，解密的 MAC 校验失败。
    return '$magicV2\n${base64Encode(iv)}\n'
        '${base64Encode(Uint8List.sublistView(out, 0, off))}';
  }

  /// 解密：输入 [encrypt]/历史 v1 的输出，自动按魔数识别 v2/v1 派生方式。
  /// 口令错误/内容篡改抛异常；非加密内容抛 ArgumentError。
  static String decrypt(String body, String password) {
    if (!isEncrypted(body)) {
      throw ArgumentError('不是加密备份文件');
    }
    final v2 = body.startsWith(magicV2);
    final lines = body.split('\n');
    if (lines.length < 3) throw ArgumentError('加密文件格式损坏');
    final iv = base64Decode(lines[1].trim());
    final ct = base64Decode(lines.sublist(2).join('\n').trim());
    final key = deriveKey(password, v2: v2);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final out = Uint8List(gcm.getOutputSize(ct.length));
    var off = gcm.processBytes(ct, 0, ct.length, out, 0);
    off += gcm.doFinal(out, off);
    return utf8.decode(Uint8List.sublistView(out, 0, off));
  }
}