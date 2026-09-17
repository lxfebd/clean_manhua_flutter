import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/xbiquge_novel_source.dart';

/// xbiquge 多页章节聚合的离线回归测试。
///
/// 背景：chapterContent 的 while(true) 逐页聚合（_{n}.html 后缀）原本没有任何
/// 页数上限——站点若在末页仍返回指向同章下一页的导航（页面结构漂移/404 残留），
/// page 会无限递增并持续发请求，正文无限膨胀（与 RateLimiter 活锁同类：循环
/// 依赖外部内容前进却无兜底）。已在 chapterContent 加 _maxChapterPages 上游兜底，
/// 此处用本地 mock server 锁定正常聚合与超限截断两个行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_xbiquge').path;
        }
        return null;
      },
    );
  });

  late HttpServer server;
  late String base;

  /// 生成一节正文页：`qsbs.bb('base64-utf8')` 包裹的 <p> 文本 +
  /// JS 导航变量。nextHref 指向同章下一页或下一章。
  String pageBody(String title, List<String> paras, String nextHref,
      {String? prevHref}) {
    final html = paras.map((p) => '<p>$p</p>').join();
    final b64 = base64Encode(utf8.encode(html));
    final prev = prevHref == null ? '' : "var lkldeh='$prevHref';";
    return '''
    <html><head><title>$title</title></head><body>
    <h1>$title</h1>
    <script type="text/javascript">document.writeln(qsbs.bb('$b64'));$prev var ycmxa='$nextHref';</script>
    </body></html>''';
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.address}:${server.port}';
    // write 后必须 close()，否则客户端读不到响应体而等待超时
    server.listen((req) {
      final path = req.uri.path;
      req.response.headers.contentType = ContentType.html;
      void respond(String body) {
        req.response.write(body);
        req.response.close();
      }
      // 多页章节：101.html（首页）→ 101_1.html（第2页）→ 101_2.html（第3页）→ 结束切到 102
      if (path == '/books_100/101.html') {
        respond(pageBody('第一章 起点（第1页）', ['第一段', '第二段'],
            '/books_100/101_1.html'));
      } else if (path == '/books_100/101_1.html') {
        respond(pageBody('第一章 起点（第2页）', ['第三段'],
            '/books_100/101_2.html'));
      } else if (path == '/books_100/101_2.html') {
        respond(pageBody('第一章 起点（第3页）', ['第四段'],
            '/books_100/102.html'));
      } else if (path == '/books_100/102.html') {
        respond(pageBody('第二章 终点', ['第二章内容'],
            '/books_100/103.html', prevHref: '/books_100/101.html'));
      } else if (path == '/books_200/201.html') {
        // 畸形导航：始终指向同章下一页（永不指向下一章）→ 必须被上限截断
        respond(pageBody('畸形章', ['内容' + '0'],
            '/books_200/201_1.html'));
      } else if (RegExp(r'^/books_200/201_\d+\.html$').hasMatch(path)) {
        respond(pageBody('畸形章', ['内容$path'],
            '/books_200/201_${int.parse(path.split('_').last.split('.').first) + 1}.html'));
      } else {
        respond('<html><body>404</body></html>');
      }
    });
    // 注入 mock host，覆盖 xbiquge 内置域名
    await SourceConfigStore.save(SourceConfig(
      engineId: 'xbiquge',
      id: 'xbiquge',
      name: 'xbiquge',
      hosts: [base],
    ));
    SourceConfigStore.invalidateCache();
  });

  tearDown(() async {
    await server.close(force: true);
    await SourceConfigStore.resetToDefaults();
    SourceConfigStore.invalidateCache();
  });

  test('多页章节聚合：3 页合并为完整正文，prev/next 章节正确', () async {
    final src = XbiqugeNovelSource();
    final content = await src.chapterContent('100|101');
    // 3 页全部聚合（第1页2段 + 第2页1段 + 第3页1段）
    expect(content.paragraphs, ['第一段', '第二段', '第三段', '第四段']);
    expect(content.title, '第一章 起点'); // （第N页）后缀被剥离
    expect(content.prevChapterId, isNull); // 首页无 prev 导航
    expect(content.nextChapterId, '100|102'); // 末页切到下一章
  });

  test('畸形导航（始终指向同章下一页）被页数上限截断，不无限请求', () async {
    final src = XbiqugeNovelSource();
    final content = await src.chapterContent('200|201');
    // 被截断后 nextChapterId 为空、段落数有限（<上限），且不会抛出
    expect(content.paragraphs.length, lessThanOrEqualTo(50));
    expect(content.nextChapterId, isNull);
    expect(content.title, '畸形章');
  });
}