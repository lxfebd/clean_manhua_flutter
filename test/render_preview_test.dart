import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/bookshelf_page.dart';
import 'package:xingmanxia/ui/home_page.dart';
import 'package:xingmanxia/ui/main_shell.dart';
import 'package:xingmanxia/ui/profile_page.dart';

/// 真实 Flutter 引擎离屏渲染预览：多尺寸生成 PNG，供人工核验多端适配效果。
/// 运行：flutter test --update-goldens test/render_preview_test.dart
/// 输出：test/preview/*.png（核对后可删本测试文件，PNG 保留给人工看）。
///
/// 默认跳过：没有 golden 基线时它会让每次 `flutter test` 误报红。
/// 需要出图时临时把 _skipPreview 改成 false，并加 --update-goldens 运行。
const bool _skipPreview = true;
void main() {
  setUpAll(() {
    // 1) 网络打桩：所有 HttpClient 返回空 200 响应，页面以空数据渲染，无真实请求/定时器。
    HttpOverrides.global = _EmptyHttpOverrides();
    // 2) path_provider 打桩：LocalStore 落到临时目录，页面正常加载（不再无限 loading）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_preview').path;
        }
        return null;
      },
    );
  });

  Future<void> pumpAt(
      WidgetTester tester, Widget widget, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(debugShowCheckedModeBanner: false, home: widget),
    );
    // 让入场动画 + 网络失败/重试退避全部落定，再出图
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  }

  testWidgets('主框架 手机 390x844', (t) async {
    await pumpAt(t, const MainShell(), const Size(390, 844));
    await expectLater(
        find.byType(MainShell), matchesGoldenFile('preview/main_390.png'));
  }, skip: _skipPreview);

  testWidgets('主框架 小平板 720x900', (t) async {
    await pumpAt(t, const MainShell(), const Size(720, 900));
    await expectLater(
        find.byType(MainShell), matchesGoldenFile('preview/main_720.png'));
  }, skip: _skipPreview);

  testWidgets('主框架 平板 1024x900', (t) async {
    await pumpAt(t, const MainShell(), const Size(1024, 900));
    await expectLater(
        find.byType(MainShell), matchesGoldenFile('preview/main_1024.png'));
  }, skip: _skipPreview);

  testWidgets('主框架 桌面 1440x900', (t) async {
    await pumpAt(t, const MainShell(), const Size(1440, 900));
    await expectLater(
        find.byType(MainShell), matchesGoldenFile('preview/main_1440.png'));
  }, skip: _skipPreview);

  testWidgets('主框架 超宽 1920x1080', (t) async {
    await pumpAt(t, const MainShell(), const Size(1920, 1080));
    await expectLater(
        find.byType(MainShell), matchesGoldenFile('preview/main_1920.png'));
  }, skip: _skipPreview);

  testWidgets('首页 平板 1024x900（源切换 + 头部）', (t) async {
    await pumpAt(t, const HomePage(), const Size(1024, 900));
    await expectLater(
        find.byType(HomePage), matchesGoldenFile('preview/home_1024.png'));
  }, skip: _skipPreview);

  testWidgets('首页 桌面 1440x900', (t) async {
    await pumpAt(t, const HomePage(), const Size(1440, 900));
    await expectLater(
        find.byType(HomePage), matchesGoldenFile('preview/home_1440.png'));
  }, skip: _skipPreview);

  testWidgets('我的 平板 1024x900（两栏布局）', (t) async {
    await pumpAt(t, const ProfilePage(), const Size(1024, 900));
    await expectLater(
        find.byType(ProfilePage), matchesGoldenFile('preview/profile_1024.png'));
  }, skip: _skipPreview);

  testWidgets('我的 桌面 1440x900', (t) async {
    await pumpAt(t, const ProfilePage(), const Size(1440, 900));
    await expectLater(
        find.byType(ProfilePage), matchesGoldenFile('preview/profile_1440.png'));
  }, skip: _skipPreview);

  testWidgets('书架 桌面 1440x900（网格列数）', (t) async {
    await pumpAt(t, const BookshelfPage(), const Size(1440, 900));
    await expectLater(find.byType(BookshelfPage),
        matchesGoldenFile('preview/bookshelf_1440.png'));
  }, skip: _skipPreview);
}

/// 使所有 HttpClient 返回「空 200 响应」：不产生任何异常/重试定时器，
/// 页面以空数据/空态渲染，纯看布局适配（不做内容验证）。
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
      // connectionFactory 等返回 Future 的工厂：返回空请求即可
      if (invocation.memberName.toString().contains('close')) return null;
      return Future.value(_EmptyRequest());
    }
    return null;
  }
}

class _FakeHttpHeaders implements HttpHeaders {
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
  final HttpHeaders _headers = _FakeHttpHeaders();
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
  HttpHeaders get headers => _FakeHttpHeaders();
  Stream<List<int>> asStream() => const Stream<List<int>>.empty();
  @override
  Future<S> fold<S>(S initialValue, S Function(S, List<int>) combine) async =>
      initialValue;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
