import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 解压炸弹防护（P1-10）。
///
/// 背景：HTTP 响应的 `Content-Encoding: gzip` 过去是「输入有限、输出不限」——
/// 一个 102KB 的压缩体能炸出 GB 级字节（gzip 常态膨胀比可达 1000×），直接
/// 打爆内存。审计实测平台层与 WebDAV 两条解压路径都只有输入侧上限
/// （WebDAV 连输入上限都没有：`res.fold` 先把整个响应堆进内存）。
///
/// 这里统一收口：**流式解码 + 逐块累计**，输出超过任一线索立即抛异常，
/// 不让炸弹有机会完整展开。
class DecompressionBombException implements Exception {
  final String reason;
  final int decodedSoFar;
  DecompressionBombException(this.reason, this.decodedSoFar);
  @override
  String toString() => '响应解压后体积异常：$reason（已解压 $decodedSoFar 字节）';
}

/// 单个响应的默认解压上限。
/// - 256MB：通用上限（远超任何正常漫画/番剧页面，正常站点一页 < 5MB）；
/// - 放大器 32×：超过即视为炸弹。低于 4MB 不查放大器——小文件的合法膨胀
///   （200B → 6.4KB）不能误杀。
const int kMaxDecodedBytes = 256 * 1024 * 1024;
const int kMaxDecodeRatio = 32;
const int kMaxDecodedBytesSmall = 32 * 1024 * 1024;

class _BoundedGuard {
  final BytesBuilder _out = BytesBuilder(copy: false);
  final int maxBytes;
  final int maxRatio;
  final int compressedLen;

  _BoundedGuard(this.maxBytes, this.maxRatio, this.compressedLen);

  int get length => _out.length;

  void add(List<int> chunk) {
    final next = _out.length + chunk.length;
    if (next > maxBytes) {
      throw DecompressionBombException('超过 ${_fmt(maxBytes)} 上限', next);
    }
    // 只对「已经不小」的解压结果查放大器，避免误杀小文件。
    if (next > 4 * 1024 * 1024 && compressedLen > 0) {
      final ratio = next / compressedLen;
      if (ratio > maxRatio) {
        throw DecompressionBombException(
            '膨胀比 ${ratio.toStringAsFixed(1)}× 超过 $maxRatio×', next);
      }
    }
    _out.add(chunk);
  }

  Uint8List take() => _out.takeBytes();
}

/// 流式解码：逐块校验，超限立即中止（不会先完整解压再检查）。
Future<List<int>> _decodeGuarded(
  List<int> compressed,
  Converter<List<int>, List<int>> codec,
  int maxBytes,
  int maxRatio,
) async {
  final guard = _BoundedGuard(maxBytes, maxRatio, compressed.length);
  await for (final chunk in codec.bind(Stream<List<int>>.fromIterable([compressed]))) {
    guard.add(chunk);
  }
  return guard.take();
}

/// 带闸门的 gzip 解码。[maxBytes] 默认 [kMaxDecodedBytes]。
Future<List<int>> gzipDecodeGuarded(List<int> compressed,
    {int maxBytes = kMaxDecodedBytes, int maxRatio = kMaxDecodeRatio}) {
  return _decodeGuarded(compressed, gzip.decoder, maxBytes, maxRatio);
}

/// 带闸门的 deflate/zlib 解码。
Future<List<int>> zlibDecodeGuarded(List<int> compressed,
    {int maxBytes = kMaxDecodedBytes, int maxRatio = kMaxDecodeRatio}) {
  return _decodeGuarded(compressed, zlib.decoder, maxBytes, maxRatio);
}

String _fmt(int b) => b >= 1024 * 1024
    ? '${(b / 1024 / 1024).toStringAsFixed(0)}MB'
    : '${(b / 1024).toStringAsFixed(0)}KB';
