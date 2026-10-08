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

  /// 裸 AES-128-CBC 解密（不剥 padding）：m3u8 分片解密专用——分片按 16
  /// 字节块对齐解密后原样拼接，末块可能不完整（不足 16 字节的尾部原样保留，
  /// 与 ffmpeg 的 m3u8 AES 解密行为一致），不能套 PKCS7 反填充。
  /// 其余场景一律用 [decryptCbc]（内建 PKCS7 反填充）。
  static Uint8List decryptCbcRaw(
      Uint8List data, Uint8List key, Uint8List iv) {
    if (key.length != 16 || iv.length != 16) {
      throw ArgumentError('AES-128-CBC requires 16-byte key and IV');
    }
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
    final out = Uint8List(data.length);
    var offset = 0;
    final blocks = data.length ~/ 16;
    for (var i = 0; i < blocks; i++) {
      offset += cipher.processBlock(data, i * 16, out, offset);
    }
    final tail = data.length - blocks * 16;
    if (tail > 0) {
      out.setRange(offset, offset + tail, data, blocks * 16);
      offset += tail;
    }
    return Uint8List.sublistView(out, 0, offset);
  }

  /// 计算 m3u8 分片 IV。m3u8 协议规定：IV 不足 16 字节时右侧补零（RFC 8216）；
  /// 无 IV 时用媒体序号 big-endian 128 位（序号占低 64 位，与 ffmpeg AV_WB64 一致）。
  static Uint8List segmentIv(String? hex, int mediaSeq) {
    if (hex != null && hex.isNotEmpty) {
      final iv = <int>[];
      for (var i = 0; i + 1 < hex.length; i += 2) {
        iv.add(int.tryParse(hex.substring(i, i + 2), radix: 16) ?? 0);
        if (iv.length == 16) break; // 只要前 16 字节
      }
      while (iv.length < 16) {
        iv.add(0); // 右侧补零对齐 16 字节
      }
      return Uint8List.fromList(iv);
    }
    final iv = Uint8List(16);
    var seq = mediaSeq;
    for (var i = 15; i >= 8; i--) {
      iv[i] = seq & 0xff;
      seq >>= 8;
    }
    return iv;
  }

  /// 在独立 Isolate 中执行 AES-128-CBC 解密，避免阻塞 UI 线程。
  static Future<Uint8List> decryptCbcAsync(
      Uint8List cipher, Uint8List key, Uint8List iv) {
    return compute(_decryptEntry, <dynamic>[cipher, key, iv]);
  }
}