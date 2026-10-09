import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/image_cache.dart';
import 'package:xingmanxia/ui/widgets/app_toast.dart';
import 'package:xingmanxia/utils/image_super_res.dart';

/// 修复 P2「超分双倍磁盘配额」复核 + 守卫。
///
/// 复核结论：修复前超分图与封面原图共用 `data/images` 同一磁盘配额，
/// 阅读器开一次超分 = 磁盘用量翻倍（SR 图 2x 放大后通常比原图更大），
/// 会挤没封面/连读缓存。本次修复把超分导数独立到 `data/images_sr` 目录，
/// 配额取正常档低一档（不随高端机放大）；内存槽用 `sr:` 前缀与普通图分离，
/// 原图读吐 / 超分缓存相互不污染。
///
/// 守卫价值：
/// 1. SR 结果必须进独立内存槽 + 独立磁盘目录（文件名带算法版本，升级自动失效）；
/// 2. 超分缓存命中不得挡住普通图 `load` 原图请求（槽隔离不变量）；
/// 3. 低内存清内存后磁盘 SR 缓存仍可命中（回读路径）；
/// 4. 配额独立且恒为正常档低一档（不双计）。
void main() {
  var tempDir = '';

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('xm_line1_sr_quota').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getApplicationSupportDirectory' ? tempDir : null,
    );
    // 各用例独立空状态，避免内存/磁盘缓存跨用例污染。
    await ImageCacheManager.clear();
  });

  tearDownAll(() {
    try {
      if (tempDir.isNotEmpty && Directory(tempDir).existsSync()) {
        Directory(tempDir).deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('loadSuperRes 超分双倍配额修复', () {
    test('未命中且无回源时抛异常（只读缓存语义）', () async {
      await expectLater(
        ImageCacheManager.loadSuperRes('https://cdn.example.com/a/1.jpg'),
        throwsA(isA<Exception>()),
      );
    });

    test('回源结果入独立超分内存槽 + 独立磁盘目录（文件名带算法版本）', () async {
      const url = 'https://cdn.example.com/ch/1.jpg';
      final bytes = Uint8List.fromList(List.filled(64, 7));
      var fetchCalls = 0;

      final r1 = await ImageCacheManager.loadSuperRes(
        url,
        readThrough: () async {
          fetchCalls++;
          return bytes;
        },
      );
      expect(r1, bytes);
      expect(fetchCalls, 1);

      // 二次调用命中超分内存槽（sr: 前缀），不再回源
      await ImageCacheManager.loadSuperRes(
        url,
        readThrough: () async {
          fetchCalls++;
          return bytes;
        },
      );
      expect(fetchCalls, 1, reason: '第二次应命中 sr 内存槽');

      // 磁盘文件落在独立目录 images_sr，且文件名带算法版本（升级自动失效）
      final srDir = Directory('$tempDir/data/images_sr');
      expect(srDir.existsSync(), isTrue);
      final srFiles = srDir.listSync().whereType<File>().toList();
      expect(srFiles, hasLength(1));
      expect(srFiles.single.uri.pathSegments.last,
          endsWith('-${ImageSuperRes.algoVersion}.img'));
    });

    test('超分缓存不污染普通图槽（同 URL 的 load 仍走原图请求）', () async {
      const url = 'https://cdn.example.com/ch/2.jpg';
      final srBytes = Uint8List.fromList(List.filled(32, 9));
      await ImageCacheManager.loadSuperRes(
        url,
        readThrough: () async => srBytes,
      );

      var fetched = false;
      final plain = await ImageCacheManager.load(
        url,
        fetch: () async {
          fetched = true;
          return Uint8List.fromList(List.filled(4, 1));
        },
      );
      expect(fetched, isTrue, reason: 'sr 槽命中不应挡住普通图加载');
      expect(plain, isNot(srBytes), reason: '原图请求不得返回超分结果');

      // 两个目录各自只有自己的一份文件（磁盘级互不串扰）
      final normalFiles = Directory('$tempDir/data/images')
          .listSync()
          .whereType<File>()
          .toList();
      final srFiles = Directory('$tempDir/data/images_sr')
          .listSync()
          .whereType<File>()
          .toList();
      expect(normalFiles, hasLength(1));
      expect(srFiles, hasLength(1));
    });

    test('低内存清内存后磁盘超分缓存仍可命中（回读路径）', () async {
      const url = 'https://cdn.example.com/ch/3.jpg';
      final bytes = Uint8List.fromList(List.filled(16, 3));
      await ImageCacheManager.loadSuperRes(
        url,
        readThrough: () async => bytes,
      );
      expect(ImageCacheManager.memoryBytes, greaterThan(0));

      ImageCacheManager.onLowMemory(); // 模拟系统低内存：清空内存缓存
      expect(ImageCacheManager.memoryBytes, 0);

      var refetched = false;
      final r = await ImageCacheManager.loadSuperRes(
        url,
        readThrough: () async {
          refetched = true;
          return Uint8List.fromList(List.filled(2, 5));
        },
      );
      expect(refetched, isFalse, reason: '磁盘 SR 缓存应命中，无需重新回源');
      expect(r, bytes);
    });
  });

  group('超分磁盘配额独立', () {
    test('SR 配额恒为正常档低一档（不双计、不随高端机放大）', () {
      const low = 24 * 1024 * 1024;
      const mid = 40 * 1024 * 1024;
      const high = 64 * 1024 * 1024;
      expect(ImageCacheManager.debugDiskBudgetForTier(low), 128 * 1024 * 1024);
      expect(ImageCacheManager.debugSrDiskBudgetForTier(low), 64 * 1024 * 1024);
      expect(ImageCacheManager.debugDiskBudgetForTier(mid), 256 * 1024 * 1024);
      expect(
          ImageCacheManager.debugSrDiskBudgetForTier(mid), 128 * 1024 * 1024);
      expect(ImageCacheManager.debugDiskBudgetForTier(high), 512 * 1024 * 1024);
      expect(
          ImageCacheManager.debugSrDiskBudgetForTier(high), 256 * 1024 * 1024);
    });
  });

  group('AppToast 全局 messenger 通路（无 context 写盘失败钩子）', () {
    testWidgets('showViaMessenger 经 scaffoldMessengerKey 弹错误 toast',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: AppToast.messengerKey,
        home: const Scaffold(body: SizedBox()),
      ));
      AppToast.showViaMessenger('书架保存失败，本次改动可能丢失', error: true);
      await tester.pump();
      expect(find.text('书架保存失败，本次改动可能丢失'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      await tester.pumpAndSettle();
    });

    test('messenger 未挂载（启动早期）时静默跳过不抛错', () {
      expect(() => AppToast.showViaMessenger('x'), returnsNormally);
    });
  });
}