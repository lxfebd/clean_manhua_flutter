import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/dsl_video_source.dart';

/// 离线端到端验证：用本机 HTTP 服务器把 `j:\xiangm_transfer\xiangm\back\tmpprobe\live\`
/// 下存留的真实页面快照挂出去，跑完整链路
/// `listByCategory → detail → playUrl`。
///
/// 这样既复用了 [DslVideoSource] 的真实 `_fetch`/`_extract`/`_transformId`，
/// 又完全不依赖外部网络（16dns 与 dainyew 当前都对本机强制断连）。
late Directory _snap;
late String _base;
late HttpServer _server;

Directory _findSnapshots() {
  final root = Directory.current.absolute;
  final candidates = [
    Directory(r'j:\xiangm_transfer\xiangm\back\tmpprobe\live'),
    Directory('${root.path}\\..\\tmpprobe\\live'),
    Directory('tmpprobe\\live'),
  ];
  for (final c in candidates) {
    if (c.existsSync()) return c;
  }
  throw StateError('snapshots not found');
}

void _serve(HttpRequest req, String file) {
  final p = File('${_snap.path}\\$file');
  if (!p.existsSync()) {
    req.response.statusCode = 404;
    req.response.write('missing snapshot: $file');
    req.response.close();
    return;
  }
  req.response.headers.contentType = ContentType.html;
  req.response.write(p.readAsStringSync());
  req.response.close();
}

/// 16dns 源定义（与 sources/wche_dm.json 保持同步）。
CustomSourceDef _wche() => CustomSourceDef.fromJson({
      'id': 'wche_dm',
      'name': '风车动漫',
      'type': 'video',
      'version': '1.0.0',
      'author': 'test',
      'baseUrl': _base,
      'headers': const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
      'categoryListUrl': '$_base/html/{categoryId}-{page}.html',
      'categoryList': {
        'css': 'a.stui-vodlist__thumb[data-original]',
        'id': 'href',
        'name': 'title',
        'pic': 'data-original',
      },
      'detailUrl': '$_base/{id}',
      'detail': {
        'title': 'h1.title',
        'titleRe': r'^(.*?\S)\s*\d{1,2}\.\d$',
        'cover': 'div.stui-content__thumb img',
        'coverAttr': 'data-original',
        'description': 'p.desc',
        'chaptersRe':
            r'<a[^>]*href="(?<href>/co_e/\d+-(?<season>\d+)-\d+\.html)"[^>]*>(?!立即播放)(?<title>[^<]+)</a>',
        'idRegex': r'166(?<id>\d+)',
        'picListUrl': '$_base/co_e/{id}-0-{episode}.html',
        'picListRe': r'var\s+now="([^"]+)"',
      },
    });

