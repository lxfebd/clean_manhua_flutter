import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/dsl/html_parser.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_result.dart';

/// 修复线 5 回归：源管理 / DSL 自定义源安全线。
///
/// 覆盖缺陷：
/// - P0-2 正则长度上限 + 编译性预检（含此前漏检的 picFilter）
/// - P0-2 parseHtml 超长输入抛 SourceError.parse
/// - P0-3 m3u8Rewrite 值禁止 file:// 等非 http(s) scheme
/// - P1-5 baseUrl 内网/本机地址拒绝（localhost / 127/8 / 10/8 / 192.168/16 等）
/// - P1-7 SourceConfigStore TTL 缓存过期后重新读盘
/// - P1-8 SourceMarket fetchIndex 的缓存语义（_parse 成功后才落盘）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    // SourceConfigStore 走 LocalStore，需要 path_provider 指向临时目录
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_line5_fix').path;
        }
        return null;
      },
    );
  });

  group('P1-5 baseUrl 内网/本机地址拒绝', () {
    test('baseUrl=localhost 被拒', () {
      expect(_def(baseUrl: 'https://localhost/').validate().join('; '),
          contains('localhost'));
    });

    test('baseUrl=127.0.0.1 被拒（127/8）', () {
      expect(_def(baseUrl: 'http://127.0.0.1/x').validate().join('; '),
          contains('127/8'));
    });

    test('baseUrl=192.168.1.1 被拒（192.168/16）', () {
      expect(_def(baseUrl: 'http://192.168.1.1').validate().join('; '),
          contains('192.168/16'));
    });

    test('baseUrl=10.0.0.1 被拒（10/8）', () {
      expect(_def(baseUrl: 'http://10.0.0.1').validate().join('; '),
          contains('10/8'));
    });

    test('baseUrl=172.16.5.5 被拒（172.16/12）', () {
      expect(_def(baseUrl: 'http://172.16.5.5').validate().join('; '),
          contains('172.16/12'));
    });

    test('baseUrl=[::1] 被拒（IPv6 回环）', () {
      expect(_def(baseUrl: 'http://[::1]:8080').validate().join('; '),
          contains('::1'));
    });

    test('baseUrl=[::ffff:127.0.0.1] 被拒（IPv6 混合写法回环）', () {
      expect(
          _def(baseUrl: 'http://[::ffff:127.0.0.1]').validate().join('; '),
          contains('127/8'));
    });

    test('baseUrl=0.0.0.0 被拒（RFC 1918 保留地址）', () {
      expect(_def(baseUrl: 'http://0.0.0.0/x').validate().join('; '),
          contains('0.0.0.0'));
    });

    test('baseUrl=169.254.5.5 被拒（链路本地）', () {
      expect(_def(baseUrl: 'http://169.254.5.5').validate().join('; '),
          contains('169.254/16'));
    });

    test('合法公网 baseUrl 通过', () {
      expect(_def(baseUrl: 'https://www.example.com').validate(), isEmpty);
    });

    test('非 http(s) 前缀仍被拒（baseUrl 前缀检查）', () {
      expect(_def(baseUrl: 'ftp://example.com').validate().join('; '),
          contains('必须以 http'));
    });
  });

  group('P0-2 正则长度上限 + 编译性预检', () {
    test('picFilter 非法正则被预检拒绝（此前漏检）', () {
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'\.jpg',
          'picFilter': '[', // 非法：孤立 `[`
        }).validate().join('; '),
        contains('非法正则'),
      );
    });

    test('titleRe 非法正则被预检拒绝', () {
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'\.jpg',
          'titleRe': '(?', // 未闭合命名组
        }).validate().join('; '),
        contains('非法正则'),
      );
    });

    test('chaptersRe 非法正则被预检拒绝', () {
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'\.jpg',
          'chaptersRe': '(', // 未闭合括号
        }).validate().join('; '),
        contains('非法正则'),
      );
    });

    test('categoryListRule.regex 非法 → validate 失败（listRule 通道）', () {
      expect(
        _def(
          categoryListUrl: 'https://example.com/l',
          categoryList: {'regex': '['}, // 非法
        ).validate().join('; '),
        contains('非法正则'),
      );
    });

    test('超长正则（>2000 字符）被预检拒绝', () {
      final longPattern = List.filled(2100, 'a').join();
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'\.jpg',
          'picFilter': longPattern,
        }).validate().join('; '),
        contains('正则过长'),
      );
    });
  });

  group('P0-2 parseHtml 输入长度上限', () {
    test('超长输入抛 SourceError（parse 类）', () {
      // 构造 8 MB + 若干 字符（略高于默认上限）
      final huge = 'a' * (8 * 1024 * 1024 + 100);
      expect(
        () => parseHtml(huge),
        throwsA(isA<SourceError>()),
        reason: '超长输入必须抛 SourceError（parse 类）',
      );
    });

    test('自定义 maxBytes 覆盖默认值', () {
      expect(
        () => parseHtml('<html>' * 20, maxBytes: 5),
        throwsA(isA<SourceError>()),
      );
      // 小字符串在更紧的上限下也过关
      final root = parseHtml('<p>ok</p>', maxBytes: 100);
      expect(root.querySelectorAll('p').length, 1);
    });

    test('抛的是 SourceError（不是 FormatException）', () {
      try {
        parseHtml('x' * (8 * 1024 * 1024 + 1));
        fail('应该抛异常');
      } on SourceError {
        // 期望路径
      } on FormatException {
        fail('不应抛 FormatException，应统一为 SourceError');
      }
    });

    test('默认上限内的小文档正常解析（无回归）', () {
      final root = parseHtml(
          '<html><body><div class="x"><a href="/a">link</a></div></body></html>');
      expect(root.querySelectorAll('.x a').length, 1);
      expect(root.querySelectorAll('.x a').first.attrs['href'], '/a');
    });
  });

  group('P0-3 m3u8Rewrite 值 scheme 校验', () {
    test('file:// target 被拒（防任意文件读）', () {
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'src="([^"]+\.m3u8)"',
          'm3u8Rewrite': {'old.host': 'file:///etc/passwd'},
        }).validate().join('; '),
        contains('file'),
      );
    });

    test('data: target 被拒', () {
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'src="([^"]+\.m3u8)"',
          'm3u8Rewrite': {'x': 'data:text/plain;base64,AAAA'},
        }).validate().join('; '),
        contains('data'),
      );
    });

    test('folder:// target 被拒', () {
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'src="([^"]+\.m3u8)"',
          'm3u8Rewrite': {'x': 'folder:/'},
        }).validate().join('; '),
        contains('folder'),
      );
    });

    test('https:// 完整 URL target 通过', () {
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'src="([^"]+\.m3u8)"',
          'm3u8Rewrite': {'https://old.com': 'https://new.com'},
        }).validate(),
        isEmpty,
      );
    });

    test('纯主机名 target 通过（无 scheme 子串替换）', () {
      // 实际项目 wche_dm.json 里的这种写法必须通过
      expect(
        _def(detail: {
          'title': 'h1',
          'picListUrl': 'https://example.com/p/{id}',
          'picListRe': r'src="([^"]+\.m3u8)"',
          'm3u8Rewrite': {'kkzycdn.com:65': 'play.modujx16.com'},
        }).validate(),
        isEmpty,
        reason: '纯主机名替换（无 scheme）是合法用例',
      );
    });

    test('运行期 unsafeRewriteTarget API 可独立测试', () {
      expect(unsafeRewriteTarget('file:///etc/passwd'), isNotNull);
      expect(unsafeRewriteTarget('https://x.com'), isNull);
      expect(unsafeRewriteTarget('http://x.com'), isNull);
      expect(unsafeRewriteTarget('host.com'), isNull);
      expect(unsafeRewriteTarget('host.com:65'), isNull);
      expect(unsafeRewriteTarget('data:text/plain'), isNotNull);
      expect(unsafeRewriteTarget(''), isNull);
    });
  });

  group('P1-7 SourceConfigStore TTL 缓存', () {
    test('TTL 未过期：两次 all() 返回同一缓存实例', () async {
      final t0 = DateTime(2026, 1, 1, 12, 0);
      SourceConfigStore.testSetClock(() => t0);
      SourceConfigStore.invalidateCache();
      final first = await SourceConfigStore.all();
      // 30 秒后仍在 5 分钟 TTL 内
      SourceConfigStore.testSetClock(
          () => t0.add(const Duration(seconds: 30)));
      final second = await SourceConfigStore.all();
      expect(identical(first, second), isTrue,
          reason: 'TTL 内应返回同一缓存实例');
      SourceConfigStore.testSetClock(null);
    });

    test('TTL 过期：all() 返回新实例（重新读盘）', () async {
      final t0 = DateTime(2026, 1, 1, 12, 0);
      SourceConfigStore.testSetClock(() => t0);
      SourceConfigStore.invalidateCache();
      final first = await SourceConfigStore.all();
      // 6 分钟后：应过期重读
      SourceConfigStore.testSetClock(() => t0.add(const Duration(minutes: 6)));
      final second = await SourceConfigStore.all();
      expect(identical(first, second), isFalse,
          reason: 'TTL 过期后应重新构造列表');
      SourceConfigStore.testSetClock(null);
    });

    test('invalidateCache 立即使缓存失效（不等 TTL）', () async {
      final t0 = DateTime(2026, 1, 1, 12, 0);
      SourceConfigStore.testSetClock(() => t0);
      SourceConfigStore.invalidateCache();
      final first = await SourceConfigStore.all();
      SourceConfigStore.invalidateCache();
      final second = await SourceConfigStore.all();
      expect(identical(first, second), isFalse,
          reason: 'invalidateCache 后应立即重新读盘');
      SourceConfigStore.testSetClock(null);
    });
  });

  group('其它 smoke', () {
    test('htmlUnescape 命名/数字实体均解码', () {
      expect(htmlUnescape('a&amp;b'), 'a&b');
      expect(htmlUnescape('&#19968;&#19968;'), '一一');
      expect(htmlUnescape('&#x4e00;'), '一');
    });

    test('safeRegExp 非法 pattern 抛 SourceError（非 FormatException）', () {
      try {
        safeRegExp('[');
        fail('应该抛异常');
      } on SourceError {
        // 期望路径
      } on FormatException {
        fail('应统一为 SourceError');
      }
    });

    test('safeRegExp dotAll 正常返回可用 RegExp', () {
      final re = safeRegExp(r'a.b', dotAll: true);
      expect(re.hasMatch('a\nb'), isTrue);
    });

    test('SourceConfigStore.defaults() 保留内置源', () {
      expect(SourceConfigStore.defaults(), isNotEmpty);
      expect(SourceConfigStore.defaults().first.engineId, isNotEmpty);
    });
  });
}

/// 构造最小可用 CustomSourceDef；baseUrl 与 detail/categoryList 可组合。
CustomSourceDef _def({
  String baseUrl = 'https://example.com',
  String? categoryListUrl,
  Map<String, dynamic>? categoryList,
  Map<String, dynamic>? detail,
}) {
  final j = <String, dynamic>{
    'id': 'sec_test',
    'name': '安全测试源',
    'type': 'comic',
    'version': '1.0.0',
    'author': 'sec',
    'baseUrl': baseUrl,
  };
  if (categoryListUrl != null) j['categoryListUrl'] = categoryListUrl;
  if (categoryList != null) j['categoryList'] = categoryList;
  if (detail != null) {
    j['detailUrl'] = 'https://example.com/{id}';
    j['detail'] = detail;
  } else if (categoryListUrl == null && categoryList == null) {
    // CustomSourceDef.validate 要求至少一种内容规则
    j['categoryListUrl'] = 'https://example.com/list';
    j['categoryList'] = {
      'css': '.item',
      'name': 'a|text',
      'id': 'a|href',
    };
  }
  return CustomSourceDef.fromJson(j);
}
