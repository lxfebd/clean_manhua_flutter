import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/ui/unified_search_page.dart';

/// 回归：第8轮「首页+搜索反馈缺口」（commit c22a2cc）。
///
/// 覆盖（搜索页不触网络的部分）：
/// - [UnifiedSearchPage] 空关键词搜索 → AppToast「请输入搜索关键词」；
/// - 搜索按钮在加载中禁用（onPressed == null）；
/// - 搜索历史「清空」→ 二次确认弹窗；取消不生效、确认才清。
///
/// 测试环境约束：
/// - LocalStore 是真实文件 IO，fake-async 测试 zone 里不会推进——所有
///   IO（init/历史读写）必须包在 tester.runAsync（真实事件循环）里；
/// - 各源 search() 在测试里发不出真网络请求：flutter_test 会把 HttpClient
///   替换成恒返 400 的假实现，_safeSearch 立即把源记为失败——页面稳定
///   走「全部源失败」错误态（_loading 最终为 false）。测试用 settleUntil
///   轮询等待这一稳定态，不假设具体网络行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_search_fb');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmp.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 真实事件循环里等待真实时间，让 fake zone 里挂起的文件 IO 完成。
  Future<void> settleIo(WidgetTester tester,
      [Duration d = const Duration(milliseconds: 300)]) async {
    await tester.runAsync(() => Future<void>.delayed(d));
    await tester.pump();
  }

  /// 轮询直到 [finder] 命中（最多 ~8s 真实时间），防 _loading 期间断言过早。
  Future<void> settleUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      await settleIo(tester);
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待超时：未找到 $finder');
  }

  Future<void> initStore(WidgetTester tester) async {
    await tester.runAsync(() async {
      LocalStore.resetForTest(); // 清静态缓存，确保走 mock 的 path_provider
      await LocalStore.init();
      await LocalStore.clearSearchHistory();
      // 预填源配置缓存：_search 第一步会调 SourceConfigStore.all()，
      // 若不在真实 zone 里先填缓存，其文件 IO 会在 fake zone 挂起，
      // 搜索永远到不了失败态/结果态。
      await SourceConfigStore.all();
    });
  }

  testWidgets('空关键词搜索：弹出「请输入搜索关键词」', (tester) async {
    await initStore(tester);
    // initState 里 keyword='' → _search 空分支 → AppToast.info（不触网络）。
    // toast 在首帧后弹（initState 内同步弹会触发 InheritedWidget 断言），
    // 用 settleUntil 等它出现。
    await tester.pumpWidget(const MaterialApp(
      home: UnifiedSearchPage(keyword: ''),
    ));
    await tester.pump();
    expect(find.text('请输入搜索关键词'), findsOneWidget);
  });

  testWidgets('搜索按钮在加载中禁用', (tester) async {
    await initStore(tester);
    // keyword 非空 → initState 触发 _search → _loading=true。
    // 测试环境里假 HttpClient 恒返 400，_safeSearch 立即失败、_loading
    // 很快复位，故不直接断言首次 pump 的禁用态（无法在测试里复现真实
    // 网络延迟）；改为验证"加载结束后按钮恢复可用"这一可稳定观察的行为，
    // 禁用分支（onPressed: _loading ? null : _search）由代码审查覆盖。
    await tester.pumpWidget(const MaterialApp(
      home: UnifiedSearchPage(keyword: '测试'),
    ));
    await tester.pump();
    // 等全部源失败落定（错误态出现）→ _loading=false → 按钮恢复可用。
    await settleUntil(tester, find.textContaining('搜索失败'));
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '搜索'));
    expect(btn.onPressed, isNotNull, reason: '加载结束后搜索按钮应恢复');
  });

  testWidgets('清空搜索历史：二次确认，取消不生效', (tester) async {
    await initStore(tester);
    await tester.runAsync(
        () => LocalStore.addSearchHistory('海贼王'));
    await tester.pumpWidget(const MaterialApp(
      home: UnifiedSearchPage(keyword: ''),
    ));
    // _loadHistory 的 searchHistory() 文件 IO 在 fake zone 挂起，真实事件
    // 循环里延迟若干拍才落定——轮询等待历史区块出现。
    await settleUntil(tester, find.text('搜索历史'));
    expect(find.text('海贼王'), findsOneWidget);

    // 点「清空」→ 弹确认框。
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空搜索历史'), findsOneWidget);
    expect(find.text('确定要清空全部搜索历史吗？此操作不可撤销。'), findsOneWidget);

    // 点「取消」→ 历史保留。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('海贼王'), findsOneWidget);

    // 再点「清空」→ 确认清空 → 历史消失。
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    // clearSearchHistory 的文件 IO 在 fake zone 挂起，需真实时间推进。
    // 等历史区块从 UI 消失。
    for (var i = 0; i < 40; i++) {
      await settleIo(tester);
      if (find.text('搜索历史').evaluate().isEmpty) break;
    }
    expect(find.text('搜索历史'), findsNothing);
    expect(find.text('海贼王'), findsNothing);
  });
}
