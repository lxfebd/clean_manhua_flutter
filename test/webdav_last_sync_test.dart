import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/webdav_sync.dart';

/// 回归：第8轮「WebDAV 最近同步时间」（commit 8eb54e3）。
///
/// 覆盖：
/// - [WebDavSync.lastSyncMillis] 读取 `webdav_last_upload`（UTC 毫秒）；
/// - 从未同步 = 0；
/// - push 成功后写入时间戳（push 走真实网络，这里直接验证写通路：
///   `LocalStore.writeJson('webdav_last_upload', ms)` 正是 push() 的落盘动作）；
/// - 跨读写持久（同一值读回）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_webdav_sync');
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
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await LocalStore.init();
    await LocalStore.writeJson('webdav_last_upload', 0);
  });

  test('从未同步：lastSyncMillis 返回 0', () async {
    await LocalStore.writeJson('webdav_last_upload', 0);
    expect(await WebDavSync.lastSyncMillis(), 0);
  });

  test('最近一次 push 时间戳：写入后读回一致（UTC 毫秒）', () async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // 等价于 push() 成功后的落盘动作。
    await LocalStore.writeJson('webdav_last_upload', now);
    expect(await WebDavSync.lastSyncMillis(), now);
  });

  test('跨读写持久：同值读回（不丢精度）', () async {
    final ms = 1768886400000; // 固定值，模拟基线
    await LocalStore.writeJson('webdav_last_upload', ms);
    expect(await WebDavSync.lastSyncMillis(), ms);
    // 再次读取仍是同值。
    expect(await WebDavSync.lastSyncMillis(), ms);
  });

  test('无 webdav_last_upload 键（旧数据）：返回 0', () async {
    final f = File('${tmp.path}/webdav_last_upload.json');
    if (f.existsSync()) f.deleteSync();
    expect(await WebDavSync.lastSyncMillis(), 0);
  });
}