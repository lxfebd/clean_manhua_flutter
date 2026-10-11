import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_manager.dart';
import 'package:xingmanxia/sources/source_plugin.dart';
import 'package:xingmanxia/sources/source_plugin_manager.dart';

/// 测试用源：只区分 id，其余行为空实现（不联网）。
class OrderFakeSource extends ComicSource {
  final String id0;
  OrderFakeSource(this.id0);
  @override
  String get id => id0;
  @override
  String get name => 'fake-$id0';
  @override
  SourceTier get tier => SourceTier.primary;
  @override
  Future<List<Category>> categories() async => const [];
  @override
  Future<List<ComicItem>> listByCategory(String categoryId, int page) async =>
      const [];
  @override
  Future<List<ComicItem>> rank(int page) async => const [];
  @override
  Future<List<ComicItem>> search(String keyword, int page) async => const [];
  @override
  Future<ComicDetail> detail(String comicId) async =>
      ComicDetail(ComicItem(comicId, 'n', ''), []);
  @override
  Future<List<String>> chapterPics(String chapterId) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final added = <String>[];

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('xm_srcorder');
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
    // SourceConfigStore 走 LocalStore → 需要初始化到临时目录。
    // ignore: invalid_use_of_visible_for_testing_member
    LocalStore.resetForTest();
    await LocalStore.init();
  });

  tearDownAll(() async {
    for (final id in added) {
      SourceManager.removeSource(id);
    }
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('enabledSources：同 tier 按注册顺序稳定返回（n>32 快排不重排）', () async {
    // _enabledSorted 注释承诺「按注册顺序稳定」——Dart List.sort 对 >32
    // 元素走双枢轴快排不稳定：40 个同 tier 源若无显式 tie-break，
    // 同 tier 组内注册顺序会被打乱（实测 n=40/100 重排率 20/20）。
    final before = await SourceConfigStore.all();
    final byId = {for (final c in before) c.engineId: c};
    // 禁用内置漫画源，只留下面注册的 fake。
    for (final builtin in ['dm5', 'doubao', 'jm', 'mangadex']) {
      await SourceConfigStore.save(SourceConfig(
        engineId: builtin,
        id: byId[builtin]?.id ?? builtin,
        name: byId[builtin]?.name ?? builtin,
        isEnabled: false,
        tier: SourceTier.disabled,
      ));
    }
    SourceConfigStore.invalidateCache();
    addTearDown(() async {
      for (final c in before) {
        await SourceConfigStore.save(c);
      }
      SourceConfigStore.invalidateCache();
    });

    const n = 40; // >32 触发 Dart sort 快排路径
    for (var i = 0; i < n; i++) {
      final id = 'orderfake$i';
      SourceManager.addSource(OrderFakeSource(id));
      added.add(id);
    }

    final enabled = await SourceManager.enabledSources();
    final got = [for (final s in enabled) s.id];
    final expected = [for (var i = 0; i < n; i++) 'orderfake$i'];
    expect(got, expected,
        reason: '同 tier 必须保持注册顺序（注释契约：按注册顺序稳定）');
  });

  test('自定义源停用后从 enabledSources 移除（防配置变更后静默切回）', () async {
    final before = await SourceConfigStore.all();
    const id = 'orderfake';
    // 忠实路径：自定义源经插件注册表 install（bind 才把实现挂进 SourceManager），
    // 直接 addSource 会绕过注册表——那时 setEnabled 对未注册插件静默 no-op。
    await SourcePluginManager.instance.install(_OrderFakePlugin(id));
    addTearDown(() async {
      await SourcePluginManager.instance.uninstall(id);
      SourceManager.removeSource(id);
    });
    addTearDown(() async {
      for (final c in before) {
        await SourceConfigStore.save(c);
      }
      SourceConfigStore.invalidateCache();
    });

    // 启用时在列表里。
    var enabled = await SourceManager.enabledSources();
    expect(enabled.any((s) => s.id == id), isTrue,
        reason: '自定义源启用时应进入 enabledSources');

    // 停用（setEnabled(false) 走 SourcePluginManager 的 _disabledCustom 禁用集合）。
    await SourcePluginManager.instance.setEnabled(id, false);

    enabled = await SourceManager.enabledSources();
    expect(enabled.any((s) => s.id == id), isFalse,
        reason: '停用的自定义源必须从 enabledSources 消失——否则配置变更后 '
            'ensureEnabledCurrent 会把它静默切回当前源');
  });
}

/// 自定义源插件的最小忠实替身：bind/unbind 挂/收漫画源实现正文。
class _OrderFakePlugin extends SourcePlugin {
  _OrderFakePlugin(String id)
      : super(
          id: id,
          name: 'fake-$id',
          type: 'comic',
          version: '1.0.0',
          author: 'test',
        );

  @override
  Future<void> bind() async => SourceManager.addSource(OrderFakeSource(id));

  @override
  Future<void> unbind() async => SourceManager.removeSource(id);
}
