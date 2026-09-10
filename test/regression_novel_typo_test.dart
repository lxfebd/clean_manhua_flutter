import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';

/// 小说排版控制：段间距/首行缩进 持久化 + 默认值兼容。
/// 注：LocalStore 的目录在进程内只解析一次，全部断言放同一 test 保证顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.createTempSync('xm_novel_typo').path;
        }
        return null;
      },
    );
  });

  setUp(() => LocalStore.init());

  test('段间距/首行缩进 持久化 + 默认值（顺序敏感）', () async {
    // 全新用户（等价于老数据无新字段）：默认段间距 18、首行缩进开
    expect(await LocalStore.novelParagraphGap(), 18);
    expect(await LocalStore.novelFirstIndent(), isTrue);

    // 写入自定义值
    await LocalStore.setNovelReadSettings(paragraphGap: 30, firstIndent: false);
    expect(await LocalStore.novelParagraphGap(), 30);
    expect(await LocalStore.novelFirstIndent(), isFalse);

    // 只更新其中一个，另一个保持
    await LocalStore.setNovelReadSettings(paragraphGap: 14);
    expect(await LocalStore.novelParagraphGap(), 14);
    expect(await LocalStore.novelFirstIndent(), isFalse);

    // 色温：默认 0，写入 40，再写入 120（越界钳制到 100）
    expect(await LocalStore.novelColorTemp(), 0);
    await LocalStore.setNovelReadSettings(colorTemp: 40);
    expect(await LocalStore.novelColorTemp(), 40);
    await LocalStore.setNovelReadSettings(colorTemp: 120);
    expect(await LocalStore.novelColorTemp(), 100);
  });
}
