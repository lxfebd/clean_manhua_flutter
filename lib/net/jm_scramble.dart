import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// JM 图片解扰（按 JMComic 开源库真实算法还原）。
///
/// 禁漫对部分专辑（aid ≥ 220980）的图片做「纵向分块倒序」混淆：
///   1. 分块数 num 由 aid + 文件名 决定（JmImageTool.get_num）：
///      - aid < 220980         → 不加密（num = 0）
///      - 220980 ≤ aid < 268850 → 固定 10 块
///      - 268850 ≤ aid < 421926 → MD5(aid+文件名) 末字符 ASCII % 10 × 2 + 2
///      - aid ≥ 421926（2023-02-08 起）→ 同上但 % 8 × 2 + 2
///   2. 把图片按高度切成 num 个横向条带（第一条多 h % num 余数），
///      然后「块顺序倒转」拼回（每块内部像素方向不变）——即
///      descramble = 把源图底部块放到目标顶部、顶部块放到目标底部。
///
/// 参考：hect0x7/JMComic-Crawler-Python（JmImageTool.decode_and_save / get_num、
///       JmMagicConstants.SCRAMBLE_*）。
class JmScramble {
  /// aid < 220980 不加密。
  static const int kScrambleAid0 = 220980;
  /// 220980 ≤ aid < 268850 固定 10 块。
  static const int kScrambleAid1 = 268850;
  /// 2023-02-08 起 MD5 分支取模由 10 改为 8。
  static const int kScrambleAid2 = 421926;

  /// 把图片 URL 拆成 (真实地址, scramble 标记?)。
  /// 兼容旧格式 `url@xxx`；新算法不依赖 @ 内容，仅从 URL 解析 aid。
  static ({String url, String? scramble}) splitUrl(String url) {
    final idx = url.lastIndexOf('@');
    if (idx < 0) return (url: url, scramble: null);
    return (url: url.substring(0, idx), scramble: url.substring(idx + 1));
  }

  /// 常用正则（编译一次）。
  static final RegExp _rePhoto = RegExp(r'(photos?|albums?)/(\d+)');
  static final RegExp _reId = RegExp(r'id=(\d+)');
  static final RegExp _reJmTag = RegExp(r'@jm:(\d+)');

  /// 从图片 URL 解析专辑 ID（aid）。
  /// 支持 /albums/{id}/、/photos/{id}/、/media/photos/{id}/、id={id}，
  /// 以及阅读器附加的 `@jm:{aid}` 标记。
  static int? parseAid(String url) {
    final m = _rePhoto.firstMatch(url);
    if (m != null) return int.tryParse(m.group(2)!);
    final m2 = _reId.firstMatch(url);
    if (m2 != null) return int.tryParse(m2.group(1)!);
    final m3 = _reJmTag.firstMatch(url);
    if (m3 != null) return int.tryParse(m3.group(1)!);
    return null;
  }

  /// URL 文件名（去扩展名与 query），如 .../00001.jpg → 00001。
  static String fileName(String url) {
    var u = url;
    final q = u.indexOf('?');
    if (q >= 0) u = u.substring(0, q);
    final slash = u.lastIndexOf('/');
    var name = slash >= 0 ? u.substring(slash + 1) : u;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name;
  }

  /// 计算分块数（0 = 不加密）。
  static int getNum(int aid, String filename) {
    if (aid < kScrambleAid0) return 0;
    if (aid < kScrambleAid1) return 10;
    final x = aid < kScrambleAid2 ? 10 : 8;
    final s = md5.convert(utf8.encode('$aid$filename')).toString();
    final num = s.codeUnitAt(s.length - 1) % x * 2 + 2;
    return num;
  }

  /// 还原被打乱的图片字节。从 [url] 解析 aid 与文件名；无需还原时原样返回。
  /// 还原失败时回退原图，绝不抛异常。
  ///
  /// 真实算法（与禁漫前端 JS `onImageLoaded` 一致）：
  ///   1. 算出 num 段数（由 aid + filename 决定）；
  ///   2. 加扰图高度与原图相同，无黑边空隙；它是把原图纵向切成 num 块后
  ///      「块顺序倒转」拼回的结果（最底下的块在最上，最顶上的块在最下）；
  ///   3. 基础块高 c = h ~/ num，余数 l = h % num 归入 m == 0 的块（即底部块）；
  ///   4. 还原 = 从加扰图底部往顶部逐块取（源 y = h - c*(m+1) - l），
  ///      贴到目标画布顶部往下（目标 y 累加块高），得到与原图同高的图片。
  static Uint8List descramble(Uint8List bytes, String url) {
    final aid = parseAid(url);
    if (aid == null) return bytes;
    final num = getNum(aid, fileName(url));
    if (num <= 1) return bytes;
    try {
      final image = img.decodeImage(bytes);
      if (image == null) return bytes;
      final w = image.width;
      final h = image.height;
      if (h <= 1) return bytes;
      final c = h ~/ num; // 基础块高
      final l = h % num; // 余数
      if (c <= 0) return bytes;
      final out = img.Image(width: w, height: h);
      var g = 0; // 目标 y（从上往下）
      for (var m = 0; m < num; m++) {
        final srcY = h - c * (m + 1) - l; // 源 y（从加扰图底部往上取）
        final blockH = m == 0 ? c + l : c; // 底部块多含余数
        final strip =
            img.copyCrop(image, x: 0, y: srcY, width: w, height: blockH);
        img.compositeImage(out, strip, dstX: 0, dstY: g);
        g += blockH;
      }
      return Uint8List.fromList(img.encodeJpg(out, quality: 92));
    } catch (_) {
      return bytes;
    }
  }

  /// compute() 入口（必须为顶层/静态函数，以便跨 Isolate 序列化）。
  static Uint8List _descrambleEntry(List<dynamic> args) {
    return descramble(args[0] as Uint8List, args[1] as String);
  }

  /// 在独立 Isolate 中执行解扰，避免 200-800ms 的 CPU 密集操作阻塞 UI 线程。
  /// 若 [bytes] 无需还原（aid < 220980 或解析失败），原样返回。
  static Future<Uint8List> descrambleAsync(Uint8List bytes, String url) {
    final aid = parseAid(url);
    if (aid == null) return Future.value(bytes);
    final num = getNum(aid, fileName(url));
    if (num <= 1) return Future.value(bytes);
    return compute(_descrambleEntry, <dynamic>[bytes, url]);
  }
}