/// dainyew 源定义（与 sources/ashan_yy.json 保持同步）。
CustomSourceDef _ashan() => CustomSourceDef.fromJson({
      'id': 'ashan_yy',
      'name': '鞍山影院',
      'type': 'video',
      'version': '1.0.0',
      'author': 'test',
      'baseUrl': _base,
      'headers': const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
      'categoryListUrl': '$_base/listnew/{categoryId}-{page}.html',
      'categoryList': {
        'css': 'div.ewave-vodlist__thumb[data-original]',
        'id': 'a.thumb-link|href',
        'name': 'title',
        'pic': 'data-original',
      },
      'detailUrl': '$_base/{id}',
      'detail': {
        'title': 'h1.title',
        'titleRe': r'^(.*?\S)\s*\d{1,2}\.\d$',
        'cover': 'div.ewave-content__thumb img',
        'coverAttr': 'data-original',
        'description': 'p.desc',
        'chaptersRe':
            r'<a[^>]*href="(?<href>/tvplay/\d+-(?<season>\d+)-(?<ep>\d+)\.html)"[^>]*>(?<title>[^<]+)</a>',
        'idRegex': r'(?<id>\d+)',
        'picListUrl': '$_base/tvplay/{id}-{season}-{episode}.html',
        'picListRe': r'"url":"([^"]+)"',
        'picReplace': {r'\/': '/'},
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_dsl_live').path;
        }
        return null;
      },
    );
    _snap = _findSnapshots();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _base = 'http://${_server.address.address}:${_server.port}';
    _server.listen((req) {
      final path = req.uri.path;
      // 16dns（快照对应用例 videoId=16613410，playId=13410）
      if (path == '/html/1666-1.html') {
        _serve(req, 'wc_list.html');
      } else if (path == '/fcdm/16613410.html') {
        _serve(req, 'wc_detail.html');
      } else if (path.startsWith('/co_e/13410-0-')) {
        _serve(req, 'wc_play.html');
      }
      // dainyew
      else if (path == '/listnew/26-1.html') {
        _serve(req, 'ay_list.html');
      } else if (path == '/pptv/1230130.html') {
        _serve(req, 'ay_detail_pptv.html');
      } else if (path.startsWith('/tvplay/1230130-')) {
        _serve(req, 'ay_play_pptv.html');
      } else {
        req.response.statusCode = 404;
        req.response.write('not found: $path');
        req.response.close();
      }
    });
  });

  tearDownAll(() async {
    await _server.close(force: true);
  });

  // 16dns: 分类列表条目 > 0，id 与 title 正确抽出。
  test('wche_dm 16dns list page parses cards', () async {
    final src = DslVideoSource(_wche());
    final items = await src.listByCategory('1666', 1);
    expect(items.length, greaterThan(0));
    final first = items.first;
    expect(first.id, startsWith('fcdm/'));
    expect(first.id, endsWith('.html'));
    expect(first.name, isNotEmpty);
    expect(first.name.contains('&#'), isFalse,
        reason: '标题不应残留 HTML 实体');
    expect(first.pic, startsWith('http'),
        reason: '封面应已补全为绝对地址，实际：${first.pic}');
  });

  test('wche_dm 16dns detail cleans rating and parses episodes', () async {
    final src = DslVideoSource(_wche());
    final d = await src.detail('fcdm/16613410.html');
    // h1 尾部有评分 span，必须被 titleRe 剥离。
    expect(RegExp(r'\d+\.\d+$').hasMatch(d.video.name), isFalse,
        reason: '标题不应以评分数字结尾，实际：${d.video.name}');
    expect(d.video.name, contains('泡在我家'),
        reason: '标题应包含剧集主体词，实际：${d.video.name}');
    // 16dns 剧集号 0 基（-0-0 即第 01 集）
    expect(d.episodes, isNotEmpty);
    expect(d.episodes.first.episode, isZero);
    // 「立即播放」按钮 href 与第 0 集相同但必须被负向前瞻排除：
    // 第 0 集标题应保留站点给的原文（如「第01集」）而非「立即播放」。
    final labels = d.episodes.map((e) => e.title).toList();
    expect(labels.contains('立即播放'), isFalse,
        reason: '「立即播放」按钮必须被排除，实际剧集：$labels');
  });

  test('wche_dm 16dns playUrl strips 166 prefix and pulls m3u8', () async {
    final src = DslVideoSource(_wche());
    final url = await src.playUrl('fcdm/16613410.html', 0, 0);
    expect(url, startsWith('https://'),
        reason: '应补全为绝对 URL，实际：$url');
    expect(url.contains('.m3u8'), isTrue,
        reason: '应返回 m3u8 直链，实际：$url');
    // 服务器只响应 `/co_e/13410-0-0.html`，命中即证明 idRegex 已把
    // 详情 id 的 `166` 前缀剥掉。若前缀未剥离，请求会是 `/co_e/16613410-...`
    // 并 404，测试就会在上一行断言失败。
  });

  // dainyew: 列表页用 HTML 数字实体转义中文，htmlUnescape 必须介入。
  test('ashan_yy dainyew list decodes numeric entities', () async {
    final src = DslVideoSource(_ashan());
    final items = await src.listByCategory('26', 1);
    expect(items.length, greaterThan(0));
    for (final it in items.take(3)) {
      expect(it.name.contains('&#'), isFalse,
          reason: '标题不应残留 HTML 数字实体，实际：${it.name}');
      expect(it.name.trim(), isNotEmpty);
    }
    expect(items.first.id, startsWith('pptv/'));
  });

  test('ashan_yy dainyew detail cleans rating and expands multi-season',
      () async {
    final src = DslVideoSource(_ashan());
    final d = await src.detail('pptv/1230130.html');
    // 标题应剥离尾部评分（如「片名 5.0」→「片名」）
    expect(RegExp(r'\d+\.\d+$').hasMatch(d.video.name), isFalse,
        reason: '标题不应以评分数字结尾，实际：${d.video.name}');
    // 站点用 /tvplay/{id}-{season}-{ep}.html 承载多线路，
    // chaptersRe 的 season 命名组应把多组剧集正确展开。
    expect(d.episodes, isNotEmpty);
  });

  test('ashan_yy dainyew playUrl unescapes backslashes in m3u8', () async {
    final src = DslVideoSource(_ashan());
    final url = await src.playUrl('pptv/1230130.html', 1, 1);
    // player_aaaa 里的斜杠被转义为 \/，picReplace 应还原成正常路径。
    expect(url.contains(r'\/'), isFalse,
        reason: '不应残留转义斜杠，实际：$url');
    expect(url.contains('.m3u8'), isTrue,
        reason: '应返回 m3u8 直链，实际：$url');
  });
}
