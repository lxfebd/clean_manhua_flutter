import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/custom_source_store.dart';
import 'package:xingmanxia/sources/dsl/dsl_novel_source.dart';
import 'package:xingmanxia/sources/dsl/dsl_video_source.dart';
import 'package:xingmanxia/sources/source_manager.dart';

/// 回归：video / novel 两种 DSL 自定义源。
///
/// 用本机 HTTP 服务器模拟一个「动漫站」和一个「小说站」，验证：
/// - DslVideoSource：search 搜索列表、detail 剧集列表、playUrl 播放地址。
/// - DslNovelSource：search 列表、detail 章节目录、chapterContent 正文段落。
/// - CustomSourcePlugin.bind 会把 video/novel 分别注册进 SourceManager。
///
/// 本文件不入库（见 .gitignore /test/regression_*_test.dart）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_dsl_av').path;
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
      req.response.headers.contentType = ContentType.html;
      // ---- 动漫站 ----
      if (path == '/search') {
        req.response.write('''
        <html><body>
          <ul class="vod-list">
            <li class="vod-item"><a class="nm" href="/bangumi/111.html">测试番剧A</a><img src="/cover/a.jpg"></li>
            <li class="vod-item"><a class="nm" href="/bangumi/222.html">测试番剧B</a><img src="/cover/b.jpg"></li>
          </ul>
        </body></html>''');
      } else if (path == '/bangumi/111.html') {
        req.response.write('''
        <html><body>
          <h1 class="v-title">测试番剧A</h1>
          <div class="v-desc">这是番剧简介</div>
          <div class="v-info"><span class="v-area">日本</span><span class="v-type">TV</span></div>
          <div class="ep-list">
            <a href="/play/111/1.html">第1集</a>
            <a href="/play/111/2.html">第2集</a>
            <a href="/play/111/3.html">第3集</a>
          </div>
        </body></html>''');
      } else if (path == '/play/111/2.html') {
        req.response.write('''
        <html><body>
          <div class="player"><iframe src="https://parser.example/play?vid=111&ep=2"></iframe></div>
        </body></html>''');
        // ---- 小说站 ----
      } else if (path == '/nsearch') {
        req.response.write('''
        <html><body>
          <ul class="n-list">
            <li><a href="/book/1001/">测试小说甲</a><img src="/cov/x.jpg"></li>
            <li><a href="/book/1002/">测试小说乙</a><img src="/cov/y.jpg"></li>
          </ul>
        </body></html>''');
      } else if (path == '/book/1001/') {
        req.response.write('''
        <html><body>
          <h1 class="n-title">测试小说甲</h1>
          <div class="n-desc">小说简介</div>
          <div class="c-list">
            <a href="/book/1001/1.html">第一章</a>
            <a href="/book/1001/2.html">第二章</a>
          </div>
        </body></html>''');
      } else if (path == '/book/1001/1.html') {
        req.response.write('''
        <html><body>
          <div id="content">
            <p>第一段正文。</p>
            <p>第二段正文。</p>
          </div>
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

  CustomSourceDef videoDef() => CustomSourceDef.fromJson({
        'id': 'av_test_video',
        'name': '测试动漫源',
        'type': 'video',
        'version': '1.0.0',
        'author': 't',
        'baseUrl': base,
        'searchUrl': '$base/search?wd={keyword}&page={page}',
        'search': {
          'css': 'ul.vod-list li.vod-item',
          'name': 'a.nm|text',
          'id': 'a|href',
          'url': 'a|href',
          'pic': 'img|src',
        },
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.v-title',
          'description': 'div.v-desc',
          'type': 'span.v-type',
          'area': 'span.v-area',
          'chapters': 'div.ep-list a',
          // 播放页规则：{id}=视频路径 id，{episode}=集号。
          // 站内实际结构为 /play/{videoId}/{ep}.html，这里用 {episode} 显式拼。
          'picListUrl': '$base/play/111/{episode}.html',
          'picListCss': '.player iframe',
          'picAttr': 'src',
        },
      });

  CustomSourceDef novelDef() => CustomSourceDef.fromJson({
        'id': 'av_test_novel',
        'name': '测试小说源',
        'type': 'novel',
        'version': '1.0.0',
        'author': 't',
        'baseUrl': base,
        'searchUrl': '$base/nsearch?q={keyword}',
        'search': {
          'css': 'ul.n-list li',
          'name': 'a|text',
          'id': 'a|href',
          'url': 'a|href',
          'pic': 'img|src',
        },
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.n-title',
          'description': 'div.n-desc',
          'chapters': 'div.c-list a',
          'picListUrl': '$base/{id}',
          'picListCss': '#content p',
        },
      });

  group('DslVideoSource (CSS 规则)', () {
    test('search 解析列表', () async {
      final src = DslVideoSource(videoDef());
      final items = await src.search('测试', 1);
      expect(items.length, 2);
      expect(items[0].name, '测试番剧A');
      expect(items[0].id, 'bangumi/111.html');
      expect(items[0].pic, '$base/cover/a.jpg');
      expect(items[1].name, '测试番剧B');
    });

    test('detail 解析剧集列表与元信息', () async {
      final src = DslVideoSource(videoDef());
      final d = await src.detail('bangumi/111.html');
      expect(d.video.name, '测试番剧A');
      expect(d.description, '这是番剧简介');
      expect(d.episodes.length, 3);
      expect(d.episodes[0].episode, 1);
      expect(d.episodes[0].title, '第1集');
      expect(d.episodes[2].episode, 3);
      expect(d.area, '日本');
      expect(d.type, 'TV');
    });

    test('playUrl 解析播放地址（iframe 解析器链接）', () async {
      final src = DslVideoSource(videoDef());
      final url = await src.playUrl('bangumi/111.html', 1, 2);
      expect(url.contains('parser.example'), isTrue);
      expect(url.contains('ep=2'), isTrue);
    });
  });

  group('DslNovelSource (CSS 规则)', () {
    test('search 解析列表', () async {
      final src = DslNovelSource(novelDef());
      final items = await src.search('测试', 1);
      expect(items.length, 2);
      expect(items[0].name, '测试小说甲');
      expect(items[0].id, 'book/1001/');
      expect(items[0].pic, '$base/cov/x.jpg');
    });

    test('detail 解析章节目录', () async {
      final src = DslNovelSource(novelDef());
      final d = await src.detail('book/1001/');
      expect(d.name, '测试小说甲');
      expect(d.description, '小说简介');
      expect(d.chapters.length, 2);
      expect(d.chapters[0].title, '第一章');
      expect(d.chapters[1].id, 'book/1001/2.html');
    });

    test('chapterContent 解析正文段落', () async {
      final src = DslNovelSource(novelDef());
      final c = await src.chapterContent('book/1001/1.html');
      expect(c.paragraphs.length, 2);
      expect(c.paragraphs.first, '第一段正文。');
      expect(c.paragraphs[1], '第二段正文。');
    });
  });

  group('章节正则（chaptersRe，含命名组）', () {
    test('DslVideoSource 用 chaptersRe 解析剧集', () async {
      final def = CustomSourceDef.fromJson({
        'id': 'av_re_video',
        'name': '正则视频源',
        'type': 'video',
        'version': '1.0.0',
        'author': 't',
        'baseUrl': base,
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.v-title',
          'chaptersRe':
              r'<a href="/play/\d+/(?<ep>\d+)\.html"[^>]*>(?<title>[^<]+)</a>',
          'picListUrl': '$base/{id}',
          'picListRe': r'<iframe[^>]+src="([^"]+)"',
        },
      });
      final src = DslVideoSource(def);
      final d = await src.detail('bangumi/111.html');
      expect(d.episodes.length, 3);
      expect(d.episodes[0].title, '第1集');
      expect(d.episodes[2].episode, 3);
    });

    test('DslNovelSource 用 chaptersRe 解析章节', () async {
      final def = CustomSourceDef.fromJson({
        'id': 'av_re_novel',
        'name': '正则小说源',
        'type': 'novel',
        'version': '1.0.0',
        'author': 't',
        'baseUrl': base,
        'detailUrl': '$base/{id}',
        'detail': {
          'title': 'h1.n-title',
          'chaptersRe':
              r'<a href="/book/1001/(?<href>\d+\.html)">(?<title>[^<]+)</a>',
          'picListUrl': '$base/{id}',
          'picListCss': '#content p',
        },
      });
      final src = DslNovelSource(def);
      final d = await src.detail('book/1001/');
      expect(d.chapters.length, 2);
      expect(d.chapters[0].title, '第一章');
      expect(d.chapters[1].title, '第二章');
    });
  });

  group('CustomSourcePlugin.bind 类型分发', () {
    test('video 源注册进 SourceManager、novel 源注册进 novelSources', () async {
      final videoId = 'av_plugin_video';
      final novelId = 'av_plugin_novel';
      final vp = CustomSourcePlugin(
          CustomSourceDef.fromJson({...videoDef().toJson(), 'id': videoId}));
      final np = CustomSourcePlugin(
          CustomSourceDef.fromJson({...novelDef().toJson(), 'id': novelId}));

      await vp.bind();
      await np.bind();
      try {
        expect(SourceManager.videoSources.any((s) => s.id == videoId), isTrue);
        expect(SourceManager.novelSources.any((s) => s.id == novelId), isTrue);
        // novelById 对未知名回退第一个源，改用 any 判断注册语义
      } finally {
        await vp.unbind();
        await np.unbind();
      }
      expect(SourceManager.videoSources.any((s) => s.id == videoId), isFalse);
      expect(SourceManager.novelSources.any((s) => s.id == novelId), isFalse);
    });
  });
}