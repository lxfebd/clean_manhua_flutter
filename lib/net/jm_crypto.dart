import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 禁漫天堂（JM）App API 鉴权与响应解密。
/// 参考 hect0x7/JMComic-Crawler-Python 的 JmCryptoTool。
///
/// - 请求签名：`token = MD5("{ts}{token_secret}")`、`tokenparam = "{ts},{ver}"`。
/// - 响应解密：`AES-256-ECB(key = MD5("{ts}{data_secret}").hex_utf8, PKCS7)`。
class JmCrypto {
  static const String kAppVersion = '2.0.30';
  static const String kTokenSecret = '185Hcomic3PAPP7R';
  static const String kDataSecret = '185Hcomic3PAPP7R';

  /// 生成请求头所需的 (token, tokenparam)。
  static ({String token, String tokenparam}) makeHeaders(int ts) {
    final token = md5.convert(utf8.encode('$ts$kTokenSecret')).toString();
    return (token: token, tokenparam: '$ts,$kAppVersion');
  }

  /// 解密 base64 编码的响应 data 字段。返回明文 JSON 字符串。
  static String decryptResponseData(String base64Data, int ts,
      {String? secret}) {
    secret ??= kDataSecret;
    // key = MD5("{ts}{secret}").toString().utf-8 → 32 字节（AES-256）。
    final keyStr = md5.convert(utf8.encode('$ts$secret')).toString();
    final keyBytes = Uint8List.fromList(utf8.encode(keyStr));
    final cipher = PaddedBlockCipher('AES/ECB/PKCS7')
      ..init(false, PaddedBlockCipherParameters(KeyParameter(keyBytes), null));
    final raw = base64Decode(base64Data);
    final plain = cipher.process(Uint8List.fromList(raw));
    return utf8.decode(plain);
  }
}