import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/sources/mangadex_ua.dart';
import 'package:xingmanxia/ui/widgets/cached_image.dart';

/// MangaDex 反爬回归（2026-11-26）。
///
/// ## 背景
/// api/uploads.mangadex.org 现在前置 **POWBlock**（SHA-256 工作量证明反爬
/// 网关）。它专门针对「自称浏览器却不是浏览器」的请求：只要 User-Agent
/// 以 `Mozilla/5.0` 开头，就返回 **200 + 一张 2KB 的 HTML 验证页**，
/// 正文是 JS 挖矿脚本。
///
/// 旧实现在接口侧正是伪装浏览器 UA，于是**每个接口**都拿到 HTML，
/// `jsonDecode` 首字符即抛 `FormatException`——在源健康里表现为
/// 「MangaDex FormatException」，极容易被误判成 API 契约变更而去改解析器。
///
/// 图片侧更隐蔽：`uploads.mangadex.org` 走**同一套网关**，旧代码图片全用
/// 浏览器 UA，章节图返回 HTML 后解码端只当**损坏图**，表现是封面全灰、
/// 章节图全裂，日志里看不出是反爬。
///
/// 实测对照（2026-11-26，同机同时刻）：
/// | UA | 结果 |
/// |---|---|
/// | `Mozilla/5.0 (Windows NT 10.0; …) AppleWebKit/537.36` | 2022B HTML 挑战页 |
/// | `Mozilla/5.0 (compatible; xingmanxia/…)` | 2022B HTML 挑战页 |
/// | `xingmanxia/<ver> (https://github.com/…)` | 正常 JSON / image |
/// | 不带 UA / `curl/8.0` / `Dart/3.x` | 正常 |
void main() {
  group('MangaDex UA 反爬契约', () {
    test('不得伪装成 Mozilla 浏览器（会触发 POWBlock 挑战页）', () {
      final ua = mangaDexUserAgent();
      expect(
        ua.startsWith('Mozilla/'),
        isFalse,
        reason: 'Mozilla/* 会被 POWBlock 判定为伪装爬虫并返回 HTML 挑战页，'
            '所有接口都会 FormatException',
      );
    });

    test('不得复用全局伪装浏览器 UA', () {
      // NetConn.defaultUA 是 Mozilla/* 伪装 UA（国内源必需）。
      // 这里守一道语义：UA 必须能被认出是星漫匣自己。
      expect(mangaDexUserAgent(), contains('xingmanxia'));
    });

    test('如实标识应用，并带版本号', () {
      final ua = mangaDexUserAgent();
      expect(
        RegExp(r'xingmanxia/\d+\.\d+\.\d+').hasMatch(ua),
        isTrue,
        reason: 'MangaDex API 规范要求 UA 带版本号，便于对方定位问题。'
            '当前 UA=$ua',
      );
    });

    test('版本号来自运行时，不是硬编码字面量', () {
      // 关键回归：UA 里的版本必须来自 UpdateChecker.currentVersion()
      // （启动时由 PackageInfo 写入的真实版本），不能是 'xingmanxia/1.5.7'
      // 这种字面量——否则下次升版 UA 就在说谎，MangaDex 侧排查会拿到
      // 错误版本。单测无 PackageInfo，故断言"不含旧硬编码值"。
      expect(
        mangaDexUserAgent(),
        isNot(contains('1.5.7')),
        reason: '若这里失败，说明有人把版本号写死回 UA 了',
      );
      // 同一进程内必须稳定（不能每次调用乱变）。
      expect(mangaDexUserAgent(), mangaDexUserAgent());
    });

    test('带联系方式（项目地址），符合官方 API 规范', () {
      expect(mangaDexUserAgent(), contains(kMangaDexUaContact));
    });

    test('接口头要求 JSON，图片头不带 Accept，UA 一致', () {
      expect(mangaDexApiHeaders()['Accept'], 'application/json');
      expect(mangaDexImageHeaders().containsKey('Accept'), isFalse);
      // 同一网关同一策略，两种头的 UA 必须一致。
      expect(mangaDexApiHeaders()['User-Agent'],
          mangaDexImageHeaders()['User-Agent']);
    });
  });

  group('MangaDex 域名识别', () {
    test('api / uploads / at-home CDN 都算 MangaDex 全线', () {
      expect(isMangaDexHost('https://api.mangadex.org/manga'), isTrue);
      expect(isMangaDexHost('https://uploads.mangadex.org/data/a/b.jpg'), isTrue);
      expect(
        isMangaDexHost('https://cmdxd98sb0x3yprd.mangadex.network/data/a.jpg'),
        isTrue,
      );
    });

    test('其它站点不算（国内源 CDN 必须保持浏览器 UA）', () {
      expect(isMangaDexHost('https://p6.aawp.cn/cover/1.jpg'), isFalse);
      expect(isMangaDexHost('https://lain.bgm.tv/pic/1.jpg'), isFalse);
      expect(isMangaDexHost('https://www.dm5.com/x.jpg'), isFalse);
      // 防误判：仅"包含"关键字不算，必须真以域名结尾。
      expect(isMangaDexHost('https://fakemangadex.org.cn/a.jpg'), isFalse);
    });
  });

  group('图片请求头按域名分流', () {
    test('uploads 章节图用应用 UA，不用浏览器 UA', () {
      final h = CachedImage.headersFor(
        'https://uploads.mangadex.org/data/abcd/page1.jpg',
      );
      expect(h['User-Agent']!.startsWith('Mozilla/'), isFalse);
      expect(h['User-Agent'], contains('xingmanxia'));
    });

    test('封面域 covers 同样走应用 UA', () {
      final h = CachedImage.headersFor(
        'https://uploads.mangadex.org/covers/xxx/cover.jpg.256.jpg',
      );
      expect(h['User-Agent']!, contains('xingmanxia'));
    });

    test('at-home CDN（*.mangadex.network）同样走应用 UA', () {
      final h = CachedImage.headersFor(
        'https://cmdxd98sb0x3yprd.mangadex.network/data/abc/p1.jpg',
      );
      expect(h['User-Agent']!, contains('xingmanxia'));
    });

    test('其它站点仍用浏览器 UA（国内源 CDN 需要伪装，不能一刀切）', () {
      final h = CachedImage.headersFor('https://p6.aawp.cn/cover/1.jpg');
      expect(h['User-Agent']!.startsWith('Mozilla/'), isTrue);
    });

    test('bgm.tv 保留 Referer 防盗链', () {
      final h = CachedImage.headersFor('https://lain.bgm.tv/pic/1.jpg');
      expect(h['Referer'], 'https://bgm.tv/');
    });
  });
}
