import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/download_manager.dart';
import 'package:xingmanxia/net/video_download_manager.dart';

/// P0-03 / P0-04 的**纯逻辑**回归（不联网、不需要真机）：
/// - `LocalPages`：离线页枚举的语义（缺页为 null、complete/total/missing）；
/// - `looksLikeMarkup`：首块特征嗅探能否识别「网页被存成 mp4」的假成功。
///
/// 端到端（下载→杀进程→飞行模式冷启动）仍需实机复验，这里只锁死可判定的部分。
void main() {
  group('LocalPages（P0-03 离线枚举语义）', () {
    test('一页不缺 → complete 且 missing=0', () {
      const p = LocalPages(['/a/0.jpg', '/a/1.jpg', '/a/2.jpg']);
      expect(p.complete, isTrue);
      expect(p.missing, 0);
      expect(p.total, 3);
    });

    test('缺页以 null 占位，不被静默换成网络 URL', () {
      const p = LocalPages(['/a/0.jpg', null, '/a/2.jpg']);
      expect(p.complete, isFalse);
      expect(p.missing, 1);
      expect(p.total, 3);
      expect(p.paths[1], isNull,
          reason: '缺页必须是 null，调用方才好明示「本地缺 N 页」');
    });

    test('空列表不算 complete（防零页假成功）', () {
      const p = LocalPages([]);
      expect(p.complete, isFalse);
      expect(p.total, 0);
    });

    test('全部缺失 → missing 等于 total', () {
      const p = LocalPages([null, null]);
      expect(p.missing, 2);
      expect(p.complete, isFalse);
    });
  });

  group('looksLikeMarkup（P0-04 首块嗅探）', () {
    /// 把字符串按 UTF-8 编码成字节（模拟网络分片）。
    List<int> b(String s) => utf8.encode(s);

    test('网页/错误页被识别', () {
      for (final s in [
        '<!DOCTYPE html><html><head><title>404</title></head></html>',
        '<html><body>登录后继续</body></html>',
        '<?xml version="1.0"?><Error/>',
        '  \n\t<!doctype HTML>',
        '{"code":403,"message":"access denied"}',
        '{"error":"forbidden"}',
      ]) {
        expect(VideoDownloadManager.looksLikeMarkup(b(s)), isTrue, reason: s);
      }
    });

    test('二进制媒体分片不被误判', () {
      // TS 同步字节 0x47、fMP4 的 "ftyp"、乱码二进制均不得判为网页。
      expect(VideoDownloadManager.looksLikeMarkup([0x47, 0x40, 0x00, 0x10]),
          isFalse);
      expect(VideoDownloadManager.looksLikeMarkup(b('ftypisom')), isFalse);
      expect(VideoDownloadManager.looksLikeMarkup([0x00, 0x00, 0x00, 0x18]),
          isFalse);
      expect(
          VideoDownloadManager.looksLikeMarkup([0xFF, 0xD8, 0xFF, 0xE0]),
          isFalse);
    });

    test('空分片不判为网页（交给别处判断）', () {
      expect(VideoDownloadManager.looksLikeMarkup(const []), isFalse);
    });

    test('只取前 256 字节：长二进制里混入 < 也不误判', () {
      // 视频正常内容中完全可能出现 '<'；嗅探只看开头前缀。
      final bytes = <int>[0x47, 0x40, ...List<int>.filled(300, 0)];
      expect(VideoDownloadManager.looksLikeMarkup(bytes), isFalse);
    });
  });
}
