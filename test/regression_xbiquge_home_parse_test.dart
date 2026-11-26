import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/sources/xbiquge_novel_source.dart';

/// 新笔趣阁首页解析回归（2026-11-27）。
///
/// ## 修的是什么
/// `rank(1)` 抓首页，但线上有**两个版本**，按 UA 分流：
/// - 桌面 UA → 34110 字节完整版（`sort_list` / `<div class="item">`）
/// - **移动 UA → 10104 字节精简版**（App 的 `NetConn.defaultUA` 就是移动 UA）
///
/// 移动版精简首页的结构与解析器原有锚点**全都不匹配**：
/// - `div.item` 0 个
/// - `sort_list` 0 个（那是分类页的结构）
/// - `rec-focus-book` 4 个，但全是**空占位**（`href="/books_3/"`、`alt=""`、
///   标题空、作者空），且 4 个都是同一个 id=3
///
/// 结果：`rank(1)` 只解析出 **1 条**（id=3 的假数据，标题为空）。
/// 这会被源健康判成「解析出条目但只有 1 条」——不算失败，但首页基本是空的。
///
/// 真书在 `<dl class="sort-book-first">`（头条位，带封面 6 条）和
/// `<ul class="sort-book-list">`（其余，纯文字 57 条）里，共 63 本唯一书。
///
/// 另一个缺陷：旧实现 `if (seen.add(it.id)) items.add(it)` 是「先到先得」，
/// 空占位 id=3 先被加进去后，后面再有同 id 的完整条目会被**丢弃**。
///
/// 修法：新增两个锚点 + 改为「同 id 时用完整条目替换空条目」（保留顺序）。
void main() {
  group('移动版精简首页（App 实际拿到的版本）', () {
    // 从 2026-11-27 真实响应中截取的最小片段，结构与线上一致。
    const mobileHtml = '''
<div class="wrap-box"><h3 class="wrap-title"><span>玄幻修真</span><a class="more" href="/fenlei.html">更多..</a></h3>
<div class="sort-box">
<dl class="sort-book-first"><dt class="book-img"><a href="/books_35261/"><img height="100" width="80" src="/img/35261.jpg" alt="我在幕后调教大佬"></a></dt><dd class="book-info"><h4><a href="/books_35261/">我在幕后调教大佬</a></h4><p>作者：阎ZK</p><p>欢迎阅读…</p></dd></dl>
<ul class="sort-book-list"><li><a href="/books_38414/">龙王传说</a><span>唐家三少</span></li><li><a href="/books_26289/">逆天邪神</a><span>火星引力</span></li></ul>
</div></div>
''';

    test('sort-book-first 头条位能解析出（带封面）', () {
      final src = XbiqugeNovelSource();
      final items = src.parseItemsForTest(mobileHtml);
      final first = items.firstWhere((i) => i.id == '35261');
      expect(first.name, '我在幕后调教大佬');
      expect(first.pic, 'https://www.xbiquge.bz/img/35261.jpg');
    });

    test('sort-book-list 其余书能解析出（无封面）', () {
      final src = XbiqugeNovelSource();
      final items = src.parseItemsForTest(mobileHtml);
      final ids = items.map((i) => i.id).toSet();
      expect(ids, containsAll(['38414', '26289']));
      final lt = items.firstWhere((i) => i.id == '38414');
      expect(lt.name, '龙王传说');
      expect(lt.pic, isEmpty); // 纯文字列表页无封面，不该编造
    });

    test('不再被空占位挤占：同 id 时空标题被完整条目替换', () {
      // 空占位在前（移动版 rec-focus 的形态），完整条目在后。
      const html = '''
<dl class="rec-focus-book"><dt class="book-img"><a href="/books_3/"><img height="100" width="80" src="/img/3.jpg" alt=""></a></dt><dd class="book-info"><h2><a href="/books_3/"></a></h2><p>作者：</p></dd></dl>
<dl class="sort-book-first"><dt><a href="/books_3/"><img src="/img/3.jpg" alt="真书名"></a></dt><dd><h4><a href="/books_3/">真书名</a></h4></dd></dl>
''';
      final src = XbiqugeNovelSource();
      final items = src.parseItemsForTest(html);
      final e = items.firstWhere((i) => i.id == '3');
      expect(e.name, '真书名', reason: '空占位不该把同名完整条目挤掉');
      // 且不应产生两条同 id
      expect(items.where((i) => i.id == '3').length, 1);
    });
  });

  group('桌面版完整首页（兼容，勿回归）', () {
    const desktopHtml = '''
<div class="item"><dl><dt><a href="/books_999/"><img src="/img/999.jpg" alt="桌面书"></a></dt><dd>简介</dd></dl></div>
<ul class="sort_list"><li><span class="s1">[都市小说]</span><span class="s2"><a href="/books_888/">分类页书</a></span></li></ul>
''';

    test('div.item 与 sort_list 仍能解析（旧锚点保留）', () {
      final src = XbiqugeNovelSource();
      final items = src.parseItemsForTest(desktopHtml);
      final ids = items.map((i) => i.id).toSet();
      expect(ids, contains('999'));
      expect(ids, contains('888'));
    });
  });

  test('空输入不抛异常', () {
    final src = XbiqugeNovelSource();
    expect(src.parseItemsForTest(''), isEmpty);
    expect(src.parseItemsForTest('<html></html>'), isEmpty);
  });
}
