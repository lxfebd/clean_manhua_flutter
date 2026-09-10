import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/css_selector.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_comic_source.dart';
import 'package:xingmanxia/sources/dsl/html_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_dsl_test').path;
        }
        return null;
      },
    );
  });

  group('HTML 解析器', () {
    test('解析成对标签与文本', () {
      final root = parseHtml('<div><a href="/a">标题</a></div>');
      expect(root.children.length, 1);
      final div = root.children.first;
      expect(div.tag, 'div');
      expect(div.children.first.tag, 'a');
      expect(div.children.first.attrs['href'], '/a');
      expect(div.innerText.trim(), '标题');
    });

    test('自闭合标签与属性引号', () {
      final root = parseHtml(
          '<img src="x.png" data-id=\'7\' width=100><br><input disabled>');
      final imgs = root.querySelectorAll('img');
      expect(imgs.length, 1);
      expect(imgs.first.attrs['src'], 'x.png');
      expect(imgs.first.attrs['data-id'], '7');
      expect(imgs.first.attrs['width'], '100');
      expect(root.querySelectorAll('input').length, 1);
    });

    test('script 内容不污染选择器', () {
      final root = parseHtml(
          '<div class="a">正文<script>var x="<div class=\\"b\\">";</script></div>');
      expect(root.querySelectorAll('.b').length, 0);
      expect(root.querySelectorAll('.a').length, 1);
    });

    test('注释被跳过', () {
      final root = parseHtml('<!-- 注释 --><p>x</p>');
      expect(root.querySelectorAll('p').length, 1);
    });
  });

  group('CSS 选择器', () {
    test('标签/类/id/属性组合', () {
      final root = parseHtml(
          '<ul><li class="item" id="a"><a href="/x">x</a></li>'
          '<li class="item other" id="b"><a href="/y">y</a></li></ul>');
      expect(root.querySelectorAll('ul li').length, 2);
      expect(root.querySelectorAll('.item').length, 2);
      expect(root.querySelectorAll('#a').length, 1);
      expect(root.querySelectorAll('[href^="/y"]').length, 1);
      expect(root.querySelectorAll('li.item a[href]').length, 2);
    });

    test('不支持的选择器返回 null', () {
      expect(CssSelector.parse('a > b'), isNull);
      expect(CssSelector.parse(''), isNull);
      expect(CssSelector.parse(':hover'), isNull);
    });
  });

  group('解密链', () {
    test('base64 解码', () {
      final enc = base64Encode(utf8.encode('<div>hi</div>'));
      expect(DslDecrypt.apply('b64', enc), '<div>hi</div>');
    });

    test('replace 替换', () {
      expect(DslDecrypt.apply('replace:abc>xyz', 'xabcy'), 'xxyzy');
    });

    test('hex 解码', () {
      final hex = utf8.encode('AB').map((b) => b.toRadixString(16)).join();
      expect(DslDecrypt.apply('hex', hex), 'AB');
    });
  });

  group('CustomSourceDef', () {
    test('JSON 往返', () {
      final def = CustomSourceDef.fromJson({
        'id': 't1',
        'name': '测试源',
        'type': 'comic',
        'version': '1.0.0',
        'author': 'me',
        'baseUrl': 'https://example.com',
        'categoryListUrl': 'https://example.com/list/{page}.html',
        'categoryList': {
          'css': 'ul li',
          'name': 'a',
          'id': 'r1',
          'url': 'href',
          'pic': 'img',
        },
        'detail': {
          'title': 'h1',
          'chapters': 'a.ch',
          'picListUrl': 'https://example.com/ch/{id}.html',
          'picListCss': 'img',
        },
      });
      expect(def.validate(), isEmpty);
      final back = decodeCustomSourceDef(encodeCustomSourceDef(def))!;
      expect(back.id, 't1');
      expect(back.categoryListRule!.selector, 'ul li');
      expect(back.detailRule!.picListCss, 'img');
    });

    test('校验缺 baseUrl', () {
      final def = CustomSourceDef.fromJson({'id': 'x', 'name': 'x', 'baseUrl': ''});
      expect(def.validate(), isNotEmpty);
    });

    test('校验非法 type', () {
      final def = CustomSourceDef.fromJson({
        'id': 'x', 'name': 'x', 'type': 'music',
        'baseUrl': 'https://a.com',
      });
      expect(def.validate(), contains(anything));
    });
  });

  group('正则分支虚拟节点', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.address}:${server.port}';
      server.listen((req) {
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
        <html><body>
          <a class="title" href="/detail/b1.html">星漫匣测试漫画A</a>
          <a class="title" href="/detail/b2.html">测试漫画B</a>
        </body></html>''');
        req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('正则 search 规则能正常抽取（回归：attrs 不可修改 map 崩溃）', () async {
      final def = CustomSourceDef.fromJson({
        'id': 'rx',
        'name': '正则源',
        'type': 'comic',
        'version': '1.0.0',
        'author': 'me',
        'baseUrl': base,
        'searchUrl': '$base/search?keyword={keyword}',
        'search': {
          'regex': '<a class="title" href="/detail/([^/"]+)\\.html">([^<]+)</a>',
          'name': 'r2',
          'id': 'r1',
        },
      });
      final src = DslComicSource(def);
      final items = await src.search('星漫匣测试', 1);
      expect(items.length, 2);
      expect(items[0].name, '星漫匣测试漫画A');
      // 正则捕获组 r1 为裸 id（b1），由 detailUrl 模板自行拼成 /detail/{id}.html
      expect(items[0].id, 'b1');
      expect(items[1].name, '测试漫画B');
      expect(items[1].id, 'b2');
    });
  });
}