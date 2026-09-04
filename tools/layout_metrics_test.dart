import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/bookshelf_page.dart';
import 'package:xingmanxia/ui/home_page.dart';
import 'package:xingmanxia/ui/profile_page.dart';
import 'package:xingmanxia/ui/toolbox_page.dart';

/// 临时几何测量（不留在仓库）：在真实断点尺寸下量四页面的
/// 字号分布 / 最小可点击区域短边 / 布局异常，结果打印到 stdout。
/// 运行：flutter test test/tmp_layout_metrics_test.dart
void main() {
  setUpAll(() {
    HttpOverrides.global = _EmptyHttpOverrides();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_metrics').path;
        }
        return null;
      },
    );
  });

  void report(WidgetTester tester, String tag, double w) {
    final fonts = <double, int>{};
    final tapSizes = <double>[];
    final tiny = <String>[];
    var textNodes = 0;

    final elements = <Element>[];
    void walk(Element e) {
      elements.add(e);
      e.visitChildren((child) => walk(child));
    }

    final Element? root = WidgetsBinding.instance.rootElement;
    if (root != null) walk(root);

    for (final el in elements) {
      Object? ro;
      try {
        ro = el.renderObject;
      } catch (_) {
        continue;
      }
      if (ro is! RenderBox) continue;
      final box = ro as RenderBox;
      final size = box.size;
      final wn = el.widget;
      final typeName = wn.runtimeType.toString();

      if (wn is RichText) {
        textNodes++;
        try {
          final dynamic span = wn.text;
          final TextStyle? st = span.style;
          final double? fs = st?.fontSize;
          if (fs != null) {
            fonts[fs] = (fonts[fs] ?? 0) + 1;
          }
        } catch (_) {}
      }

      final bool isTap = (wn is GestureDetector && wn.onTap != null) ||
          (wn is IconButton) ||
          typeName.contains('PressableScale') ||
          typeName.contains('HoverEffect') ||
          typeName.contains('InkWell');
      if (isTap && size.shortestSide > 0) {
        tapSizes.add(size.shortestSide);
        if (size.shortestSide < 44.0) {
          tiny.add('$typeName ${size.width.toStringAsFixed(0)}x'
              '${size.height.toStringAsFixed(0)}');
        }
      }
    }

    final fl = fonts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final uniq = <String, int>{};
    for (final s in tiny) {
      uniq[s] = (uniq[s] ?? 0) + 1;
    }
    tapSizes.sort();

    print('M[$tag] w=$w textNodes=$textNodes tapNodes=${tapSizes.length}');
    print('M[$tag] fonts=${fl.map((e) => "${e.key}x${e.value}").join(" ")}');
    print('M[$tag] minTapShortestSide='
        '${tapSizes.isEmpty ? "n/a" : tapSizes.first.toStringAsFixed(1)} '
        'p25=${tapSizes.isEmpty ? "n/a" : tapSizes[(tapSizes.length * 0.25).floor()].toStringAsFixed(1)}');
    print('M[$tag] under44=${tiny.length}/${tapSizes.length} '
        '${uniq.entries.take(16).map((e) => "${e.key}*${e.value}").join(" ; ")}');
    print('M[$tag] exception=${tester.takeException()}');
  }

  Future<void> pump(WidgetTester tester, Widget page, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(debugShowCheckedModeBanner: false, home: page),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  }

  final cases = <List<Object>>[
    ['home-390', const HomePage(), const Size(390, 844)],
    ['shelf-390', const BookshelfPage(), const Size(390, 844)],
    ['tools-390', const ToolboxPage(), const Size(390, 844)],
    ['profile-390', const ProfilePage(), const Size(390, 844)],
    ['home-960', const HomePage(), const Size(960, 540)],
    ['shelf-960', const BookshelfPage(), const Size(960, 540)],
    ['tools-960', const ToolboxPage(), const Size(960, 540)],
    ['profile-960', const ProfilePage(), const Size(960, 540)],
    ['profile-1280', const ProfilePage(), const Size(1280, 800)],
  ];

  for (final c in cases) {
    final tag = c[0] as String;
    final page = c[1] as Widget;
    final size = c[2] as Size;
    testWidgets('几何 $tag', (t) async {
      await pump(t, page, size);
      report(t, tag, size.width);
    });
  }
}

class _EmptyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _EmptyClient();
}

class _EmptyClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _EmptyRequest();
  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _EmptyRequest();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _EmptyRequest();
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) {
      if (invocation.memberName.toString().contains('close')) return null;
      return Future.value(_EmptyRequest());
    }
    return null;
  }
}

class _EmptyHeaders implements HttpHeaders {
  final Map<String, String> _v = {};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _v[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _v[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _EmptyRequest implements HttpClientRequest {
  final HttpHeaders _headers = _EmptyHeaders();
  @override
  HttpHeaders get headers => _headers;
  @override
  void write(Object? object) {}
  @override
  Future<HttpClientResponse> close() async => _EmptyResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _EmptyResponse implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => 0;
  @override
  HttpHeaders get headers => _EmptyHeaders();
  @override
  Stream<List<int>> asStream() => const Stream<List<int>>.empty();
  @override
  Future<S> fold<S>(S initial, S Function(S, List<int>) combine) async =>
      initial;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
