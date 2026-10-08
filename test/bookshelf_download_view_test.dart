import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/local_store.dart';
import 'package:xingmanxia/net/video_download_manager.dart';
import 'package:xingmanxia/ui/bookshelf_download_view.dart';

/// 书架「下载」Tab 渲染测试：动漫下载卡片四态（进行中/完成/失败/取消）
/// 与「已完成但文件缺失」态的图标/文案/重试入口呈现。
///
/// 纯渲染组件测试：不触网络/IO，直接构造 [BookshelfDownloadView] 放入
/// CustomScrollView 渲染（组件返回单个 Sliver）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  VideoDownloadTask task({
    required String title,
    String state = 'downloading',
    String? localPath,
    String? error,
    int segmentsTotal = 0,
    int segmentsDone = 0,
  }) => VideoDownloadTask(
          sourceId: 's', videoId: 'v', title: title, season: 1,
          episode: 1, url: 'http://x/a.mp4')
      ..state = state
      ..localPath = localPath
      ..error = error
      ..segmentsTotal = segmentsTotal
      ..segmentsDone = segmentsDone;

  Widget wrap(List<VideoDownloadTask> anime,
      {List<DownloadRecord> manga = const [], bool retryingAll = false}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => CustomScrollView(
            slivers: [
              BookshelfDownloadView(
                scheme: Theme.of(context).colorScheme,
                mangaDownloads: manga,
                animeDownloads: anime,
                retryingAll: retryingAll,
                onClearManga: () async {},
                onRetryAllManga: () async {},
                onOpenMangaDetail: (_) {},
                onRetryManga: (_) async {},
                onRemoveManga: (_) {},
                onRemoveMangaBook: (_) async {},
                onClearAnime: () async {},
                onOpenAnime: (_) {},
                onRetryAnime: (_) async {},
                onRemoveAnime: (_) {},
                onRemoveAnimeTitle: (_) async {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('动漫下载：进行中显示下载图标与进度', (WidgetTester tester) async {
    final t = task(title: '海贼王', segmentsTotal: 10, segmentsDone: 5);
    await tester.pumpWidget(wrap([t]));
    expect(find.text('海贼王'), findsOneWidget);
    expect(find.text('第 1 集'), findsOneWidget);
    expect(find.byIcon(Icons.downloading_rounded), findsOneWidget);
    // 进度条 + 分片计数（无 totalBytes 时显示 segmentsDone/total）
    expect(find.text('5/10'), findsOneWidget);
  });

  testWidgets('动漫下载：完成显示播放图标与「第 N 集」', (WidgetTester tester) async {
    // done + 文件真实存在 → 播放图标（系统 temp 在测试里可写）
    final dir = Directory.systemTemp.createTempSync('xm_dl_view');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final f = File('${dir.path}/done.mp4');
    f.writeAsBytesSync([0, 1, 2, 3]);
    final t = task(title: '火影', state: 'done', localPath: f.path);
    await tester.pumpWidget(wrap([t]));
    expect(find.text('火影'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.text('第 1 集'), findsOneWidget);
  });

  testWidgets('动漫下载：失败显示红色错误图标 + 原因文案 + 重试按钮', (WidgetTester tester) async {
    final t = task(
        title: '鬼灭', state: 'failed', error: '下载停滞，请重试');
    await tester.pumpWidget(wrap([t]));
    expect(find.text('鬼灭'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.textContaining('下载停滞'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('动漫下载：取消显示停止图标 + 「已取消」', (WidgetTester tester) async {
    final t = task(title: '电锯人', state: 'canceled');
    await tester.pumpWidget(wrap([t]));
    expect(find.text('电锯人'), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    expect(find.textContaining('已取消'), findsOneWidget);
  });

  testWidgets('动漫下载：已完成但文件缺失 → 缺失图标 + 提示，不是播放图标', (WidgetTester tester) async {
    final t = task(title: '进击', state: 'done', localPath: null);
    await tester.pumpWidget(wrap([t]));
    expect(find.text('进击'), findsOneWidget);
    // 关键断言：done + 文件缺失必须显示缺失图标（灰 help），不是蓝色播放图标
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsNothing);
    expect(find.textContaining('文件缺失'), findsOneWidget);
    // 缺失态提供重新下载入口
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  DownloadRecord failedManga() => DownloadRecord(
        book: const Bookmark(sourceId: 's', comicId: 'c', name: '咒术', pic: ''),
        chapterId: 'ch1',
        chapterTitle: '第 1 话',
        total: 2,
        done: 2, // 计数到齐但未 finished → 判定为失败任务
        finished: false,
        localKey: 'k',
        error: '磁盘写入失败',
      );

  testWidgets('漫画下载：失败任务显示「重试 N」入口（未在重试中）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap([], manga: [failedManga()]));
    expect(find.text('咒术'), findsOneWidget);
    expect(find.textContaining('磁盘写入失败'), findsOneWidget);
    expect(find.text('重试 1'), findsOneWidget);
    // 未重试中 → 按钮可点，无 spinner
    final btn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '重试 1'));
    expect(btn.onPressed, isNotNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('漫画下载：retryingAll 时重试按钮禁用 + spinner + 「重试中…」', (WidgetTester tester) async {
    // 进行中的任务（done < total）不计入 _failedManga；两个失败任务 → 计数 2
    final inProgress = DownloadRecord(
        book: const Bookmark(sourceId: 's', comicId: 'c2', name: '进行中', pic: ''),
        chapterId: 'ch1',
        chapterTitle: '第 1 话',
        total: 5,
        done: 2,
        finished: false,
        localKey: 'k2');
    await tester.pumpWidget(wrap([],
        manga: [failedManga(), failedManga(), inProgress], retryingAll: true));
    expect(find.text('重试中…'), findsOneWidget);
    // 重试中：头部按钮禁用（onPressed null）+ spinner
    final btn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '重试中…'));
    expect(btn.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 头部刷新图标被 spinner 替换；卡片级重试按钮不随批量重试隐藏
    // （3 张未完成卡片：2 失败 + 1 进行中，每张各有一个 refresh）
    expect(find.byIcon(Icons.refresh_rounded), findsNWidgets(3));
    // 头部「重试 N」计数消失（被「重试中…」取代）
    expect(find.text('重试 2'), findsNothing);
  });
}
