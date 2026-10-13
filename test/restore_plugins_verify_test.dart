// 决定性端到端验证：
// 1) 把 sources/*.json 写到 LocalStore 目录的 custom_sources.json
// 2) 调用 CustomSourceStore.restorePlugins()
// 3) 断言 SourceManager.videoSources 出现 wche_dm 和 ashan_yy
// 用 flutter_test 跑（mock path_provider）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/dsl/custom_source_store.dart';
import 'package:xingmanxia/sources/source_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_restore_test');
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
    // 清静态目录缓存：测试环境里其他测试可能已把 LocalStore 指向真实
    // AppData，不清会读到真实 custom_sources（含旧版 wche_dm 变体）。
    LocalStore.resetForTest();
  });

  test('restorePlugins 从 custom_sources.json 注册两个自定义视频源', () async {
    // 写 LocalStore 数据目录：<support>/data/custom_sources.json
    final dataDir = Directory('${tmp.path}/data');
    dataDir.createSync(recursive: true);
    final wche = File('sources/wche_dm.json').readAsStringSync();
    final ashan = File('sources/ashan_yy.json').readAsStringSync();
    final combined = '[$wche,$ashan]';
    // 先校验 JSON 合法
    expect(() => jsonDecode(combined), returnsNormally, reason: '合并 JSON 必须合法');
    File('${dataDir.path}/custom_sources.json')
        .writeAsStringSync(combined, flush: true);

    // 清理可能残留的注册
    final before = SourceManager.videoSources.map((s) => s.id).toList();
    for (final id in ['wche_dm', 'ashan_yy']) {
      if (before.contains(id)) SourceManager.removeVideoSource(id);
    }

    await CustomSourceStore.restorePlugins();

    final ids = SourceManager.videoSources.map((s) => s.id).toList();
    // ignore: avoid_print
    print('videoSources ids: $ids');
    expect(ids, contains('wche_dm'), reason: '风车动漫必须被注册');
    // 鞍山影院有两份：内置 ashanyy（Dart 类）与市场 DSL 版 ashan_yy（下划线，
    // id 不同）。addVideoSource 的名称去重只作用于 builtinIds 内的 id，DSL 版
    // 不在其中，因此可正常注册——这里断言它确实被装上了。
    expect(ids, contains('ashan_yy'), reason: '鞍山影院（DSL 版）必须被注册');
    expect(ids, contains('ashanyy'), reason: '鞍山影院（内置版）应始终在册');
  });
}
