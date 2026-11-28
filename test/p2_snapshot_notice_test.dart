import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/theme.dart';
import 'package:xingmanxia/ui/home_page.dart';

/// P2-03：快照/离线状态必须可见，不能只靠用户猜。
void main() {
  testWidgets('离线快照显示缓存时间与重试入口', (tester) async {
    var retries = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(0, false),
      home: Scaffold(
        body: HomeSnapshotNotice(
          updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
          offline: true,
          onRetry: () => retries++,
        ),
      ),
    ));
    expect(find.textContaining('离线内容'), findsOneWidget);
    expect(find.textContaining('上次更新于今天'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retries, 1);
  });

  testWidgets('网络更新中也明确这是缓存，不伪装成实时内容', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(0, false),
      home: Scaffold(
        body: HomeSnapshotNotice(
          updatedAt: null,
          offline: false,
          onRetry: () {},
        ),
      ),
    ));
    expect(find.textContaining('缓存内容'), findsOneWidget);
    expect(find.textContaining('正在更新'), findsOneWidget);
    expect(find.textContaining('时间未知'), findsOneWidget);
  });
}
