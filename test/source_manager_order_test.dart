import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/models/comic_item.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/sources/comic_source.dart';
import 'package:xingmanxia/sources/source_config.dart';
import 'package:xingmanxia/sources/source_manager.dart';

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
}
