import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';

/// 修复 P1-1「网络层无响应体上限」回归测试。
///
/// 覆盖 `Net.readLimited`（io/Cronet/web 三条线上路径共用）：
///   1. 分块累计，未超上限时原样拼接返回
///   2. 超过 [limit] 立即抛 [ResponseTooLargeException]，不再消费后续块
///   3. 恰好等于上限不抛（等于合法）
/// 真实网络请求本身不加 mock（io 端难稳定注入超大响应），语义统一在
/// 读写辅助函数这一层验证；[Net.get]/[Net.downloadBytes] 默认值通过常量断言锁定。
void main() {
  Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 0x41));

  group('Net.readLimited 响应体字节上限', () {
    test('未超上限：分块原样拼接返回', () async {
      final src = Stream.fromIterable([bytes(3), bytes(4), bytes(2)]);
      final out = await Net.readLimited(src, 100, const Duration(seconds: 2));
      expect(out.length, 9);
    });

    test('恰好等于上限：合法，不抛异常', () async {
      final src = Stream.fromIterable([bytes(8), bytes(4)]);
      final out = await Net.readLimited(src, 12, const Duration(seconds: 2));
      expect(out.length, 12);
    });

    test('超过上限：抛 ResponseTooLargeException，且不消费后续块', () async {
      var consumed = false;
      final src = Stream.fromIterable([
        bytes(8),
        bytes(8), // 累计 16 > 10，触发上限
        bytes(1024), // 不应被消费
      ]).map((c) {
        consumed = c.length == 1024;
        return c;
      });
      await expectLater(
        Net.readLimited(src, 10, const Duration(seconds: 2)),
        throwsA(isA<ResponseTooLargeException>()),
      );
      // 触发后不应继续读到大块（防止无限内存累积）
      expect(consumed, isFalse);
    });

    test('默认上限常量：文本 8MB 对齐 parseHtml，下载 256MB 容下权重', () {
      expect(Net.maxTextBytes, 8 * 1024 * 1024);
      expect(Net.maxDownloadBytes, 256 * 1024 * 1024);
    });
  });
}