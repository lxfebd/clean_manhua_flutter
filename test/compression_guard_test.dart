import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/compression_guard.dart';

/// P1-10 解压炸弹防护回归。
///
/// 审计实测：平台层与 WebDAV 的解压都只有输入侧上限（WebDAV 连输入上限都没有），
/// 一个 102KB 的 gzip 体能炸出 GB 级字节打爆内存。这个测试**真的造一个炸弹**
/// 来验证闸门有效，而不是只测常量。
void main() {
  group('gzipDecodeGuarded', () {
    test('正常内容：压缩→解压往返一致', () async {
      final text = '星漫匣' * 20000; // 约 260KB
      final compressed = gzip.encode(utf8.encode(text));
      final out = await gzipDecodeGuarded(compressed);
      expect(utf8.decode(out), text);
    });

    test('小文件的合法高膨胀比不被误杀', () async {
      // 200 字节 → ~6.4KB（32× 量级），但总量很小，必须放行。
      final tiny = List<int>.filled(200, 0x41);
      final compressed = gzip.encode(tiny);
      final out = await gzipDecodeGuarded(compressed);
      expect(out.length, tiny.length);
    });

    test('真炸弹：超过 maxBytes 立即抛，且不会完整展开', () async {
      // 20MB 全零 → gzip 后只有几十 KB，没有闸门时会完整解出 20MB。
      final bomb = Uint8List(20 * 1024 * 1024);
      final compressed = gzip.encode(bomb);
      expect(compressed.length, lessThan(100 * 1024),
          reason: '炸弹的压缩体必须很小才构成威胁');
      await expectLater(
        gzipDecodeGuarded(compressed, maxBytes: 4 * 1024 * 1024),
        throwsA(isA<DecompressionBombException>()),
      );
    });

    test('真炸弹：放大器超限也抛', () async {
      final bomb = Uint8List(8 * 1024 * 1024); // 8MB
      final compressed = gzip.encode(bomb);
      // 上限放到 256MB（不会触发体积闸门），但比例 8MB/几十KB ≫ 32×。
      await expectLater(
        gzipDecodeGuarded(compressed, maxBytes: kMaxDecodedBytes),
        throwsA(isA<DecompressionBombException>()),
      );
    });

    test('异常信息里带体积线索（用户可见、不是空泛失败）', () async {
      final bomb = Uint8List(6 * 1024 * 1024);
      final compressed = gzip.encode(bomb);
      try {
        await gzipDecodeGuarded(compressed, maxBytes: 1 * 1024 * 1024);
        fail('应当抛 DecompressionBombException');
      } on DecompressionBombException catch (e) {
        expect(e.toString(), contains('解压后体积异常'));
        expect(e.toString(), contains('MB'));
        expect(e.decodedSoFar, greaterThan(1024 * 1024));
      }
    });

    test('坏数据 → 抛 FormatException（不是静默返回空）', () async {
      await expectLater(
        gzipDecodeGuarded([1, 2, 3, 4, 5]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('zlibDecodeGuarded', () {
    test('正常往返', () async {
      final data = utf8.encode('ZLib 测试数据' * 5000);
      final compressed = zlib.encode(data);
      final out = await zlibDecodeGuarded(compressed);
      expect(utf8.decode(out), utf8.decode(data));
    });

    test('炸弹同样被拦', () async {
      final bomb = Uint8List(16 * 1024 * 1024);
      final compressed = zlib.encode(bomb);
      await expectLater(
        zlibDecodeGuarded(compressed, maxBytes: 2 * 1024 * 1024),
        throwsA(isA<DecompressionBombException>()),
      );
    });
  });

  group('常量（防呆）', () {
    test('上限与放大器为合理值', () {
      expect(kMaxDecodedBytes, 256 * 1024 * 1024);
      expect(kMaxDecodeRatio, 32);
      expect(kMaxDecodedBytesSmall, lessThan(kMaxDecodedBytes),
          reason: 'WebDAV/文本响应用更紧的上限');
    });
  });
}
