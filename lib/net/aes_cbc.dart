import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// AES-128-CBC 解密（PKCS7 反填充内建），使用 pointycastle。
/// 用于豆包漫画章节图片解密（key 固定为 5V&RoR%Jf@pJPydF）。
class AesCbc {
  static Uint8List decryptCbc(Uint8List cipher, Uint8List key, Uint8List iv) {
    if (key.length != 16) {
      throw ArgumentError('AES-128 requires 16-byte key');
    }
    if (iv.length != 16) {
      throw ArgumentError('AES-CBC requires 16-byte IV');
    }
    if (cipher.isEmpty || cipher.length % 16 != 0) {
      throw ArgumentError('ciphertext length must be a non-zero multiple of 16');
    }
    final engine = PaddedBlockCipher('AES/CBC/PKCS7')
      ..init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, CipherParameters?>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
    return engine.process(cipher);
  }

  static Uint8List _decryptEntry(List<dynamic> args) {
    return decryptCbc(
      args[0] as Uint8List,
      args[1] as Uint8List,
      args[2] as Uint8List,
    );
  }

  /// 在独立 Isolate 中执行 AES-128-CBC 解密，避免阻塞 UI 线程。
  static Future<Uint8List> decryptCbcAsync(
      Uint8List cipher, Uint8List key, Uint8List iv) {
    return compute(_decryptEntry, <dynamic>[cipher, key, iv]);
  }
}