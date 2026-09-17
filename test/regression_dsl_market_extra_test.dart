import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_comic_source.dart';

/// 源市场补充演示源端到端验证（本机 HTTP 服务器模拟站结构）：
///
/// 1. demo.dsl.regex —— 正则行式抽取漫画源：列表/章节/图片全用正则捕获组
///    （r1/r2/r3），验证 DSL 的 regex 抽取通道（对应旧演示源 demo.dsl.manhuadb
///     的角色，但使用新版 DSL 顶层格式）。
/// 2. demo.dsl.category —— 带分类导航的漫画源：categoriesUrl + categories
///    （itemName/itemUrl）→ listByCategory 全链路，验证分类页下拉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_dsl_extra').path;
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
      if (path == '/regex/list/1.html') {
        // 正则行式抽取的列表页（无 css 容器，靠 regex 锚点）
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="list">
            <a href="/re/101.html" title="极速领域">极速领域</a>
            <img data-src="/re/cover-101.jpg">
            <a href="/re/102.html" title="暗夜行者">暗夜行者</a>
            <img data-src="/re/cover-102.jpg">
          </div>
        </body></html>''');
      } else if (path == '/re/101.html') {
        // 详情页（章节正则抽取）
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <h1 class="book-title">极速领域</h1>
          <div class="book-desc">飙车题材漫画</div>
          <div class="chapter">
            <a href="/rc/101-1.html">第1话 起步</a>
            <a href="/rc/101-2.html">第2话 弯道</a>
          </div>
        </body></html>''');
      } else if (path == '/rc/101-1.html') {
        // 章节图片页（正则抽取 <img>）
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="content">
            <img src="/rim/1.jpg">
            <img src="/rim/2.jpg">
          </div>
        </body></html>''');
      } else if (path == '/cat/categories.html') {
        // 分类导航页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="nav">
            <a href="hot">热门</a>
            <a href="new">最新</a>
            <a href="finish">完结</a>
          </div>
        </body></html>''');
      } else if (path == '/cat/hot.html') {
        // 分类内容页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="pic">
            <a href="/ca/201.html"><img data-original="/cat/c1.jpg"></a>
            <p><a href="/ca/201.html">热门漫画一</a></p>
          </div>
          <div class="pic">
            <a href="/ca/202.html"><img data-original="/cat/c2.jpg"></a>
            <p><a href="/ca/202.html">热门漫画二</a></p>
          </div>
        </body></html>''');
      } else {
        req.response.statusCode = 404;
        req.response.write('not found: $path');
      }
      req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// 与远端 index.json 的 demo.dsl.regex 条目保持同步。
  CustomSourceDef regexDef() => CustomSourceDef.fromJson({
        'id': 'demo.dsl.regex',
        'name': '正则抽取演示源',
        'type': 'comic',
        'version': '1.0.0',
        'author': '星漫匣官方',
        'description':
            '源市场演示源：正则行式抽取（regex + r1/r2/r3 捕获组），'
            '验证 DSL 正则抽取通道。',
        'baseUrl': base,
        'headers': const {'User-Agent': 'Mozilla/5.0'},
        'categoryListUrl': '$base/regex/list/{page}.html',
        'categoryList': {
          'regex':
              '<a href="([^"]+)" title="([^"]+)">[^<]*</a>[\\s\\S]*?<img data-src="([^"]+)"',
          'id': 'r1',
          'name': 'r2',
          'pic': 'r3',
          'url': 'r1',
        },
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.book-title',
          'description': '.book-desc',
          'chaptersRe':
              '<a href="(?<href>[^"]+)"[^>]*>(?<title>[^<]+)</a>',
          'picListUrl': '$base/{id}',
          'picListRe': '<img src="([^"]+)"',
          'picAttr': 'src',
        },
      });

  /// 与远端 index.json 的 demo.dsl.category 条目保持同步。
  CustomSourceDef categoryDef() => CustomSourceDef.fromJson({
        'id': 'demo.dsl.category',
        'name': '分类导航演示源',
        'type': 'comic',
        'version': '1.0.0',
        'author': '星漫匣官方',
        'description':
            '源市场演示源：分类导航（categoriesUrl + categories），'
            '验证分类页下拉与分类内容列表。',
        'baseUrl': base,
        'headers': const {'User-Agent': 'Mozilla/5.0'},
        'categoriesUrl': '$base/cat/categories.html',
        'categories': {
          'css': 'div.nav a',
          'itemName': 'text',
          'itemUrl': 'href',
        },
        'categoryListUrl': '$base/cat/{categoryId}.html',
        'categoryList': {
          'css': 'div.pic',
          'name': 'p a|text',
          'id': 'p a|href',
          'url': 'p a|href',
          'pic': 'img|data-original',
        },
      });

  test('regex 源 validate() 通过', () {
    expect(regexDef().validate(), isEmpty);
  });

  test('regex 源 listByCategory 正则抽卡', () async {
    final src = DslComicSource(regexDef());
    final items = await src.listByCategory('all', 1);
    expect(items.length, 2);
    expect(items[0].name, '极速领域');
    expect(items[0].id, 're/101.html');
    expect(items[0].pic, '$base/re/cover-101.jpg');
    expect(items[1].name, '暗夜行者');
  });

  test('regex 源 detail 正则抽章节', () async {
    final src = DslComicSource(regexDef());
    final d = await src.detail('re/101.html');
    expect(d.name, '极速领域');
    expect(d.description, '飙车题材漫画');
    expect(d.chapters.length, 2);
    expect(d.chapters[0].title, '第1话 起步');
  });

  test('regex 源 chapterPics 正则抽图', () async {
    final src = DslComicSource(regexDef());
    final pics = await src.chapterPics('rc/101-1.html');
    expect(pics.length, 2);
    expect(pics.first, '$base/rim/1.jpg');
    expect(pics[1], '$base/rim/2.jpg');
  });

  test('category 源 validate() 通过', () {
    expect(categoryDef().validate(), isEmpty);
  });

  test('category 源 categories() 解析导航', () async {
    final src = DslComicSource(categoryDef());
    final cats = await src.categories();
    expect(cats.length, 3);
    expect(cats[0].name, '热门');
    expect(cats[0].id, 'hot');
    expect(cats[2].name, '完结');
  });

  test('category 源 listByCategory 按分类拉列表', () async {
    final src = DslComicSource(categoryDef());
    final items = await src.listByCategory('hot', 1);
    expect(items.length, 2);
    expect(items[0].name, '热门漫画一');
    expect(items[0].pic, '$base/cat/c1.jpg');
  });
}