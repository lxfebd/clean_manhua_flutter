import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P1-20 切章失败重试的源码契约回归。
///
/// 背景：三个切章入口（连读 / 上一章 / 目录）都在调用 `_openChapter` **之前**
/// 改 `_chapterIndex`，而旧实现在失败时既不回滚索引、重试又固定读
/// `widget.chapterId` ——于是「索引与标题已是新章、内容还是旧章」，用户点重试
/// 读到初始章，标题/下一页/目录/历史全线错位。
///
/// SourceManager 的源列表是 `static final`（无依赖注入点），真行为无法在单测
/// 里跑，故用与 design_tokens_test / reader_keepalive_test 同构的源码棘轮
/// 锁住三处不变量；行为由真机验收（请求序列必须 N→N+1→N+1）覆盖。
void main() {
  String codeOnly(String text) => text
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final src = codeOnly(File('lib/ui/reader_page.dart').readAsStringSync());

  group('P1-20 切章失败重试契约', () {
    test('源码文件必须存在', () {
      expect(File('lib/ui/reader_page.dart').existsSync(), isTrue);
    });

    test('_load 必须接受目标章节参数（不再固定读 widget.chapterId）', () {
      expect(src.contains('_load({String? chapterId'), isTrue,
          reason: '_load 需要 chapterId 参数，否则重试只能读初始章');
      // 解析目标必须用参数而不是 widget.chapterId。
      expect(src.contains('final targetId = chapterId ?? widget.chapterId;'),
          isTrue);
      // 章节解析与状态提交都必须走 targetId。
      expect(src.contains('_resolveChapterUrls(targetId)'), isTrue);
      expect(src.contains('_activeChapterId = targetId;'), isTrue);
    });

    test('_retryLoad 必须按当前活动章节重试', () {
      expect(src.contains('_load(chapterId: target'), isTrue,
          reason: '重试要带目标章节');
      expect(src.contains('_activeChapterId.isNotEmpty ? _activeChapterId'),
          isTrue,
          reason: '目标必须是当前活动章节，而不是固死的 widget.chapterId');
      // 旧的失败分支（_loadError 时裸调 _load()）必须已被移除。
      expect(RegExp(r'if \(_loadError\) \{\s*_load\(\);').hasMatch(src), isFalse,
          reason: '裸 _load() 会读回初始章');
    });

    test('_openChapter 失败必须回滚章节三态（内容/ID/标题/索引自洽）', () {
      expect(src.contains('final prevActive = _activeChapterId;'), isTrue);
      expect(src.contains('final prevIndex = _chapterIndex;'), isTrue);
      expect(src.contains('_activeChapterId = prevActive;'), isTrue,
          reason: '失败要把活动章节退回请求前，别让 ID/标题指向新章');
      expect(src.contains('_chapterIndex = prevIndex;'), isTrue,
          reason: '索引也必须回滚——入口是提前 ++ 的');
      expect(src.contains('_activeChapterTitle = prevTitle;'), isTrue);
    });

    test('续读页码只在首载章节应用（重试旧章不跳续读页）', () {
      expect(src.contains('final useInitial ='), isTrue);
      expect(src.contains('if (useInitial &&'), isTrue,
          reason: 'widget.initialPage 只应在目标==widget.chapterId 时生效');
    });
  });
}
