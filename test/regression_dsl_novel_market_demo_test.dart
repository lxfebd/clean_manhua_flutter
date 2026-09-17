import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_novel_source.dart';

/// 源市场演示源（novel 型）端到端验证：用本机 HTTP 服务器模拟笔趣阁系
/// 通用结构（搜索页 + 章节目录页 + 正文页），验证 DslNovelSource 的
/// search → detail → chapterContent 全链路。
///
/// 该 JSON 规则结构与 sources/ 下两个视频演示源同属「新 DSL 顶层格式」
/// （categoryList/detail 顶层 key，而非旧的 rules 嵌套），用于替换远端
/// index.json 里旧 rules 格式的演示源——旧格式 CustomSourceDef.fromJson
/// 无法解析，是「源市场列表空」的根因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_dsl_novel').path;
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
      final kw = req.uri.queryParameters['searchkey'] ?? '';
      if (path == '/modules/article/search.php') {
        // 搜索页：结果表，书名链接指向章节目录页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body><table id="novelist"><tbody>
          <tr class="grid">
            <td><a href="/8/8123/">『$kw』之试</a></td>
            <td>作者A</td>
          </tr>
          <tr class="grid">
            <td><a href="/8/8124/">第二本</a></td>
            <td>作者B</td>
          </tr>
        </tbody></table></body></html>''');
      } else if (path == '/8/8123/') {
        // 章节目录页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <h1 class="book-title">试字之书</h1>
          <p class="info">这是简介</p>
          <div class="listmain">
            <dl><dd><a href="/8/8123/8123001.html">第一章 起点</a></dd>
            <dd><a href="/8/8123/8123002.html">第二章 转折</a></dd>
            <dd><a href="/8/8123/8123003.html">第三章 结局</a></dd></dl>
          </div>
        </body></html>''');
      } else if (path == '/catindex.html') {
        // 分类导航页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <div class="nav">
            <a href="xuanhuan">玄幻</a>
            <a href="dushi">都市</a>
            <a href="kehuan">科幻</a>
          </div>
        </body></html>''');
      } else if (path == '/cat/xuanhuan.html') {
        // 分类列表页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body><ul class="booklist">
          <li><a href="/12/1201/">斗破苍穹</a></li>
          <li><a href="/12/1202/">凡人修仙传</a></li>
        </ul></body></html>''');
      } else if (path == '/8/8123/8123001.html') {
        // 正文页
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <h1>第一章 起点</h1>
          <div id="content">
            <p>第一段正文。</p>
            <p>第二段正文。</p>
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

  /// 与远端 index.json 的 demo.dsl.biquge 条目保持同步的 JSON 定义。
  CustomSourceDef def() => CustomSourceDef.fromJson({
        'id': 'demo.dsl.biquge',
        'name': '笔趣阁 演示源（通用结构）',
        'type': 'novel',
        'version': '1.0.0',
        'author': '星漫匣官方',
        'description':
            '源市场演示源：笔趣阁系通用结构（搜索表 + 章节目录 + 正文段落），'
            '验证源市场一键安装全链路与 novel 型 DSL 解析。',
        'baseUrl': base,
        'headers': const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        'searchUrl': '$base/modules/article/search.php?searchkey={keyword}',
        'search': {
          'css': 'table#novelist tr.grid',
          'name': 'td a|text',
          'id': 'td a|href',
        },
        'categoriesUrl': '$base/catindex.html',
        'categories': {
          'css': 'div.nav a',
          'itemName': 'text',
          'itemUrl': 'href',
        },
        'categoryListUrl': '$base/cat/{categoryId}.html',
        'categoryList': {
          'css': 'ul.booklist li',
          'name': 'a|text',
          'id': 'a|href',
        },
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.book-title',
          'description': 'p.info',
          'chapters': 'div.listmain dd a',
          'chapterUrl': 'href',
          'picListUrl': '$base/{id}',
          'picListCss': 'div#content p',
        },
      });

  test('def.validate() 通过', () {
    expect(def().validate(), isEmpty);
  });

  test('search 解析书名与 id', () async {
    final src = DslNovelSource(def());
    final items = await src.search('试', 1);
    expect(items.length, 2);
    expect(items[0].name, '『试』之试');
    expect(items[0].id, '8/8123/');
  });

  test('detail 解析章节列表', () async {
    final src = DslNovelSource(def());
    final d = await src.detail('8/8123/');
    expect(d.name, '试字之书');
    expect(d.description, '这是简介');
    expect(d.chapters.length, 3);
    expect(d.chapters[0].title, '第一章 起点');
    expect(d.chapters[0].id, '8/8123/8123001.html');
    expect(d.chapters[2].title, '第三章 结局');
  });

  test('chapterContent 解析正文段落', () async {
    final src = DslNovelSource(def());
    final c = await src.chapterContent('8/8123/8123001.html');
    expect(c.paragraphs.length, 2);
    expect(c.paragraphs[0], '第一段正文。');
    expect(c.paragraphs[1], '第二段正文。');
  });

  test('categories 解析分类导航', () async {
    final src = DslNovelSource(def());
    final cats = await src.categories();
    expect(cats.length, 3);
    expect(cats[0].name, '玄幻');
    expect(cats[0].id, 'xuanhuan');
    expect(cats[2].name, '科幻');
  });

  test('listByCategory 按分类拉小说列表', () async {
    final src = DslNovelSource(def());
    final items = await src.listByCategory('xuanhuan', 1);
    expect(items.length, 2);
    expect(items[0].name, '斗破苍穹');
    expect(items[0].id, '12/1201/');
  });
}
