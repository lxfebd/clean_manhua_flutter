import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_comic_source.dart';

/// 源市场演示源（comic 型）端到端验证：用本机 HTTP 服务器模拟标准漫画站
/// 通用结构（分类列表 + 章节目录 + 章节图片页），验证 DslComicSource 的
/// listByCategory → detail → chapterPics 全链路。
///
/// 该 JSON 规则结构与远端 index.json 的 demo.dsl.manhua 条目保持同步，
/// 与 novel/video 演示源同属「新 DSL 顶层格式」，用于补齐源市场的 comic 类型。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_dsl_comic').path;
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
      if (path == '/list/1.html') {
        // 分类列表页：漫画卡片（封面 + 书名 + 详情链接）
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="mh-item">
            <a href="/manhua/1001.html"><img class="lazy" data-original="/cover/a.jpg"></a>
            <p class="title"><a href="/manhua/1001.html">星海传说</a></p>
          </div>
          <div class="mh-item">
            <a href="/manhua/1002.html"><img class="lazy" data-original="/cover/b.jpg"></a>
            <p class="title"><a href="/manhua/1002.html">孤岛奇谭</a></p>
          </div>
        </body></html>''');
      } else if (path == '/manhua/1001.html') {
        // 详情页：书名 + 简介 + 章节列表
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <h1 class="book-title">星海传说</h1>
          <div class="book-desc">发生在星海的冒险故事</div>
          <div class="chapter-list">
            <a href="/ch/1001-1.html">第1话 启程</a>
            <a href="/ch/1001-2.html">第2话 遭遇</a>
            <a href="/ch/1001-3.html">第3话 抉择</a>
          </div>
        </body></html>''');
      } else if (path == '/ch/1001-1.html') {
        // 章节图片页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="read-img"><img data-original="/img/1.jpg"></div>
          <div class="read-img"><img data-original="/img/2.jpg"></div>
          <div class="read-img"><img data-original="/img/3.jpg"></div>
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

  /// 与远端 index.json 的 demo.dsl.manhua 条目保持同步的 JSON 定义。
  CustomSourceDef def() => CustomSourceDef.fromJson({
        'id': 'demo.dsl.manhua',
        'name': '漫画演示源（通用结构）',
        'type': 'comic',
        'version': '1.0.0',
        'author': '星漫匣官方',
        'description':
            '源市场演示源：标准漫画站通用结构（分类列表 + 章节目录 + 章节图片），'
            '验证源市场一键安装全链路与 comic 型 DSL 解析。',
        'baseUrl': base,
        'headers': const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        'categoryListUrl': '$base/list/{page}.html',
        'categoryList': {
          'css': 'div.mh-item',
          'name': 'p.title a|text',
          'id': 'p.title a|href',
          'url': 'p.title a|href',
          'pic': 'img.lazy|data-original',
        },
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.book-title',
          'description': '.book-desc',
          'chapters': '.chapter-list a',
          'chapterUrl': 'href',
          'picListUrl': '$base/{id}',
          'picListCss': '.read-img img',
          'picAttr': 'data-original',
        },
      });

  test('def.validate() 通过', () {
    expect(def().validate(), isEmpty);
  });

  test('listByCategory 解析漫画卡片', () async {
    final src = DslComicSource(def());
    final items = await src.listByCategory('all', 1);
    expect(items.length, 2);
    expect(items[0].name, '星海传说');
    expect(items[0].id, 'manhua/1001.html');
    expect(items[0].pic, '$base/cover/a.jpg');
    expect(items[1].name, '孤岛奇谭');
  });

  test('detail 解析章节列表', () async {
    final src = DslComicSource(def());
    final d = await src.detail('manhua/1001.html');
    expect(d.name, '星海传说');
    expect(d.description, '发生在星海的冒险故事');
    expect(d.chapters.length, 3);
    expect(d.chapters[0].title, '第1话 启程');
    expect(d.chapters[0].id, 'ch/1001-1.html');
    expect(d.chapters[2].title, '第3话 抉择');
  });

  test('chapterPics 解析章节图片', () async {
    final src = DslComicSource(def());
    final pics = await src.chapterPics('ch/1001-1.html');
    expect(pics.length, 3);
    expect(pics.first, '$base/img/1.jpg');
    expect(pics[2], '$base/img/3.jpg');
  });
}