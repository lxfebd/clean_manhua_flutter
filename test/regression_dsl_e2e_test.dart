import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_comic_source.dart';

/// 端到端：用本机 HTTP 服务器模拟一个漫画站，验证 DslComicSource 的
/// listByCategory → detail → chapterPics 全链路（真实网络请求）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    // flutter_test 默认把所有 HTTP 请求 mock 成 400，恢复真实网络以便连本机服务器
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_dsl_e2e').path;
        }
        return null;
      },
    );
  });

  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.address}:${server.port}';
    server.listen((req) {
      final path = req.uri.path;
      if (path == '/list.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <ul class="book-list">
            <li><a class="nm" href="/book/1.html">漫画A</a><img src="/cover/a.jpg"></li>
            <li><a class="nm" href="/book/2.html">漫画B</a><img src="/cover/b.jpg"></li>
          </ul>
        </body></html>''');
      } else if (path == '/book/1.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <h1 class="book-title">漫画A</h1>
          <div class="book-desc">这是描述</div>
          <div class="chapter-list">
            <a href="/ch/11.html">第1话</a>
            <a href="/ch/12.html">第2话</a>
          </div>
        </body></html>''');
      } else if (path == '/ch/11.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="read-img"><img src="/img/1.jpg"></div>
          <div class="read-img"><img src="/img/2.jpg"></div>
        </body></html>''');
      } else {
        req.response.statusCode = 404;
        req.response.write('not found');
      }
      req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  CustomSourceDef def() => CustomSourceDef.fromJson({
        'id': 'e2e',
        'name': 'E2E 源',
        'type': 'comic',
        'version': '1.0.0',
        'author': 't',
        'baseUrl': base,
        'categoryListUrl': '$base/list.html',
        'categoryList': {
          'css': 'ul.book-list li',
          'name': 'a.nm|text',
          'id': 'a|href',
          'url': 'a|href',
          'pic': 'img|src',
        },
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.book-title',
          'description': '.book-desc',
          'chapters': '.chapter-list a',
          'picListUrl': '$base/{id}',
          'picListCss': '.read-img img',
          'picAttr': 'src',
        },
      });

  test('listByCategory 解析列表', () async {
    final src = DslComicSource(def());
    final items = await src.listByCategory('all', 1);
    expect(items.length, 2);
    expect(items[0].name, '漫画A');
    expect(items[0].id, 'book/1.html');
    expect(items[0].pic, '$base/cover/a.jpg');
  });

  test('detail 解析章节', () async {
    final src = DslComicSource(def());
    final d = await src.detail('book/1.html');
    expect(d.name, '漫画A');
    expect(d.description, '这是描述');
    expect(d.chapters.length, 2);
    expect(d.chapters.first.title, '第1话');
  });

  test('chapterPics 解析图片', () async {
    final src = DslComicSource(def());
    final pics = await src.chapterPics('ch/11.html');
    expect(pics.length, 2);
    expect(pics.first, '$base/img/1.jpg');
    expect(pics[1], '$base/img/2.jpg');
  });
}